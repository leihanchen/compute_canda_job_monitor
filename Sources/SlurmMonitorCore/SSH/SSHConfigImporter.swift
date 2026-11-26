import Foundation

/// A literal host entry parsed from an OpenSSH client configuration file.
public struct SSHConfigHost: Equatable, Sendable {
    public var alias: String
    public var hostName: String?
    public var user: String?

    public init(alias: String, hostName: String? = nil, user: String? = nil) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
    }
}

/// Read-only parser and converter for `~/.ssh/config` host entries.
public enum SSHConfigImporter {
    private static let knownDomainSuffixes = [
        ".alliancecan.ca",
        ".computecanada.ca",
        ".scinet.utoronto.ca",
    ]

    /// Parses literal `Host` blocks from SSH config text, ignoring comments, blank lines,
    /// `Match` blocks, and wildcard/negated patterns (`*`, `?`, `!`).
    public static func parseHosts(_ text: String) -> [SSHConfigHost] {
        var parsed: [SSHConfigHost] = []
        var currentHosts: [SSHConfigHost] = []

        func flushCurrent() {
            guard !currentHosts.isEmpty else { return }
            parsed.append(contentsOf: currentHosts)
            currentHosts.removeAll(keepingCapacity: true)
        }

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let (keyword, value) = splitDirective(trimmed)
            switch keyword {
            case "host":
                flushCurrent()
                let aliases = value
                    .split(whereSeparator: \.isWhitespace)
                    .map { stripQuotes(String($0)) }
                    .filter { !$0.isEmpty && !containsWildcard($0) }
                currentHosts = aliases.map { SSHConfigHost(alias: $0) }
            case "match":
                flushCurrent()
            case "hostname":
                applyIfUnset(\.hostName, rawValue: value, to: &currentHosts)
            case "user":
                applyIfUnset(\.user, rawValue: value, to: &currentHosts)
            default:
                continue
            }
        }

        flushCurrent()
        return parsed
    }

    /// Returns `true` when `hostName` ends with a known Alliance or SciNet cluster domain suffix.
    public static func isKnownClusterDomain(_ hostName: String) -> Bool {
        let normalized = hostName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return knownDomainSuffixes.contains { normalized.hasSuffix($0) }
    }

    /// Converts a parsed `SSHConfigHost` into a `ClusterConfig`, preserving `sshAlias`.
    public static func cluster(from host: SSHConfigHost, defaultUser: String) -> ClusterConfig {
        let resolvedHost = host.hostName ?? host.alias
        let resolvedUser = host.user ?? defaultUser
        let requiresKey = AlliancePresets.all.contains { preset in
            preset.requiresKey && preset.host.caseInsensitiveCompare(resolvedHost) == .orderedSame
        }
        return ClusterConfig(
            name: host.alias,
            host: resolvedHost,
            username: resolvedUser,
            sshAlias: host.alias,
            requiresKey: requiresKey
        )
    }

    private static func applyIfUnset(
        _ keyPath: WritableKeyPath<SSHConfigHost, String?>,
        rawValue: String,
        to hosts: inout [SSHConfigHost]
    ) {
        let resolved = stripQuotes(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else { return }
        for index in hosts.indices where hosts[index][keyPath: keyPath] == nil {
            hosts[index][keyPath: keyPath] = resolved
        }
    }

    private static func splitDirective(_ line: String) -> (keyword: String, value: String) {
        guard let splitIndex = line.firstIndex(where: { $0.isWhitespace || $0 == "=" }) else {
            return (line.lowercased(), "")
        }
        let keyword = line[..<splitIndex].lowercased()
        var remainder = line[splitIndex...].drop(while: { $0.isWhitespace })
        if remainder.first == "=" {
            remainder = remainder.dropFirst().drop(while: { $0.isWhitespace })
        }
        let value = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return (keyword, value)
    }

    private static func containsWildcard(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?") || pattern.contains("!")
    }

    private static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
