import Combine
import Foundation

/// Observable state coordinator for monitored Slurm clusters, offline cache hydration, and refresh execution.
@MainActor
public final class MonitorModel: ObservableObject {
    private static let queryTimeout: TimeInterval = 15

    @Published public private(set) var clusters: [ClusterView] = []
    @Published public private(set) var lastError: [UUID: ClusterError] = [:]

    /// Aggregated dashboard metrics computed from the current cluster views.
    public var dashboard: Dashboard {
        Dashboard(clusters: clusters, now: now())
    }

    private let store: ClusterStore
    private let cache: SnapshotCache
    private let transports: @Sendable (ClusterConfig) -> [ClusterTransport]
    private let now: @Sendable () -> Date

    private var preLoginStatus: [UUID: ClusterStatus] = [:]
    private var stateEpoch: [UUID: UInt64] = [:]

    public init(
        store: ClusterStore,
        cache: SnapshotCache,
        transports: @escaping @Sendable (ClusterConfig) -> [ClusterTransport],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.cache = cache
        self.transports = transports
        self.now = now

        let loadedConfigs = (try? store.load()) ?? []
        applyClusters(loadedConfigs)
    }

    /// Reloads cluster configurations from `store`, throwing on disk or JSON decode failure.
    public func reloadClusters() throws {
        let loadedConfigs = try store.load()
        applyClusters(loadedConfigs)
    }

    /// Persists `configs` to `store` and updates monitored cluster views in memory.
    public func setClusters(_ configs: [ClusterConfig]) throws {
        try store.save(configs)
        applyClusters(configs)
    }

    /// Refreshes all enabled clusters concurrently for the given `reason`.
    public func refreshAll(_ reason: RefreshReason) async {
        let enabledIDs = clusters.filter(\.config.enabled).map(\.config.id)
        await withTaskGroup(of: Void.self) { group in
            for id in enabledIDs {
                group.addTask {
                    await self.refresh(id, reason)
                }
            }
        }
    }

    /// Refreshes a single cluster by `id` if enabled and permitted by `RefreshPolicy`.
    public func refresh(_ id: UUID, _ reason: RefreshReason) async {
        guard let index = clusters.firstIndex(where: { $0.config.id == id }) else {
            return
        }
        let view = clusters[index]
        guard view.config.enabled else {
            return
        }
        guard RefreshPolicy.shouldRefresh(
            reason: reason,
            lastFetched: view.snapshot?.fetchedAt,
            now: now(),
            isLoggingIn: view.status == .loggingIn
        ) else {
            return
        }

        let epoch = bumpEpoch(for: id)
        let clusterTransports = transports(view.config)

        let chainResult = await ConnectionChain(clusterTransports).firstUsable()
        guard !Task.isCancelled else { return }

        switch chainResult {
        case .failure(let error):
            recordFailure(id: id, epoch: epoch, error: error)
        case .success(let transport):
            do {
                let output = try await transport.run(SlurmQuery.remoteScript, timeout: Self.queryTimeout)
                guard !Task.isCancelled else { return }
                let fetchedAt = now()
                let snapshot = try SlurmQuery.parse(output, clusterID: id, fetchedAt: fetchedAt)
                recordSuccess(id: id, epoch: epoch, snapshot: snapshot, method: transport.kind)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                recordFailure(id: id, epoch: epoch, error: mapQueryError(error))
            }
        }
    }

    /// Toggles `.loggingIn` state for `id`, preserving and later restoring its prior status.
    public func setLoggingIn(_ id: UUID, _ value: Bool) {
        guard let index = clusters.firstIndex(where: { $0.config.id == id }) else {
            preLoginStatus.removeValue(forKey: id)
            return
        }

        if value {
            // Invalidate any in-flight refresh so its late completion cannot overwrite `.loggingIn`.
            _ = bumpEpoch(for: id)
            if clusters[index].status != .loggingIn {
                preLoginStatus[id] = clusters[index].status
                clusters[index].status = .loggingIn
            }
        } else {
            let previous = preLoginStatus.removeValue(forKey: id)
            if clusters[index].status == .loggingIn {
                let fallback: ClusterStatus = clusters[index].snapshot != nil ? .stale : .error(.needsLogin)
                clusters[index].status = previous ?? fallback
            }
        }
    }

    /// Number of enabled clusters currently in the `.live` state.
    public func liveCount() -> Int {
        dashboard.liveCount
    }

    private func applyClusters(_ configs: [ClusterConfig]) {
        let existingByID = Dictionary(
            clusters.map { ($0.config.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        clusters = configs.map { config in
            if var existing = existingByID[config.id] {
                let connectionChanged = existing.config.hasConnectionChange(comparedTo: config)

                if existing.snapshot == nil, let cached = cache.load(config.id) {
                    existing.snapshot = cached
                    if existing.status != .loggingIn {
                        existing.status = .stale
                    }
                }

                if connectionChanged || !config.enabled {
                    lastError.removeValue(forKey: config.id)
                    _ = bumpEpoch(for: config.id)
                    existing.methodInUse = nil
                    let resetStatus: ClusterStatus = existing.snapshot != nil ? .stale : .error(.needsLogin)
                    if existing.status == .loggingIn {
                        preLoginStatus[config.id] = resetStatus
                    } else {
                        existing.status = resetStatus
                    }
                }

                existing.config = config
                return existing
            } else {
                let cached = cache.load(config.id)
                let initialStatus: ClusterStatus = cached != nil ? .stale : .error(.needsLogin)
                return ClusterView(
                    config: config,
                    status: initialStatus,
                    snapshot: cached,
                    methodInUse: nil
                )
            }
        }

        let validIDs = Set(configs.map(\.id))
        lastError = lastError.filter { validIDs.contains($0.key) }
        preLoginStatus = preLoginStatus.filter { validIDs.contains($0.key) }
        stateEpoch = stateEpoch.filter { validIDs.contains($0.key) }
    }

    private func bumpEpoch(for id: UUID) -> UInt64 {
        let next = (stateEpoch[id] ?? 0) &+ 1
        stateEpoch[id] = next
        return next
    }

    private func canCommit(id: UUID, epoch: UInt64) -> Int? {
        guard stateEpoch[id] == epoch,
              let index = clusters.firstIndex(where: { $0.config.id == id }),
              clusters[index].config.enabled,
              clusters[index].status != .loggingIn
        else {
            return nil
        }
        return index
    }

    private func recordSuccess(
        id: UUID,
        epoch: UInt64,
        snapshot: ClusterSnapshot,
        method: ConnectionMethodKind
    ) {
        guard let index = canCommit(id: id, epoch: epoch) else { return }
        try? cache.save(snapshot)
        lastError.removeValue(forKey: id)
        clusters[index].status = .live
        clusters[index].snapshot = snapshot
        clusters[index].methodInUse = method
    }

    private func recordFailure(
        id: UUID,
        epoch: UInt64,
        error: ClusterError
    ) {
        guard let index = canCommit(id: id, epoch: epoch) else { return }
        lastError[id] = error
        clusters[index].methodInUse = nil
        clusters[index].status = clusters[index].snapshot != nil ? .stale : .error(error)
    }

    private func mapQueryError(_ error: Error) -> ClusterError {
        if let clusterError = error as? ClusterError {
            return clusterError
        }
        if let queryError = error as? SlurmQueryError {
            switch queryError {
            case .commandFailed(let message):
                return .slurmFailed(message)
            case .malformed:
                return .slurmFailed("Malformed Slurm output")
            }
        }
        return .slurmFailed(error.localizedDescription)
    }
}
