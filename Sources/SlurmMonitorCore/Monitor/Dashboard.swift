import Foundation

/// Current monitoring status of a cluster in the UI.
public enum ClusterStatus: Hashable, Sendable {
    case live
    case stale
    case loggingIn
    case error(ClusterError)
}

/// Snapshot and transport status paired with a cluster's configuration.
public struct ClusterView: Equatable, Hashable, Sendable {
    public var config: ClusterConfig
    public var status: ClusterStatus
    public var snapshot: ClusterSnapshot?
    public var methodInUse: ConnectionMethodKind?

    public init(
        config: ClusterConfig,
        status: ClusterStatus,
        snapshot: ClusterSnapshot? = nil,
        methodInUse: ConnectionMethodKind? = nil
    ) {
        self.config = config
        self.status = status
        self.snapshot = snapshot
        self.methodInUse = methodInUse
    }
}

/// Associates a job with the cluster it belongs to without cross-cluster deduplication.
public struct JobRef<J: Hashable & Sendable>: Hashable, Sendable {
    public var cluster: ClusterConfig
    public var job: J

    public init(cluster: ClusterConfig, job: J) {
        self.cluster = cluster
        self.job = job
    }
}

/// Aggregated cross-cluster job metrics and sorted sections for the menu bar and popover.
public struct Dashboard: Equatable, Sendable {
    public let runningCount: Int
    public let pendingCount: Int
    public let gpusInUse: Int
    public let endingSoon: [JobRef<ActiveJob>]
    public let waiting: [JobRef<ActiveJob>]
    public let recentlyEnded: [JobRef<EndedJob>]
    public let liveCount: Int
    public let enabledCount: Int
    public let hasStale: Bool
    public let menuBarText: String

    public init(clusters: [ClusterView], now: Date = Date()) {
        _ = now
        let enabledClusters = clusters.filter(\.config.enabled)

        var runningJobs: [JobRef<ActiveJob>] = []
        var pendingJobs: [JobRef<ActiveJob>] = []
        var endedJobs: [JobRef<EndedJob>] = []
        var gpuSum = 0
        var liveClusters = 0
        var staleDataPresent = false

        for view in enabledClusters {
            if view.status == .live {
                liveClusters += 1
            } else if view.status != .loggingIn, view.snapshot != nil {
                staleDataPresent = true
            }

            guard let snapshot = view.snapshot else { continue }

            for job in snapshot.active {
                let ref = JobRef(cluster: view.config, job: job)
                switch job.state {
                case .running, .completing:
                    runningJobs.append(ref)
                    gpuSum += job.gpus ?? 0
                case .pending:
                    pendingJobs.append(ref)
                default:
                    break
                }
            }

            for job in snapshot.ended {
                endedJobs.append(JobRef(cluster: view.config, job: job))
            }
        }

        self.runningCount = runningJobs.count
        self.pendingCount = pendingJobs.count
        self.gpusInUse = gpuSum
        self.endingSoon = runningJobs.sorted {
            Self.compareOptional(
                Self.remainingTime($0.job),
                Self.remainingTime($1.job),
                ascending: true
            )
        }
        self.waiting = pendingJobs.sorted {
            Self.compareOptional($0.job.estimatedStart, $1.job.estimatedStart, ascending: true)
        }
        self.recentlyEnded = Array(
            endedJobs.sorted {
                Self.compareOptional($0.job.endTime, $1.job.endTime, ascending: false)
            }.prefix(3)
        )
        self.liveCount = liveClusters
        self.enabledCount = enabledClusters.count
        self.hasStale = staleDataPresent
        self.menuBarText = "▶ \(runningJobs.count)  ⏸ \(pendingJobs.count)"
    }

    /// Formats a snapshot age in seconds into a compact human-readable label.
    public static func ageText(_ seconds: TimeInterval) -> String {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        if clamped < 60 {
            return "just now"
        }
        if clamped < 3_600 {
            return "\(Int(clamped / 60))m ago"
        }
        if clamped < 86_400 {
            return "\(Int(clamped / 3_600))h ago"
        }
        let days = Int(min(clamped, Double(Int.max)) / 86_400)
        return "\(days)d ago"
    }

    private static func remainingTime(_ job: ActiveJob) -> TimeInterval? {
        guard let limit = job.timeLimit else { return nil }
        return limit - (job.elapsed ?? 0)
    }

    private static func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?, ascending: Bool) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?):
            return ascending ? (left < right) : (left > right)
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return false
        }
    }
}
