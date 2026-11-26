import Foundation

/// Normalized Slurm job lifecycle state.
public enum JobState: String, Codable, Hashable, Sendable {
    case running
    case pending
    case completing
    case completed
    case failed
    case timeout
    case outOfMemory
    case cancelled
    case other

    /// Initializes a `JobState` from a raw Slurm state string (e.g. `"CANCELLED by 123"`).
    public init(slurm: String) {
        let firstWord = slurm
            .split(whereSeparator: \.isWhitespace)
            .first
            .map { String($0).uppercased() } ?? ""

        switch firstWord {
        case "RUNNING":
            self = .running
        case "PENDING":
            self = .pending
        case "COMPLETING":
            self = .completing
        case "COMPLETED":
            self = .completed
        case "FAILED", "NODE_FAIL", "BOOT_FAIL":
            self = .failed
        case "TIMEOUT", "DEADLINE":
            self = .timeout
        case "OUT_OF_MEMORY":
            self = .outOfMemory
        case "CANCELLED":
            self = .cancelled
        default:
            self = .other
        }
    }

    /// Returns `true` when the state represents a finished job.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .timeout, .outOfMemory, .cancelled:
            return true
        case .running, .pending, .completing, .other:
            return false
        }
    }
}

/// Active or pending Slurm job parsed from `squeue`.
public struct ActiveJob: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var state: JobState
    public var partition: String
    public var account: String
    public var elapsed: TimeInterval?
    public var timeLimit: TimeInterval?
    public var nodes: Int?
    public var cpus: Int?
    public var memory: String?
    public var gpus: Int?
    public var reasonOrNodes: String
    public var submitTime: Date?
    public var startTime: Date?
    public var workDir: String?
    public var estimatedStart: Date?

    public init(
        id: String,
        name: String,
        state: JobState,
        partition: String,
        account: String,
        elapsed: TimeInterval? = nil,
        timeLimit: TimeInterval? = nil,
        nodes: Int? = nil,
        cpus: Int? = nil,
        memory: String? = nil,
        gpus: Int? = nil,
        reasonOrNodes: String,
        submitTime: Date? = nil,
        startTime: Date? = nil,
        workDir: String? = nil,
        estimatedStart: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.partition = partition
        self.account = account
        self.elapsed = elapsed
        self.timeLimit = timeLimit
        self.nodes = nodes
        self.cpus = cpus
        self.memory = memory
        self.gpus = gpus
        self.reasonOrNodes = reasonOrNodes
        self.submitTime = submitTime
        self.startTime = startTime
        self.workDir = workDir
        self.estimatedStart = estimatedStart
    }
}

/// Recently terminated Slurm job parsed from `sacct`.
public struct EndedJob: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var state: JobState
    public var exitCode: String
    public var endTime: Date?
    public var elapsed: TimeInterval?

    public init(
        id: String,
        name: String,
        state: JobState,
        exitCode: String,
        endTime: Date? = nil,
        elapsed: TimeInterval? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.exitCode = exitCode
        self.endTime = endTime
        self.elapsed = elapsed
    }
}

/// Point-in-time snapshot of active and recently ended jobs on one cluster.
public struct ClusterSnapshot: Codable, Hashable, Sendable {
    public var clusterID: UUID
    public var fetchedAt: Date
    public var active: [ActiveJob]
    public var ended: [EndedJob]

    public init(
        clusterID: UUID,
        fetchedAt: Date,
        active: [ActiveJob] = [],
        ended: [EndedJob] = []
    ) {
        self.clusterID = clusterID
        self.fetchedAt = fetchedAt
        self.active = active
        self.ended = ended
    }
}
