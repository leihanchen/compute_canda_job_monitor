import Foundation
import SlurmMonitorCore
import Testing

private func makeTempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("MonitorModelTests-\(UUID().uuidString)")
}

private func makeCluster(
    id: UUID = UUID(),
    name: String,
    enabled: Bool = true,
    methods: [ConnectionMethodKind] = [.sharedSSH]
) -> ClusterConfig {
    ClusterConfig(
        id: id,
        name: name,
        host: "\(name).alliancecan.ca",
        username: "leihan",
        enabled: enabled,
        methods: methods
    )
}

private func makeActiveJob(
    id: String,
    name: String = "job",
    state: JobState,
    gpus: Int? = nil
) -> ActiveJob {
    ActiveJob(
        id: id,
        name: name,
        state: state,
        partition: "compute",
        account: "def-leihan",
        elapsed: 600,
        timeLimit: 3600,
        gpus: gpus,
        reasonOrNodes: state == .pending ? "(Priority)" : "node01"
    )
}

private func makeEndedJob(
    id: String,
    endTime: Date
) -> EndedJob {
    EndedJob(
        id: id,
        name: "ended-\(id)",
        state: .completed,
        exitCode: "0:0",
        endTime: endTime,
        elapsed: 300
    )
}

private let cannedSlurmOutput = """
@@ACTIVE
4321|train_llm|RUNNING|gpubase_bygpu_b3|def-leihan_gpu|21:00:00|1-00:00:00|1|32|128G|gres/gpu:4|ng10201|2026-11-24T10:00:00|2026-11-24T18:00:00|/home/leihan/run
4322_7|eval_big|PENDING|cpubase_bycore_b1|rrg-leihan|0:00|10:00:00|2|64|256G|N/A|(Priority)|2026-11-25T09:00:00|N/A|/home/leihan
@@START
4322_7|2026-11-25T18:30:00
@@ENDED
4100|sweep_06|COMPLETED|0:0|2026-11-25T14:00:00|05:00:00
@@DONE
"""

private let squeueFailureOutput = """
@@ACTIVE
@@ERR squeue 127
@@START
@@ENDED
@@DONE
"""

private actor ConcurrencyTracker {
    private var inFlight = 0
    private var maxSeen = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let expectedConcurrent: Int

    init(expectedConcurrent: Int) {
        self.expectedConcurrent = expectedConcurrent
    }

    func enterAndAwaitPeer() async {
        inFlight += 1
        maxSeen = max(maxSeen, inFlight)
        if inFlight >= expectedConcurrent {
            let pending = waiters
            waiters.removeAll()
            for continuation in pending {
                continuation.resume()
            }
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    func leave() {
        inFlight -= 1
    }

    func maxConcurrent() -> Int {
        maxSeen
    }
}

private actor AsyncGate {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false

    func arriveAndWait() async {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        if !released {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
    }

    func waitUntilEntered() async {
        if !entered {
            await withCheckedContinuation { continuation in
                enteredContinuation = continuation
            }
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
@Test func offlineStartShowsCachedAsStale() throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = ClusterStore(fileURL: dir.appendingPathComponent("clusters.json"))
    let cache = SnapshotCache(directory: dir.appendingPathComponent("cache"))

    let nibi = makeCluster(name: "nibi")
    let narval = makeCluster(name: "narval")
    let fir = makeCluster(name: "fir")
    let disabled = makeCluster(name: "tamia", enabled: false)

    let nibiSnap = ClusterSnapshot(
        clusterID: nibi.id,
        fetchedAt: now.addingTimeInterval(-300),
        active: [
            makeActiveJob(id: "1", state: .running, gpus: 4),
            makeActiveJob(id: "2", state: .completing, gpus: 2),
            makeActiveJob(id: "3", state: .pending, gpus: nil),
        ],
        ended: [makeEndedJob(id: "e1", endTime: now.addingTimeInterval(-600))]
    )
    let narvalSnap = ClusterSnapshot(
        clusterID: narval.id,
        fetchedAt: now.addingTimeInterval(-900),
        active: [makeActiveJob(id: "4", state: .running, gpus: 1)],
        ended: [makeEndedJob(id: "e2", endTime: now.addingTimeInterval(-1200))]
    )
    let disabledSnap = ClusterSnapshot(
        clusterID: disabled.id,
        fetchedAt: now.addingTimeInterval(-100),
        active: [makeActiveJob(id: "5", state: .running, gpus: 8)],
        ended: []
    )

    try cache.save(nibiSnap)
    try cache.save(narvalSnap)
    try cache.save(disabledSnap)
    try store.save([nibi, narval, fir, disabled])

    let model = MonitorModel(
        store: store,
        cache: cache,
        transports: { _ in [] },
        now: { now }
    )

    #expect(model.clusters.count == 4)
    #expect(model.clusters[0].status == .stale)
    #expect(model.clusters[0].snapshot == nibiSnap)
    #expect(model.clusters[0].methodInUse == nil)

    #expect(model.clusters[1].status == .stale)
    #expect(model.clusters[1].snapshot == narvalSnap)

    #expect(model.clusters[2].status == .error(.needsLogin))
    #expect(model.clusters[2].snapshot == nil)

    #expect(model.clusters[3].status == .stale)
    #expect(model.clusters[3].snapshot == disabledSnap)
    #expect(model.lastError.isEmpty)

    let dashboard = model.dashboard
    #expect(dashboard.enabledCount == 3)
    #expect(dashboard.liveCount == 0)
    #expect(model.liveCount() == 0)
    #expect(dashboard.hasStale == true)
    #expect(dashboard.runningCount == 3)
    #expect(dashboard.pendingCount == 1)
    #expect(dashboard.gpusInUse == 7)
    #expect(dashboard.menuBarText == "▶ 3  ⏸ 1")
    #expect(dashboard.recentlyEnded.map(\.job.id) == ["e1", "e2"])
}

@MainActor
@Test func successfulRefreshGoesLive() async throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = ClusterStore(fileURL: dir.appendingPathComponent("clusters.json"))
    let cache = SnapshotCache(directory: dir.appendingPathComponent("cache"))
    let nibi = makeCluster(name: "nibi")
    try store.save([nibi])

    let transport = FakeTransport(
        kind: .sharedSSH,
        probeResult: .usable,
        runResult: .success(cannedSlurmOutput)
    )

    let model = MonitorModel(
        store: store,
        cache: cache,
        transports: { _ in [transport] },
        now: { now }
    )

    #expect(model.clusters[0].status == .error(.needsLogin))

    await model.refresh(nibi.id, .manual)

    #expect(transport.probeCount == 1)
    #expect(transport.runCount == 1)
    #expect(transport.scripts == [SlurmQuery.remoteScript])
    #expect(transport.timeouts == [15])

    #expect(model.clusters[0].status == .live)
    #expect(model.clusters[0].methodInUse == .sharedSSH)
    #expect(model.lastError[nibi.id] == nil)
    #expect(model.liveCount() == 1)

    let snapshot = try #require(model.clusters[0].snapshot)
    #expect(snapshot.clusterID == nibi.id)
    #expect(snapshot.fetchedAt == now)
    #expect(snapshot.active.map(\.id) == ["4321", "4322_7"])
    #expect(snapshot.ended.map(\.id) == ["4100"])
    #expect(cache.load(nibi.id) == snapshot)

    // Simulate app relaunch from disk cache
    let relaunched = MonitorModel(
        store: store,
        cache: cache,
        transports: { _ in [] },
        now: { now.addingTimeInterval(120) }
    )
    #expect(relaunched.clusters[0].status == .stale)
    #expect(relaunched.clusters[0].snapshot == snapshot)
    #expect(relaunched.dashboard.runningCount == 1)
    #expect(relaunched.dashboard.pendingCount == 1)
    #expect(relaunched.dashboard.gpusInUse == 4)
}

@MainActor
@Test func unusableKeepsSnapshot() async throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = ClusterStore(fileURL: dir.appendingPathComponent("clusters.json"))
    let cache = SnapshotCache(directory: dir.appendingPathComponent("cache"))

    let nibi = makeCluster(name: "nibi")
    let fir = makeCluster(name: "fir")
    let cachedSnap = ClusterSnapshot(
        clusterID: nibi.id,
        fetchedAt: now.addingTimeInterval(-300),
        active: [makeActiveJob(id: "777", state: .running, gpus: 2)],
        ended: []
    )
    try cache.save(cachedSnap)
    try store.save([nibi, fir])

    let nibiTransport = FakeTransport(kind: .sharedSSH, probeResult: .unavailable(.needsLogin))
    let firTransport = FakeTransport(kind: .sharedSSH, probeResult: .unavailable(.unreachable))

    let model = MonitorModel(
        store: store,
        cache: cache,
        transports: { config in
            config.id == nibi.id ? [nibiTransport] : [firTransport]
        },
        now: { now }
    )

    await model.refreshAll(.manual)

    #expect(nibiTransport.probeCount == 1)
    #expect(nibiTransport.runCount == 0)
    #expect(model.clusters[0].status == .stale)
    #expect(model.clusters[0].snapshot == cachedSnap)
    #expect(model.clusters[0].methodInUse == nil)
    #expect(model.lastError[nibi.id] == .needsLogin)
    #expect(cache.load(nibi.id) == cachedSnap)

    #expect(firTransport.probeCount == 1)
    #expect(firTransport.runCount == 0)
    #expect(model.clusters[1].status == .error(.unreachable))
    #expect(model.clusters[1].snapshot == nil)
    #expect(model.lastError[fir.id] == .unreachable)

    // Subsequent success clears lastError
    nibiTransport.probeResult = .usable
    nibiTransport.runResult = .success(cannedSlurmOutput)
    await model.refresh(nibi.id, .afterLogin)
    #expect(model.clusters[0].status == .live)
    #expect(model.clusters[0].methodInUse == .sharedSSH)
    #expect(model.lastError[nibi.id] == nil)

    // Subsequent failure after going live reverts to .stale while keeping latest snapshot
    let liveSnap = try #require(model.clusters[0].snapshot)
    nibiTransport.probeResult = .unavailable(.unreachable)
    await model.refresh(nibi.id, .background)
    #expect(model.clusters[0].status == .stale)
    #expect(model.clusters[0].snapshot == liveSnap)
    #expect(model.clusters[0].methodInUse == nil)
    #expect(model.lastError[nibi.id] == .unreachable)
}

@MainActor
@Test func slurmFailureKeepsSnapshot() async throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = ClusterStore(fileURL: dir.appendingPathComponent("clusters.json"))
    let cache = SnapshotCache(directory: dir.appendingPathComponent("cache"))

    let nibi = makeCluster(name: "nibi")
    let narval = makeCluster(name: "narval")
    let cachedSnap = ClusterSnapshot(
        clusterID: nibi.id,
        fetchedAt: now.addingTimeInterval(-120),
        active: [makeActiveJob(id: "555", state: .running, gpus: 4)],
        ended: []
    )
    try cache.save(cachedSnap)
    try store.save([nibi, narval])

    let nibiTransport = FakeTransport(
        kind: .sharedSSH,
        probeResult: .usable,
        runResult: .success(squeueFailureOutput)
    )
    let narvalTransport = FakeTransport(
        kind: .sharedSSH,
        probeResult: .usable,
        runResult: .success(squeueFailureOutput)
    )

    let model = MonitorModel(
        store: store,
        cache: cache,
        transports: { config in
            config.id == nibi.id ? [nibiTransport] : [narvalTransport]
        },
        now: { now }
    )

    await model.refresh(nibi.id, .manual)
    #expect(model.clusters[0].status == .stale)
    #expect(model.clusters[0].snapshot == cachedSnap)
    #expect(model.lastError[nibi.id] == .slurmFailed("@@ERR squeue 127"))
    #expect(cache.load(nibi.id) == cachedSnap)

    await model.refresh(narval.id, .manual)
    #expect(model.clusters[1].status == .error(.slurmFailed("@@ERR squeue 127")))
    #expect(model.clusters[1].snapshot == nil)
    #expect(model.lastError[narval.id] == .slurmFailed("@@ERR squeue 127"))

    // Malformed output also preserves snapshot and sets .slurmFailed
    nibiTransport.runResult = .success("@@ACTIVE\ntruncated")
    await model.refresh(nibi.id, .manual)
    #expect(model.clusters[0].status == .stale)
    #expect(model.clusters[0].snapshot == cachedSnap)
    if case .slurmFailed = model.lastError[nibi.id] {
        // expected
    } else {
        Issue.record("Expected .slurmFailed for malformed output, got \(String(describing: model.lastError[nibi.id]))")
    }

    // Transport run failure preserves snapshot and records classified ClusterError
    nibiTransport.runResult = .failure(ClusterError.noAccess)
    await model.refresh(nibi.id, .manual)
    #expect(model.clusters[0].status == .stale)
    #expect(model.clusters[0].snapshot == cachedSnap)
    #expect(model.lastError[nibi.id] == .noAccess)
}

@Test func policy() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(RefreshPolicy.panelOpenThreshold == 60)
    #expect(RefreshPolicy.shouldRefresh(reason: .panelOpened, lastFetched: nil, now: now, isLoggingIn: false))
    #expect(!RefreshPolicy.shouldRefresh(reason: .panelOpened, lastFetched: now.addingTimeInterval(-30), now: now, isLoggingIn: false))
    #expect(!RefreshPolicy.shouldRefresh(reason: .panelOpened, lastFetched: now.addingTimeInterval(-60), now: now, isLoggingIn: false))
    #expect(RefreshPolicy.shouldRefresh(reason: .panelOpened, lastFetched: now.addingTimeInterval(-61), now: now, isLoggingIn: false))

    for reason in [RefreshReason.background, .manual, .afterLogin, .wakeOrNetwork] {
        #expect(RefreshPolicy.shouldRefresh(reason: reason, lastFetched: now.addingTimeInterval(-5), now: now, isLoggingIn: false))
        #expect(!RefreshPolicy.shouldRefresh(reason: reason, lastFetched: nil, now: now, isLoggingIn: true))
    }
    #expect(!RefreshPolicy.shouldRefresh(reason: .panelOpened, lastFetched: nil, now: now, isLoggingIn: true))
}

@MainActor
@Test func refreshRespectsPolicyAndSkipsDisabledClusters() async throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = ClusterStore(fileURL: dir.appendingPathComponent("clusters.json"))
    let cache = SnapshotCache(directory: dir.appendingPathComponent("cache"))

    let recentCluster = makeCluster(name: "nibi")
    let disabledCluster = makeCluster(name: "disabled", enabled: false)

    try cache.save(
        ClusterSnapshot(clusterID: recentCluster.id, fetchedAt: now.addingTimeInterval(-30))
    )
    try store.save([recentCluster, disabledCluster])

    let recentTransport = FakeTransport(
        kind: .sharedSSH,
        probeResult: .usable,
        runResult: .success(cannedSlurmOutput)
    )
    let disabledTransport = FakeTransport(
        kind: .sharedSSH,
        probeResult: .usable,
        runResult: .success(cannedSlurmOutput)
    )

    let model = MonitorModel(
        store: store,
        cache: cache,
        transports: { config in
            config.id == recentCluster.id ? [recentTransport] : [disabledTransport]
        },
        now: { now }
    )

    await model.refreshAll(.panelOpened)
    #expect(recentTransport.probeCount == 0)
    #expect(recentTransport.runCount == 0)
    #expect(disabledTransport.probeCount == 0)
    #expect(disabledTransport.runCount == 0)

    await model.refresh(disabledCluster.id, .manual)
    #expect(disabledTransport.probeCount == 0)
    #expect(disabledTransport.runCount == 0)

    await model.refresh(UUID(), .manual)

    await model.refreshAll(.manual)
    #expect(recentTransport.probeCount == 1)
    #expect(recentTransport.runCount == 1)
    #expect(disabledTransport.probeCount == 0)
    #expect(disabledTransport.runCount == 0)
    #expect(model.clusters[0].status == .live)
}

@MainActor
@Test func refreshAllRunsEnabledClustersConcurrently() async throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = ClusterStore(fileURL: dir.appendingPathComponent("clusters.json"))
    let cache = SnapshotCache(directory: dir.appendingPathComponent("cache"))

    let c1 = makeCluster(name: "nibi")
    let c2 = makeCluster(name: "narval")
    let c3 = makeCluster(name: "disabled", enabled: false)
    try store.save([c1, c2, c3])

    let tracker = ConcurrencyTracker(expectedConcurrent: 2)
    let t1 = FakeTransport(
        kind: .sharedSSH,
        probeResult: .usable,
        runHandler: { _, _ in
            await tracker.enterAndAwaitPeer()
            await tracker.leave()
            return cannedSlurmOutput
        }
    )
    let t2 = FakeTransport(
        kind: .sharedSSH,
        probeResult: .usable,
        runHandler: { _, _ in
            await tracker.enterAndAwaitPeer()
            await tracker.leave()
            return cannedSlurmOutput
        }
    )
    let t3 = FakeTransport(kind: .sharedSSH, probeResult: .usable, runResult: .success(cannedSlurmOutput))

    let model = MonitorModel(
        store: store,
        cache: cache,
        transports: { config in
            switch config.id {
            case c1.id: [t1]
            case c2.id: [t2]
            default: [t3]
            }
        },
        now: { now }
    )

    await model.refreshAll(.manual)

    #expect(await tracker.maxConcurrent() == 2)
    #expect(model.clusters[0].status == .live)
    #expect(model.clusters[1].status == .live)
    #expect(model.clusters[2].status == .error(.needsLogin))
    #expect(t3.probeCount == 0)
    #expect(model.liveCount() == 2)
}

@MainActor
@Test func setLoggingInRestoresPreviousStatusAndGuardsInFlightRefresh() async throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = ClusterStore(fileURL: dir.appendingPathComponent("clusters.json"))
    let cache = SnapshotCache(directory: dir.appendingPathComponent("cache"))

    let nibi = makeCluster(name: "nibi")
    let cachedSnap = ClusterSnapshot(
        clusterID: nibi.id,
        fetchedAt: now.addingTimeInterval(-300),
        active: [makeActiveJob(id: "10", state: .running, gpus: 1)],
        ended: []
    )
    try cache.save(cachedSnap)
    try store.save([nibi])

    let gate = AsyncGate()
    let transport = FakeTransport(
        kind: .sharedSSH,
        probeResult: .usable,
        runHandler: { _, _ in
            await gate.arriveAndWait()
            return cannedSlurmOutput
        }
    )

    let model = MonitorModel(
        store: store,
        cache: cache,
        transports: { _ in [transport] },
        now: { now }
    )

    model.setLoggingIn(nibi.id, true)
    #expect(model.clusters[0].status == .loggingIn)
    model.setLoggingIn(nibi.id, true)
    await model.refresh(nibi.id, .background)
    #expect(transport.probeCount == 0)
    #expect(transport.runCount == 0)

    model.setLoggingIn(nibi.id, false)
    #expect(model.clusters[0].status == .stale)
    #expect(transport.runCount == 0)

    // In-flight refresh started before login must not overwrite .loggingIn when it finishes
    let refreshTask = Task {
        await model.refresh(nibi.id, .manual)
    }
    await gate.waitUntilEntered()
    model.setLoggingIn(nibi.id, true)
    #expect(model.clusters[0].status == .loggingIn)

    await gate.release()
    await refreshTask.value

    #expect(model.clusters[0].status == .loggingIn)
    #expect(model.clusters[0].snapshot == cachedSnap)

    model.setLoggingIn(nibi.id, false)
    #expect(model.clusters[0].status == .stale)
}

@MainActor
@Test func setLoggingInRestoresPreviousErrorStatusAndDefaultNowWorks() async throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ClusterStore(fileURL: dir.appendingPathComponent("clusters.json"))
    let cache = SnapshotCache(directory: dir.appendingPathComponent("cache"))
    let fir = makeCluster(name: "fir")
    try store.save([fir])

    let transport = FakeTransport(kind: .sharedSSH, probeResult: .unavailable(.unreachable))
    let model = MonitorModel(store: store, cache: cache, transports: { _ in [transport] })

    await model.refresh(fir.id, .manual)
    #expect(model.clusters[0].status == .error(.unreachable))

    model.setLoggingIn(fir.id, true)
    #expect(model.clusters[0].status == .loggingIn)
    model.setLoggingIn(fir.id, false)
    #expect(model.clusters[0].status == .error(.unreachable))
}

@MainActor
@Test func reloadClustersAndSetClusters() async throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let storeURL = dir.appendingPathComponent("clusters.json")
    let store = ClusterStore(fileURL: storeURL)
    let cache = SnapshotCache(directory: dir.appendingPathComponent("cache"))

    let c1 = makeCluster(name: "nibi")
    let c2 = makeCluster(name: "fir")
    let snap1 = ClusterSnapshot(clusterID: c1.id, fetchedAt: now.addingTimeInterval(-120))
    try cache.save(snap1)

    let t1 = FakeTransport(kind: .sharedSSH, probeResult: .usable, runResult: .success(cannedSlurmOutput))
    let t2 = FakeTransport(kind: .sharedSSH, probeResult: .unavailable(.noAccess))

    let model = MonitorModel(
        store: store,
        cache: cache,
        transports: { config in
            config.id == c1.id ? [t1] : [t2]
        },
        now: { now }
    )
    #expect(model.clusters.isEmpty)

    try store.save([c1])
    try model.reloadClusters()
    #expect(model.clusters.count == 1)
    #expect(model.clusters[0].status == .stale)
    #expect(model.clusters[0].snapshot == snap1)

    await model.refresh(c1.id, .manual)
    #expect(model.clusters[0].status == .live)

    // setClusters persists to disk, preserves live c1, and adds c2
    try model.setClusters([c1, c2])
    #expect(try store.load() == [c1, c2])
    #expect(model.clusters.map(\.config) == [c1, c2])
    #expect(model.clusters[0].status == .live)
    #expect(model.clusters[1].status == .error(.needsLogin))

    await model.refresh(c2.id, .manual)
    #expect(model.lastError[c2.id] == .noAccess)

    // Removing c2 prunes its lastError
    try model.setClusters([c1])
    #expect(try store.load() == [c1])
    #expect(model.clusters.map(\.config) == [c1])
    #expect(model.lastError[c2.id] == nil)

    // Corrupt store throws on explicit reloadClusters(), while init stays resilient
    try Data("{bad json".utf8).write(to: storeURL)
    #expect(throws: Error.self) {
        try model.reloadClusters()
    }
    let fallbackModel = MonitorModel(store: store, cache: cache, transports: { _ in [] }, now: { now })
    #expect(fallbackModel.clusters.isEmpty)
}

@MainActor
@Test func connectionChainFallbackUpdatesMethodInUse() async throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = ClusterStore(fileURL: dir.appendingPathComponent("clusters.json"))
    let cache = SnapshotCache(directory: dir.appendingPathComponent("cache"))

    let c1 = makeCluster(name: "nibi", methods: [.robot, .sharedSSH])
    try store.save([c1])

    let robot = FakeTransport(kind: .robot, probeResult: .unavailable(.unreachable))
    let shared = FakeTransport(kind: .sharedSSH, probeResult: .usable, runResult: .success(cannedSlurmOutput))

    let model = MonitorModel(
        store: store,
        cache: cache,
        transports: { _ in [robot, shared] },
        now: { now }
    )

    await model.refresh(c1.id, .manual)
    #expect(robot.probeCount == 1)
    #expect(robot.runCount == 0)
    #expect(shared.probeCount == 1)
    #expect(shared.runCount == 1)
    #expect(model.clusters[0].status == .live)
    #expect(model.clusters[0].methodInUse == .sharedSSH)
}
