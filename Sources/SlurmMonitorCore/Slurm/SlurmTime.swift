import Foundation

/// Parsing helpers for Slurm durations, timestamps, and GPU resource strings.
public enum SlurmTime {
    private static let nullTokens: Set<String> = [
        "", "n/a", "(null)", "unknown", "none"
    ]

    private static let invalidDurationTokens: Set<String> = [
        "unlimited", "invalid", "not_set"
    ]

    /// Parses a Slurm duration (`D-HH:MM:SS`, `HH:MM:SS`, or `MM:SS`) into seconds.
    public static func duration(_ s: String) -> TimeInterval? {
        guard let token = nonNullToken(s) else { return nil }
        guard !invalidDurationTokens.contains(token.lowercased()) else { return nil }

        let dashParts = token.split(separator: "-", omittingEmptySubsequences: false)
        let days: Int?
        let timeString: Substring

        switch dashParts.count {
        case 1:
            days = nil
            timeString = dashParts[0]
        case 2:
            guard let parsedDays = nonNegativeASCIIInt(dashParts[0]) else { return nil }
            days = parsedDays
            timeString = dashParts[1]
        default:
            return nil
        }

        let timeParts = timeString.split(separator: ":", omittingEmptySubsequences: false)
        let hours: Int
        let minutes: Int
        let seconds: Int

        switch timeParts.count {
        case 2:
            guard days == nil,
                  let parsedMinutes = nonNegativeASCIIInt(timeParts[0]),
                  let parsedSeconds = nonNegativeASCIIInt(timeParts[1]),
                  parsedMinutes < 60,
                  parsedSeconds < 60 else {
                return nil
            }
            hours = 0
            minutes = parsedMinutes
            seconds = parsedSeconds
        case 3:
            guard let parsedHours = nonNegativeASCIIInt(timeParts[0]),
                  let parsedMinutes = nonNegativeASCIIInt(timeParts[1]),
                  let parsedSeconds = nonNegativeASCIIInt(timeParts[2]),
                  days == nil || parsedHours < 24,
                  parsedMinutes < 60,
                  parsedSeconds < 60 else {
                return nil
            }
            hours = parsedHours
            minutes = parsedMinutes
            seconds = parsedSeconds
        default:
            return nil
        }

        let totalSeconds = (days ?? 0) * 86_400 + hours * 3_600 + minutes * 60 + seconds
        return TimeInterval(totalSeconds)
    }

    /// Parses a Slurm ISO-like timestamp (`yyyy-MM-dd'T'HH:mm:ss`) in the local time zone.
    public static func date(_ s: String) -> Date? {
        guard let token = nonNullToken(s) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: token)
    }

    /// Sums trailing integers of comma-separated GPU GRES/TRES entries (e.g. `gres/gpu:4`, `gpu:h100:2`).
    public static func gpuCount(_ gres: String) -> Int? {
        guard let token = nonNullToken(gres) else { return nil }

        var total = 0
        var foundGPUEntry = false

        for rawEntry in splitTopLevelCommas(token) {
            let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard entry.localizedCaseInsensitiveContains("gpu"),
                  let count = trailingGPUCount(in: entry) else {
                continue
            }
            total += count
            foundGPUEntry = true
        }

        return foundGPUEntry ? total : nil
    }

    /// Returns `nil` when `raw` is blank or matches a Slurm sentinel placeholder.
    static func nonNullToken(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nullTokens.contains(trimmed.lowercased()) else { return nil }
        return trimmed
    }

    private static func splitTopLevelCommas(_ text: String) -> [Substring] {
        var entries: [Substring] = []
        var start = text.startIndex
        var parenDepth = 0

        for index in text.indices {
            switch text[index] {
            case "(":
                parenDepth += 1
            case ")":
                if parenDepth > 0 {
                    parenDepth -= 1
                }
            case "," where parenDepth == 0:
                entries.append(text[start..<index])
                start = text.index(after: index)
            default:
                break
            }
        }
        entries.append(text[start...])
        return entries
    }

    private static func trailingGPUCount(in entry: String) -> Int? {
        let cleaned = strippingTrailingParenthetical(entry[...])

        let parts = cleaned.split(whereSeparator: { $0 == ":" || $0 == "=" })
        guard parts.count >= 2,
              let lastPart = parts.last,
              let count = nonNegativeASCIIInt(lastPart) else {
            return nil
        }
        return count
    }

    private static func strippingTrailingParenthetical(_ text: Substring) -> Substring {
        guard text.hasSuffix(")") else { return text }
        var closeCount = 0
        var index = text.endIndex
        while index > text.startIndex {
            index = text.index(before: index)
            switch text[index] {
            case ")":
                closeCount += 1
            case "(":
                closeCount -= 1
                if closeCount == 0 {
                    return text[..<index]
                }
            default:
                break
            }
        }
        return text
    }

    private static func nonNegativeASCIIInt(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            return nil
        }
        return Int(text)
    }
}
