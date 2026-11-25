import Foundation

/// Transport method used to query Slurm status on a cluster.
public enum ConnectionMethodKind: String, Codable, Hashable, Sendable {
    case sharedSSH
    case robot
}

/// Configuration for a monitored Slurm cluster.
public struct ClusterConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var username: String
    public var sshAlias: String?
    public var identityFile: String?
    public var enabled: Bool
    public var methods: [ConnectionMethodKind]
    public var requiresKey: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        username: String,
        sshAlias: String? = nil,
        identityFile: String? = nil,
        enabled: Bool = true,
        methods: [ConnectionMethodKind] = [.sharedSSH],
        requiresKey: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.username = username
        self.sshAlias = sshAlias
        self.identityFile = identityFile
        self.enabled = enabled
        self.methods = methods
        self.requiresKey = requiresKey
    }

    /// SSH destination passed to `ssh` invocations, preferring `sshAlias` when configured.
    public var sshTarget: String {
        sshAlias ?? "\(username)@\(host)"
    }

    /// Deterministic SSH config alias derived from the cluster name.
    public var generatedAlias: String {
        let sanitized = name
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression)
        return "smon-\(sanitized)"
    }

    /// Returns `true` when any connection-defining property differs from `other`.
    public func hasConnectionChange(comparedTo other: ClusterConfig) -> Bool {
        sshTarget != other.sshTarget
            || generatedAlias != other.generatedAlias
            || host != other.host
            || username != other.username
            || identityFile != other.identityFile
            || methods != other.methods
            || requiresKey != other.requiresKey
    }
}
