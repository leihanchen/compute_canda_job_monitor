import Foundation

/// Trigger source for a cluster refresh operation.
public enum RefreshReason: Equatable, Hashable, Sendable {
    case panelOpened
    case background
    case manual
    case afterLogin
    case wakeOrNetwork
}

/// Pure policy determining whether a cluster should refresh for a given trigger and state.
public enum RefreshPolicy {
    /// Minimum age (in seconds) before opening the panel triggers an automatic refresh.
    public static let panelOpenThreshold: TimeInterval = 60

    /// Returns `true` when a cluster refresh should run under the given conditions.
    public static func shouldRefresh(
        reason: RefreshReason,
        lastFetched: Date?,
        now: Date,
        isLoggingIn: Bool
    ) -> Bool {
        if isLoggingIn {
            return false
        }

        switch reason {
        case .panelOpened:
            guard let lastFetched else {
                return true
            }
            return now.timeIntervalSince(lastFetched) > panelOpenThreshold
        case .background, .manual, .afterLogin, .wakeOrNetwork:
            return true
        }
    }
}
