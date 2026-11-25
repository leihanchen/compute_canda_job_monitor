import Foundation

/// A selectable MFA authentication method presented by Duo or SSH keyboard-interactive login.
public struct MFAOption: Equatable, Hashable, Sendable {
    public var number: Int
    public var label: String

    public init(number: Int, label: String) {
        self.number = number
        self.label = label
    }
}

/// Interactive prompts and terminal denial outcomes detected in a PTY login stream.
public enum LoginPrompt: Equatable, Hashable, Sendable {
    case hostKey(fingerprint: String)
    case password
    case passphrase
    case mfa(options: [MFAOption])
    case denied(ClusterError)
}

/// Classifies PTY output accumulated since the last answered prompt into `LoginPrompt` values.
public enum LoginPromptClassifier {
    private static let ansiEscapeRegex = try! NSRegularExpression(
        pattern: #"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B\[[0-?]*[ -/]*[@-~]|\x1B[@-Z\\-_]"#
    )
    private static let sha256Regex = try! NSRegularExpression(
        pattern: #"SHA256:\S+"#
    )
    private static let mfaOptionRegex = try! NSRegularExpression(
        pattern: #"^\s*(\d+)\.\s+(.+)$"#
    )
    private static let trailingFingerprintPunctuation = CharacterSet(charactersIn: ".,;:!?)]'\"")

    /// Normalizes PTY `\r\n` / `\r` line endings and strips ANSI escape sequences and control characters.
    public static func normalize(_ text: String) -> String {
        let unifiedNewlines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return stripANSIAndControls(unifiedNewlines)
    }

    /// Sanitizes an incremental PTY output chunk for display in `.transcript` events.
    static func sanitizeForTranscript(_ chunk: String) -> String {
        let strippedCR = chunk
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "")
        return stripANSIAndControls(strippedCR)
    }

    /// Inspects `buffer` (the text accumulated since the last answered prompt) and returns a `LoginPrompt`, if matched.
    public static func classify(_ buffer: String) -> LoginPrompt? {
        let normalized = normalize(buffer)
        let trimmedTail = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTail.isEmpty else { return nil }

        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lastNonEmptyLine = lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""

        if lastNonEmptyLine.range(of: "(yes/no/[fingerprint])", options: .caseInsensitive) != nil {
            let fingerprint = extractSHA256Fingerprint(from: normalized) ?? ""
            return .hostKey(fingerprint: fingerprint)
        }

        if lastNonEmptyLine.range(of: "Enter passphrase for key", options: .caseInsensitive) != nil {
            return .passphrase
        }

        if lastNonEmptyLine.range(of: "Passcode or option", options: .caseInsensitive) != nil {
            let options = parseMFAOptions(from: lines)
            return .mfa(options: options)
        }

        if trimmedTail.lowercased().hasSuffix("password:") {
            return .password
        }

        if normalized.contains("Permission denied (publickey)") {
            return .denied(.needsSSHKey)
        }

        if normalized.range(of: "Login timed out", options: .caseInsensitive) != nil
            || normalized.range(of: "Access denied", options: .caseInsensitive) != nil {
            return .denied(.mfaFailed)
        }

        return nil
    }

    private static func stripANSIAndControls(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let withoutANSI = ansiEscapeRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")

        var filtered = String.UnicodeScalarView()
        filtered.reserveCapacity(withoutANSI.unicodeScalars.count)
        for scalar in withoutANSI.unicodeScalars {
            let v = scalar.value
            if v == 0x09 || v == 0x0A || (v >= 0x20 && v != 0x7F) {
                filtered.append(scalar)
            }
        }
        return String(filtered)
    }

    private static func extractSHA256Fingerprint(from text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = sha256Regex.matches(in: text, range: range)
        guard let last = matches.last, let swiftRange = Range(last.range, in: text) else {
            return nil
        }
        return trimTrailingPunctuation(String(text[swiftRange]))
    }

    private static func trimTrailingPunctuation(_ token: String) -> String {
        var result = token
        while let last = result.unicodeScalars.last, trailingFingerprintPunctuation.contains(last) {
            result.unicodeScalars.removeLast()
        }
        return result
    }

    private static func parseMFAOptions(from lines: [String]) -> [MFAOption] {
        var options: [MFAOption] = []
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = mfaOptionRegex.firstMatch(in: line, range: range),
                  let numberRange = Range(match.range(at: 1), in: line),
                  let labelRange = Range(match.range(at: 2), in: line),
                  let number = Int(line[numberRange]) else {
                continue
            }
            let label = line[labelRange].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            options.append(MFAOption(number: number, label: label))
        }
        return options
    }
}
