import Foundation
import Testing
@testable import SlurmMonitorCore

private func makeCluster(
    id: UUID = UUID(),
    name: String,
    enabled: Bool = true
) -> ClusterConfig {
    ClusterConfig(
        id: id,
        name: name,
        host: "\(name).alliancecan.ca",
        username: "leihan",
        enabled: enabled
    )
}

private func makeActiveJob(
    id: String,
    name: String = "job",
    state: JobState,
    elapsed: TimeInterval? = nil,
    timeLimit: TimeInterval? = nil,
    gpus: Int? = nil,
    estimatedStart: Date? = nil
) -> ActiveJob {
    ActiveJob(
        id: id,
        name: name,
        state: state,
        partition: "compute",
        account: "def-prof",
        elapsed: elapsed,
        timeLimit: timeLimit,
        gpus: gpus,
        reasonOrNodes: state == .pending ? "(Priority)" : "node01",
        estimatedStart: estimatedStart
    )
}

private func makeEndedJob(
    id: String,
    name: String = "ended",
    state: JobState = .completed,
    endTime: Date?
) -> EndedJob {
    EndedJob(
        id: id,
        name: name,
        state: state,
        exitCode: state == .completed ? "0:0" : "1:0",
        endTime: endTime,
        elapsed: 600
    )
}

@Test func aggregatesAcrossClustersIncludingStale() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let nibi = makeCluster(name: "nibi")
    let narval = makeCluster(name: "narval")

    let nibiSnapshot = ClusterSnapshot(
        clusterID: nibi.id,
        fetchedAt: now,
        active: [
            makeActiveJob(id: "1", state: .running, gpus: 4),
            makeActiveJob(id: "2", state: .completing, gpus: nil),
            makeActiveJob(id: "3", state: .pending, gpus: 2),
        ],
        ended: [
            makeEndedJob(id: "e1", endTime: now.addingTimeInterval(-10 * 60)),
            makeEndedJob(id: "e2", endTime: now.addingTimeInterval(-3 * 3600)),
        ]
    )

    let narvalSnapshot = ClusterSnapshot(
        clusterID: narval.id,
        fetchedAt: now.addingTimeInterval(-1200),
        active: [
            makeActiveJob(id: "4", state: .running, gpus: 2),
        ],
        ended: [
            makeEndedJob(id: "e3", endTime: now.addingTimeInterval(-3600)),
            makeEndedJob(id: "e4", endTime: now.addingTimeInterval(-2 * 86_400)),
        ]
    )

    let views = [
        ClusterView(config: nibi, status: .live, snapshot: nibiSnapshot, methodInUse: .sharedSSH),
        ClusterView(config: narval, status: .stale, snapshot: narvalSnapshot, methodInUse: nil),
    ]

    let dashboard = Dashboard(clusters: views, now: now)
    #expect(dashboard.runningCount == 3)
    #expect(dashboard.pendingCount == 1)
    #expect(dashboard.gpusInUse == 6)
    #expect(dashboard.recentlyEnded.map(\.job.id) == ["e1", "e3", "e2"])
    #expect(dashboard.menuBarText == "▶ 3  ⏸ 1")
    #expect(dashboard.hasStale == true)
    #expect(dashboard.liveCount == 1)
    #expect(dashboard.enabledCount == 2)
}

@Test func excludesDisabledClustersAndTracksStaleStatusRules() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let disabled = makeCluster(name: "fir", enabled: false)
    let loggingIn = makeCluster(name: "rorqual", enabled: true)
    let errorNoSnap = makeCluster(name: "vulcan", enabled: true)
    let errorWithSnap = makeCluster(name: "killarney", enabled: true)

    let disabledSnap = ClusterSnapshot(
        clusterID: disabled.id,
        fetchedAt: now,
        active: [makeActiveJob(id: "d1", state: .running, gpus: 8)],
        ended: [makeEndedJob(id: "de1", endTime: now)]
    )
    let loggingInSnap = ClusterSnapshot(
        clusterID: loggingIn.id,
        fetchedAt: now.addingTimeInterval(-300),
        active: [makeActiveJob(id: "l1", state: .pending)],
        ended: []
    )
    let errorSnap = ClusterSnapshot(
        clusterID: errorWithSnap.id,
        fetchedAt: now.addingTimeInterval(-900),
        active: [makeActiveJob(id: "k1", state: .running, gpus: 1)],
        ended: []
    )

    let loggingInDashboard = Dashboard(
        clusters: [
            ClusterView(config: disabled, status: .stale, snapshot: disabledSnap),
            ClusterView(config: loggingIn, status: .loggingIn, snapshot: loggingInSnap),
            ClusterView(config: errorNoSnap, status: .error(.needsLogin), snapshot: nil),
        ],
        now: now
    )
    #expect(loggingInDashboard.enabledCount == 2)
    #expect(loggingInDashboard.liveCount == 0)
    #expect(loggingInDashboard.runningCount == 0)
    #expect(loggingInDashboard.pendingCount == 1)
    #expect(loggingInDashboard.gpusInUse == 0)
    #expect(loggingInDashboard.recentlyEnded.isEmpty)
    #expect(loggingInDashboard.hasStale == false)

    let errorDashboard = Dashboard(
        clusters: [
            ClusterView(config: disabled, status: .live, snapshot: disabledSnap),
            ClusterView(config: errorWithSnap, status: .error(.unreachable), snapshot: errorSnap),
        ],
        now: now
    )
    #expect(errorDashboard.enabledCount == 1)
    #expect(errorDashboard.liveCount == 0)
    #expect(errorDashboard.runningCount == 1)
    #expect(errorDashboard.gpusInUse == 1)
    #expect(errorDashboard.hasStale == true)
}

@Test func doesNotDeduplicateJobsAcrossClusters() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let trillium = makeCluster(name: "trillium")
    let trilliumGPU = makeCluster(name: "trillium-gpu")

    let sharedJob = makeActiveJob(id: "55555", name: "train", state: .running, elapsed: 100, timeLimit: 1000, gpus: 4)
    let sharedEnded = makeEndedJob(id: "44444", name: "eval", endTime: now.addingTimeInterval(-60))

    let views = [
        ClusterView(
            config: trillium,
            status: .live,
            snapshot: ClusterSnapshot(clusterID: trillium.id, fetchedAt: now, active: [sharedJob], ended: [sharedEnded])
        ),
        ClusterView(
            config: trilliumGPU,
            status: .live,
            snapshot: ClusterSnapshot(clusterID: trilliumGPU.id, fetchedAt: now, active: [sharedJob], ended: [sharedEnded])
        ),
    ]

    let dashboard = Dashboard(clusters: views, now: now)
    #expect(dashboard.runningCount == 2)
    #expect(dashboard.gpusInUse == 8)
    #expect(dashboard.endingSoon.count == 2)
    #expect(dashboard.endingSoon.map(\.cluster.name) == ["trillium", "trillium-gpu"])
    #expect(dashboard.recentlyEnded.count == 2)
}

@Test func endingSoonOrder() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let cluster = makeCluster(name: "nibi")

    let jobA = makeActiveJob(id: "A", state: .running, elapsed: 21 * 3600, timeLimit: 24 * 3600)
    let jobB = makeActiveJob(id: "B", state: .running, elapsed: 6 * 3600, timeLimit: 10 * 3600)
    let jobC = makeActiveJob(id: "C", state: .running, elapsed: 1 * 3600, timeLimit: nil)
    let jobD = makeActiveJob(id: "D", state: .completing, elapsed: nil, timeLimit: 1 * 3600)
    let pending = makeActiveJob(id: "P", state: .pending, elapsed: nil, timeLimit: 60)

    let snapshot = ClusterSnapshot(
        clusterID: cluster.id,
        fetchedAt: now,
        active: [jobC, jobB, pending, jobA, jobD],
        ended: []
    )
    let dashboard = Dashboard(
        clusters: [ClusterView(config: cluster, status: .live, snapshot: snapshot)],
        now: now
    )

    // Remaining: D = 1h - 0 = 1h, A = 3h, B = 4h, C = nil
    #expect(dashboard.endingSoon.map(\.job.id) == ["D", "A", "B", "C"])
}

@Test func waitingOrderAndRecentlyEndedNilLast() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let cluster = makeCluster(name: "narval")

    let pLater = makeActiveJob(id: "P2", state: .pending, estimatedStart: now.addingTimeInterval(3600))
    let pSooner = makeActiveJob(id: "P1", state: .pending, estimatedStart: now.addingTimeInterval(600))
    let pNoEstimate = makeActiveJob(id: "P3", state: .pending, estimatedStart: nil)

    let eOlder = makeEndedJob(id: "E2", endTime: now.addingTimeInterval(-7200))
    let eRecent = makeEndedJob(id: "E1", endTime: now.addingTimeInterval(-300))
    let eNoEnd = makeEndedJob(id: "E3", endTime: nil)

    let snapshot = ClusterSnapshot(
        clusterID: cluster.id,
        fetchedAt: now,
        active: [pNoEstimate, pLater, pSooner],
        ended: [eNoEnd, eOlder, eRecent]
    )

    let dashboard = Dashboard(
        clusters: [ClusterView(config: cluster, status: .live, snapshot: snapshot)],
        now: now
    )

    #expect(dashboard.waiting.map(\.job.id) == ["P1", "P2", "P3"])
    #expect(dashboard.recentlyEnded.map(\.job.id) == ["E1", "E2", "E3"])
}

@Test func cacheSurvivesRelaunch() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("snapshots")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snap = ClusterSnapshot(
        clusterID: UUID(),
        fetchedAt: now,
        active: [makeActiveJob(id: "123", state: .running, elapsed: 120, timeLimit: 3600, gpus: 2)],
        ended: [makeEndedJob(id: "122", state: .completed, endTime: now.addingTimeInterval(-60))]
    )

    try SnapshotCache(directory: dir).save(snap)

    let expectedFile = dir.appendingPathComponent("\(snap.clusterID.uuidString).json")
    #expect(FileManager.default.fileExists(atPath: expectedFile.path))
    #expect(SnapshotCache(directory: dir).load(snap.clusterID) == snap)
}

@Test func cacheReturnsNilWhenMissingOrCorrupt() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let cache = SnapshotCache(directory: dir)
    let missingID = UUID()
    #expect(cache.load(missingID) == nil)

    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let corruptID = UUID()
    let corruptURL = dir.appendingPathComponent("\(corruptID.uuidString).json")
    try Data("{corrupt json".utf8).write(to: corruptURL)
    #expect(cache.load(corruptID) == nil)
}

@Test func ages() {
    #expect(Dashboard.ageText(-42) == "just now")
    #expect(Dashboard.ageText(0) == "just now")
    #expect(Dashboard.ageText(30) == "just now")
    #expect(Dashboard.ageText(59) == "just now")
    #expect(Dashboard.ageText(60) == "1m ago")
    #expect(Dashboard.ageText(3599) == "59m ago")
    #expect(Dashboard.ageText(3600) == "1h ago")
    #expect(Dashboard.ageText(3700) == "1h ago")
    #expect(Dashboard.ageText(86_399) == "23h ago")
    #expect(Dashboard.ageText(86_400) == "1d ago")
    #expect(Dashboard.ageText(200_000) == "2d ago")
}
