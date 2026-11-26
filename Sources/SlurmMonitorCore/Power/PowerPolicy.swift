import Foundation

/// Evaluates whether the app should hold a system-sleep power assertion.
public enum PowerPolicy: Sendable {
    /// Returns `true` only when the preference is enabled, the Mac is on AC power, and at least one cluster is live.
    public static func shouldHoldAssertion(
        enabled: Bool,
        onACPower: Bool,
        liveConnections: Int
    ) -> Bool {
        enabled && onACPower && liveConnections >= 1
    }
}
