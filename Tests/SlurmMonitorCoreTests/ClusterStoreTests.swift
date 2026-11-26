import Foundation
import Testing
@testable import SlurmMonitorCore

@Test func storeRoundTripsClusters() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("clusters.json")
    let store = ClusterStore(fileURL: url)
    #expect(try store.load() == [])
    let c = ClusterConfig(name: "trillium-gpu", host: "trillium-gpu.scinet.utoronto.ca", username: "leihan", requiresKey: true)
    try store.save([c])
    #expect(try store.load() == [c])
}

@Test func storeCreatesNestedParentDirAndOverwrites() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("nested/config/clusters.json")
    let store = ClusterStore(fileURL: url)

    let first = ClusterConfig(name: "narval", host: "narval.alliancecan.ca", username: "leihan", methods: [.sharedSSH, .robot])
    let second = ClusterConfig(name: "fir", host: "fir.alliancecan.ca", username: "leihan", identityFile: "~/.ssh/id_ed25519", enabled: false)

    try store.save([first])
    #expect(try store.load() == [first])

    try store.save([second])
    #expect(try store.load() == [second])
}

@Test func storeThrowsOnCorruptJSON() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("clusters.json")
    try Data("{not valid json".utf8).write(to: url)

    let store = ClusterStore(fileURL: url)
    #expect(throws: Error.self) {
        _ = try store.load()
    }
}

@Test func sshTargetAndAlias() {
    let c = ClusterConfig(name: "Trillium GPU", host: "trillium-gpu.scinet.utoronto.ca", username: "leihan")
    #expect(c.sshTarget == "leihan@trillium-gpu.scinet.utoronto.ca")
    #expect(c.generatedAlias == "smon-trillium-gpu")
    #expect(c.enabled == true)
    #expect(c.methods == [.sharedSSH])
    #expect(c.requiresKey == false)
    #expect(c.sshAlias == nil)
    #expect(c.identityFile == nil)
    var d = c
    d.sshAlias = "trillium-gpu"
    #expect(d.sshTarget == "trillium-gpu")
}

@Test func settingsDefaults() {
    let s = AppSettings()
    #expect(s.refreshIntervalMinutes == 5 && s.stayAwakeWhilePluggedIn == false && s.launchAtLogin == false)
    #expect(s.showInDock == true)
}

@Test func settingsFromOlderVersionKeepValuesAndDefaultShowInDock() throws {
    let suiteName = "ClusterStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let legacy = #"{"refreshIntervalMinutes":12,"stayAwakeWhilePluggedIn":true,"launchAtLogin":false}"#
    defaults.set(Data(legacy.utf8), forKey: "appSettings")
    let loaded = AppSettings.load(from: defaults)
    #expect(loaded.refreshIntervalMinutes == 12)
    #expect(loaded.stayAwakeWhilePluggedIn == true)
    #expect(loaded.showInDock == true)
}

@Test func settingsRoundTripsUserDefaults() throws {
    let suiteName = "ClusterStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(AppSettings.load(from: defaults) == AppSettings())

    let custom = AppSettings(refreshIntervalMinutes: 10, stayAwakeWhilePluggedIn: true, launchAtLogin: true, showInDock: false)
    custom.save(to: defaults)
    #expect(AppSettings.load(from: defaults) == custom)
}
