import Foundation

/// Parser for `ssh -G` configuration dump output.
public enum SSHGOutput {
    /// Parses `ssh -G` output into a map from lowercase option name to values in order of appearance.
    public static func parse(_ text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let splitIndex = trimmed.firstIndex(where: \.isWhitespace) {
                let key = trimmed[..<splitIndex].lowercased()
                let value = trimmed[splitIndex...].trimmingCharacters(in: .whitespaces)
                result[key, default: []].append(value)
            } else {
                result[trimmed.lowercased(), default: []].append("")
            }
        }
        return result
    }
}
