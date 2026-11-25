import Foundation

/// Classified failure modes for cluster SSH and Slurm operations.
public enum ClusterError: Codable, Hashable, Sendable, Error {
    case needsLogin
    case needsSSHKey
    case noAccess
    case unreachable
    case mfaFailed
    case slurmFailed(String)

    /// Short user-facing remediation hint shown in the cluster list and status banner.
    public var hint: String {
        switch self {
        case .needsLogin:
            return "Log in to refresh"
        case .needsSSHKey:
            return "Upload an SSH key in CCDB"
        case .noAccess:
            return "Request access to this cluster in CCDB"
        case .unreachable:
            return "Cluster unreachable"
        case .mfaFailed:
            return "MFA was denied or timed out"
        case .slurmFailed:
            return "Slurm command failed"
        }
    }
}

/// Maps raw `/usr/bin/ssh` command failures into actionable `ClusterError` cases.
public enum ClusterErrorClassifier {
    private static let unreachablePatterns = [
        "Could not resolve hostname",
        "Connection refused",
        "Operation timed out",
        "No route to host",
        "Network is unreachable",
    ]

    private static let noAccessPatterns = [
        "not allowed",
        "account is not",
        "Access denied",
    ]

    private static let needsLoginPatterns = [
        "Control socket connect",
        "No such file or directory",
        "Permission denied",
        "Host key verification failed",
    ]

    /// Classifies a failed `CommandResult` according to precedence rules.
    public static func classify(_ result: CommandResult) -> ClusterError {
        if result.timedOut {
            return .unreachable
        }

        let stderr = result.stderr

        // Only publickey offered -> missing/unregistered SSH key (distinct from publickey,keyboard-interactive).
        if stderr.contains("Permission denied (publickey)") {
            return .needsSSHKey
        }

        if containsAny(stderr, patterns: unreachablePatterns) {
            return .unreachable
        }

        if containsAny(stderr, patterns: noAccessPatterns) {
            return .noAccess
        }

        if containsAny(stderr, patterns: needsLoginPatterns) {
            return .needsLogin
        }

        return .needsLogin
    }

    private static func containsAny(_ text: String, patterns: [String]) -> Bool {
        patterns.contains { text.range(of: $0, options: .caseInsensitive) != nil }
    }
}
