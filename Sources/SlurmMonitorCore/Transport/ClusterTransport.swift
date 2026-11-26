import Foundation

/// Availability state of a `ClusterTransport` after a non-interactive probe.
public enum TransportState: Equatable, Sendable {
    case usable
    case unavailable(ClusterError)
}

/// Non-interactive execution channel to a Slurm cluster.
public protocol ClusterTransport: Sendable {
    var kind: ConnectionMethodKind { get }
    func probe() async -> TransportState
    func run(_ script: String, timeout: TimeInterval) async throws -> String
}

/// Selects the first usable `ClusterTransport` from an ordered list without prompting the user.
public struct ConnectionChain: Sendable {
    public let transports: [ClusterTransport]

    public init(_ transports: [ClusterTransport]) {
        self.transports = transports
    }

    /// Probes transports in order, returning the first `.usable` transport or the last transport's error.
    public func firstUsable() async -> Result<ClusterTransport, ClusterError> {
        guard !transports.isEmpty else {
            return .failure(.needsLogin)
        }

        var lastError: ClusterError = .needsLogin
        for transport in transports {
            switch await transport.probe() {
            case .usable:
                return .success(transport)
            case .unavailable(let error):
                lastError = error
            }
        }
        return .failure(lastError)
    }
}
