import Foundation

/// Resolves the shared SSH `ControlPath` template and expanded path for a cluster.
public enum ControlPathResolver {
    private static let zeroArgMatchCriteria: Set<String> = ["all", "canonical", "final"]

    /// Finds the first applicable `ControlPath` template in an OpenSSH user configuration file.
    ///
    /// Follows OpenSSH's first-obtained rule: returns `nil` if the first applicable `ControlPath`
    /// is `none` or if no applicable block defines one. `Include` directives are not followed.
    public static func userTemplate(configText: String, alias: String?, hostName: String) -> String? {
        let candidates = [alias, hostName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        var currentBlockApplies = true

        for rawLine in configText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let (keyword, remainder) = splitDirective(trimmed)
            switch keyword {
            case "host":
                let tokens = tokenize(remainder, splitOnEquals: false)
                currentBlockApplies = hostBlockApplies(tokens: tokens, candidates: candidates)
            case "match":
                let tokens = tokenize(remainder, splitOnEquals: true)
                currentBlockApplies = matchBlockApplies(tokens: tokens, candidates: candidates)
            case "controlpath":
                guard currentBlockApplies else { continue }
                guard let value = tokenize(remainder, splitOnEquals: false).first, !value.isEmpty else {
                    continue
                }
                if value.lowercased() == "none" {
                    return nil
                }
                return value
            default:
                continue
            }
        }

        return nil
    }

    /// Resolves the effective `ControlPath` socket path and `ssh -G` options for `cluster`.
    public static func resolve(
        cluster: ClusterConfig,
        userConfigText: String,
        appTemplate: String,
        runner: CommandRunner
    ) async -> (controlPath: String, sshG: [String: [String]]) {
        let template = userTemplate(
            configText: userConfigText,
            alias: cluster.sshAlias,
            hostName: cluster.host
        ) ?? appTemplate

        let result = await runner.run(
            "/usr/bin/ssh",
            ["-G", "-o", "ControlPath=\(template)", cluster.sshTarget],
            stdin: nil,
            timeout: 10
        )

        guard !result.timedOut, result.exitCode == 0 else {
            return (expandTilde(template), [:])
        }

        let parsed = SSHGOutput.parse(result.stdout)
        if let resolvedPath = parsed["controlpath"]?.first,
           !resolvedPath.isEmpty,
           resolvedPath.lowercased() != "none" {
            return (resolvedPath, parsed)
        }

        return (expandTilde(template), parsed)
    }

    static func expandTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private static func splitDirective(_ line: String) -> (keyword: String, remainder: String) {
        guard let splitIndex = line.firstIndex(where: { $0.isWhitespace || $0 == "=" }) else {
            return (line.lowercased(), "")
        }
        let keyword = line[..<splitIndex].lowercased()
        var remainder = line[splitIndex...].drop(while: { $0.isWhitespace })
        if remainder.first == "=" {
            remainder = remainder.dropFirst().drop(while: { $0.isWhitespace })
        }
        return (keyword, String(remainder))
    }

    private static func tokenize(_ text: String, splitOnEquals: Bool) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var activeQuote: Character?

        func flush() {
            if inToken {
                tokens.append(current)
                current = ""
                inToken = false
            }
        }

        for char in text {
            if let quote = activeQuote {
                if char == quote {
                    activeQuote = nil
                } else {
                    current.append(char)
                }
                continue
            }

            if char == "\"" || char == "'" {
                activeQuote = char
                inToken = true
            } else if char.isWhitespace || (splitOnEquals && char == "=") {
                flush()
            } else {
                current.append(char)
                inToken = true
            }
        }
        flush()
        return tokens
    }

    private static func hostBlockApplies(tokens: [String], candidates: [String]) -> Bool {
        let patternList = tokens.joined(separator: ",")
        return matchesPatternList(patternList, candidates: candidates, caseInsensitive: false)
    }

    private static func matchBlockApplies(tokens: [String], candidates: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }

        var index = 0
        while index < tokens.count {
            let criterion = tokens[index].lowercased()
            if zeroArgMatchCriteria.contains(criterion) {
                index += 1
                continue
            }

            guard index + 1 < tokens.count else {
                return false
            }
            let value = tokens[index + 1]
            index += 2

            switch criterion {
            case "host", "originalhost":
                if !matchesPatternList(value, candidates: candidates, caseInsensitive: true) {
                    return false
                }
            case "!host", "!originalhost":
                if matchesPatternList(value, candidates: candidates, caseInsensitive: true) {
                    return false
                }
            default:
                // Non-host criteria (exec, user, localuser, etc.) are treated as satisfied.
                continue
            }
        }
        return true
    }

    private static func matchesPatternList(
        _ patternList: String,
        candidates: [String],
        caseInsensitive: Bool
    ) -> Bool {
        guard !candidates.isEmpty else { return false }

        var positiveMatched = false
        for rawPattern in patternList.split(separator: ",") where !rawPattern.isEmpty {
            if rawPattern.hasPrefix("!") {
                let negatedPattern = String(rawPattern.dropFirst())
                guard !negatedPattern.isEmpty else { continue }
                if candidates.contains(where: {
                    globMatch($0, pattern: negatedPattern, caseInsensitive: caseInsensitive)
                }) {
                    return false
                }
            } else {
                let pattern = String(rawPattern)
                if candidates.contains(where: {
                    globMatch($0, pattern: pattern, caseInsensitive: caseInsensitive)
                }) {
                    positiveMatched = true
                }
            }
        }
        return positiveMatched
    }

    private static func globMatch(_ text: String, pattern: String, caseInsensitive: Bool) -> Bool {
        let t = Array(caseInsensitive ? text.lowercased() : text)
        let p = Array(caseInsensitive ? pattern.lowercased() : pattern)
        var ti = 0
        var pi = 0
        var starIndex: Int?
        var matchIndex = 0

        while ti < t.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == t[ti]) {
                ti += 1
                pi += 1
            } else if pi < p.count && p[pi] == "*" {
                starIndex = pi
                matchIndex = ti
                pi += 1
            } else if let s = starIndex {
                pi = s + 1
                matchIndex += 1
                ti = matchIndex
            } else {
                return false
            }
        }

        while pi < p.count && p[pi] == "*" {
            pi += 1
        }
        return pi == p.count
    }
}
