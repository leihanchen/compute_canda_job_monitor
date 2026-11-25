# Slurm Job Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu-bar app with a Zest-style floating panel showing the user's Slurm jobs (queued/running + last 3 ended) across clusters, reusing and keeping alive MFA-authenticated SSH connections so reconnections are rare and always user-initiated.

**Architecture:** SwiftPM package with a UI-free, unit-tested core library (`SlurmMonitorCore`: models, presets, SSH-config/ControlPath resolution, transports, Slurm parsing, caching, refresh policy, login PTY session) and a thin SwiftUI `MenuBarExtra` app target (`SlurmMonitorApp`). All SSH goes through `/usr/bin/ssh` with an app-generated config (`-F`) whose `ControlPath` matches the user's own when they have one. A shell script assembles and ad-hoc signs the `.app`.

**Tech Stack:** Swift 6.3 toolchain (Command Line Tools, no Xcode), SwiftPM (tools-version 6.0, Swift language mode 5), SwiftUI/AppKit, Swift Testing (`import Testing`), Network (`NWPathMonitor`), IOKit power APIs, ServiceManagement (`SMAppService`), system `ssh`/`ssh-keygen`/`ssh-add`.

**Spec:** `docs/superpowers/specs/2026-11-25-slurm-job-monitor-design.md`

## Global Constraints

- macOS 14+ deployment target; builds with Command Line Tools only (`swift build`, `swift test`) — no Xcode project.
- Panel is **read-only**: no cancel/hold/resubmit anywhere.
- The app **never** writes `~/.ssh/config`, never runs `ssh -O exit`, never closes a live connection; stale masters are freed with `ssh -O stop`.
- The app **never** starts an MFA login except from an explicit user click (Log in / Log in to all / Log in to stale clusters).
- Every app ssh call uses `-F ~/.slurm-monitor/ssh_config`; queries add `-o BatchMode=yes -o ControlMaster=no`.
- App data dir: `~/.slurm-monitor/` (short path; Unix socket path limit). App socket template: `~/.slurm-monitor/cm-%C`.
- Master keep-alive: `ServerAliveInterval 30`, `ServerAliveCountMax 20`, `ControlPersist yes`, `ConnectTimeout 10`.
- Query overall timeout 15 s. Panel-open refresh threshold 60 s. Background refresh/check-in every 5 min (setting, default 5).
- "Stay awake while plugged in" defaults **off**; uses `kIOPMAssertionTypePreventUserIdleSystemSleep` only while on AC and ≥1 cluster live.
- Never store passwords, passphrases or MFA codes.
- Recently ended = last **3** ended jobs across all clusters by end time, from `sacct -S now-7days`.
- trillium and trillium-gpu are separate clusters; no cross-cluster de-duplication.
- Robot transport: enum case and UI label only; no implementation.

## Review Focus

1. Job names containing `|`, spaces or Unicode → fields stay aligned, name shown intact (test in Task 3).
2. A cluster with zero jobs and no recent ended jobs → live with empty lists, not an error (test in Task 3).
3. Host without Slurm / `squeue` failing → cluster shows "Slurm command failed" and keeps its previous snapshot (tests in Tasks 3 and 7).
4. App relaunched while offline → cached snapshots appear immediately, marked stale with age; totals still computed (test in Task 7).
5. Background refresh firing while that cluster's login sheet is open → no query is sent to it (test in Task 8).

---

## File Structure

```
Package.swift
.gitignore
scripts/build-app.sh                         # assemble + ad-hoc sign .app
Resources/Info.plist                         # LSUIElement etc.
Sources/SlurmMonitorCore/
  Model/ClusterConfig.swift                  # ClusterConfig, ConnectionMethodKind
  Model/ClusterStore.swift                   # JSON persistence of clusters
  Model/AlliancePresets.swift                # built-in cluster list
  Model/AppSettings.swift                    # refresh interval, stay awake, launch at login
  SSH/SSHConfigImporter.swift                # parse Host/HostName/User from ~/.ssh/config
  SSH/ControlPathResolver.swift              # find user's ControlPath template, expand via ssh -G
  SSH/SSHGOutput.swift                       # parse `ssh -G` key/value output
  SSH/GeneratedSSHConfig.swift               # render/write ~/.slurm-monitor/ssh_config
  SSH/CommandRunner.swift                    # CommandRunner protocol + ProcessCommandRunner
  SSH/ClusterErrorClassifier.swift           # stderr → ClusterError
  Transport/ClusterTransport.swift           # protocol, TransportState, ConnectionChain
  Transport/SharedSSHTransport.swift
  Slurm/SlurmModels.swift                    # JobState, ActiveJob, EndedJob, ClusterSnapshot
  Slurm/SlurmTime.swift                      # duration/date parsing
  Slurm/SlurmQuery.swift                     # remote script + parser
  Monitor/SnapshotCache.swift
  Monitor/Dashboard.swift                    # aggregation for UI
  Monitor/RefreshPolicy.swift
  Monitor/MonitorModel.swift                 # @MainActor ObservableObject
  Login/PTYProcess.swift                     # openpty + posix_spawn with controlling tty
  Login/LoginPromptClassifier.swift
  Login/LoginSession.swift                   # drives ssh master login
  Keys/KeyManager.swift
  Power/PowerPolicy.swift
Sources/SlurmMonitorApp/
  SlurmMonitorApp.swift                      # @main, MenuBarExtra
  AppEnvironment.swift                       # wiring: paths, runner, stores, model
  Platform/StayAwakeController.swift
  Platform/SystemEventsMonitor.swift         # wake + network change
  Views/PanelView.swift                      # header, tabs, footer
  Views/OverviewTab.swift
  Views/JobsTab.swift
  Views/ClustersTab.swift
  Views/WelcomeView.swift
  Views/LoginSheet.swift
  Views/SettingsView.swift
  Views/Components.swift                     # Card, StatePill, TimeBar, StatusDot
Tests/SlurmMonitorCoreTests/
  Fixtures/ (inline string fixtures in test files)
  ClusterStoreTests.swift  SSHConfigImporterTests.swift  ControlPathResolverTests.swift
  GeneratedSSHConfigTests.swift  SlurmQueryTests.swift  SlurmTimeTests.swift
  TransportTests.swift  ClusterErrorClassifierTests.swift  DashboardTests.swift
  MonitorModelTests.swift  RefreshPolicyTests.swift  LoginPromptClassifierTests.swift
  PTYProcessTests.swift  KeyManagerTests.swift  PowerPolicyTests.swift
  Fakes.swift                                # FakeRunner, FakeTransport
```

Shared test fakes (`Tests/SlurmMonitorCoreTests/Fakes.swift`, created in Task 5 and extended later):
- `final class FakeRunner: CommandRunner` — records `calls: [(executable: String, args: [String], stdin: String?)]`, returns queued `CommandResult`s keyed by a predicate.
- `struct FakeTransport: ClusterTransport` — fixed `kind`, `probeResult: TransportState`, `runResult: Result<String, ClusterError>`, records `runCount`.

---

### Task 1: Package scaffold, cluster model and store

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/SlurmMonitorCore/Model/ClusterConfig.swift`, `Sources/SlurmMonitorCore/Model/ClusterStore.swift`, `Sources/SlurmMonitorCore/Model/AppSettings.swift`, `Sources/SlurmMonitorApp/SlurmMonitorApp.swift` (placeholder `@main` with empty `MenuBarExtra("Slurm", systemImage: "server.rack") { Text("Loading") }`)
- Test: `Tests/SlurmMonitorCoreTests/ClusterStoreTests.swift`

**Interfaces:**
- Produces:
  - `public enum ConnectionMethodKind: String, Codable, Sendable { case sharedSSH, robot }`
  - `public struct ClusterConfig: Codable, Identifiable, Hashable, Sendable { id: UUID; name: String; host: String; username: String; sshAlias: String?; identityFile: String?; enabled: Bool; methods: [ConnectionMethodKind]; requiresKey: Bool }` with memberwise `public init` defaulting `id = UUID()`, `sshAlias = nil`, `identityFile = nil`, `enabled = true`, `methods = [.sharedSSH]`, `requiresKey = false`; computed `var sshTarget: String { sshAlias ?? "\(username)@\(host)" }` and `var generatedAlias: String` = `"smon-" + name` lowercased with non `[a-z0-9-]` replaced by `-`.
  - `public final class ClusterStore: Sendable { init(fileURL: URL); func load() throws -> [ClusterConfig]; func save(_ clusters: [ClusterConfig]) throws }` — missing file → `[]`; writes atomically, creating parent dir.
  - `public struct AppSettings: Codable, Equatable, Sendable { var refreshIntervalMinutes = 5; var stayAwakeWhilePluggedIn = false; var launchAtLogin = false }` with `static func load(from: UserDefaults) -> AppSettings` / `func save(to: UserDefaults)` under key `"appSettings"`.

- [ ] **Step 1:** `git init`; `.gitignore` with `.build/`, `build/`, `.swiftpm/`. `Package.swift`: tools 6.0, platforms `.macOS(.v14)`, `swiftLanguageModes: [.v5]`, targets `SlurmMonitorCore` (library), `SlurmMonitorApp` (executable, depends on core, linker settings `.linkedFramework("IOKit")`), test target `SlurmMonitorCoreTests`.
- [ ] **Step 2: Write failing tests**

```swift
import Testing, Foundation
@testable import SlurmMonitorCore

@Test func storeRoundTripsClusters() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("clusters.json")
  let store = ClusterStore(fileURL: url)
  #expect(try store.load() == [])
  let c = ClusterConfig(name: "trillium-gpu", host: "trillium-gpu.scinet.utoronto.ca", username: "leihan", requiresKey: true)
  try store.save([c])
  #expect(try store.load() == [c])
}
@Test func sshTargetAndAlias() {
  let c = ClusterConfig(name: "Trillium GPU", host: "trillium-gpu.scinet.utoronto.ca", username: "leihan")
  #expect(c.sshTarget == "leihan@trillium-gpu.scinet.utoronto.ca")
  #expect(c.generatedAlias == "smon-trillium-gpu")
  var d = c; d.sshAlias = "trillium-gpu"
  #expect(d.sshTarget == "trillium-gpu")
}
@Test func settingsDefaults() {
  let s = AppSettings()
  #expect(s.refreshIntervalMinutes == 5 && s.stayAwakeWhilePluggedIn == false && s.launchAtLogin == false)
}
```

- [ ] **Step 3:** Run `swift test --filter ClusterStoreTests` → FAIL (types missing).
- [ ] **Step 4:** Implement the types above.
- [ ] **Step 5:** Run `swift test` → PASS; `swift build` → succeeds.
- [ ] **Step 6:** Commit (include the spec and this plan): `git add -A && git commit -m "feat: package scaffold, cluster model and store"`

---

### Task 2: Alliance presets and `~/.ssh/config` importer

**Files:**
- Create: `Sources/SlurmMonitorCore/Model/AlliancePresets.swift`, `Sources/SlurmMonitorCore/SSH/SSHConfigImporter.swift`
- Test: `Tests/SlurmMonitorCoreTests/SSHConfigImporterTests.swift`

**Interfaces:**
- Consumes: `ClusterConfig`.
- Produces:
  - `public struct PresetCluster: Sendable, Hashable { name: String; host: String; requiresKey: Bool }`
  - `public enum AlliancePresets { static let all: [PresetCluster]; static func clusters(username: String, selected: Set<String>) -> [ClusterConfig] }`
  - `public struct SSHConfigHost: Equatable, Sendable { alias: String; hostName: String?; user: String? }`
  - `public enum SSHConfigImporter { static func parseHosts(_ text: String) -> [SSHConfigHost]; static func isKnownClusterDomain(_ hostName: String) -> Bool; static func cluster(from: SSHConfigHost, defaultUser: String) -> ClusterConfig }`

Values: `AlliancePresets.all` in this order — nibi `nibi.alliancecan.ca`, fir `fir.alliancecan.ca`, narval `narval.alliancecan.ca`, rorqual `rorqual.alliancecan.ca`, trillium `trillium.scinet.utoronto.ca` (requiresKey), trillium-gpu `trillium-gpu.scinet.utoronto.ca` (requiresKey), tamia `tamia.alliancecan.ca`, killarney `killarney.alliancecan.ca`. Known domains: suffixes `.alliancecan.ca`, `.computecanada.ca`, `.scinet.utoronto.ca`.

Parser rules: case-insensitive keywords, `key value` or `key=value`, ignores comments/blank lines; only literal `Host` entries without wildcards (`*`, `?`, `!`) become hosts; one host per alias when `Host a b`; `Match` lines end the current Host block; trailing whitespace trimmed (the real config has `Host narval ` and `HostName tamia.alliancecan.ca `). `cluster(from:)` sets `sshAlias = alias`, `host = hostName ?? alias`, `username = user ?? defaultUser`, `requiresKey` true when host matches a preset with requiresKey.

- [ ] **Step 1: Write failing tests**

```swift
let sample = """
Match final host *.alliancecan.ca exec "/bin/bash x"
    ControlPath ~/.ssh/cmfa-%C
Match all
Host nibi
  HostName nibi.alliancecan.ca
  User leihan
Host narval 
  HostName narval.alliancecan.ca
  User leihan
Host trillium-gpu
  HostName trillium-gpu.scinet.utoronto.ca
  User leihan
Host gpu_server
  HostName gpuclient.cs.torontomu.ca
Host *
  ServerAliveInterval 60
"""
@Test func parsesLiteralHostsOnly() {
  let hosts = SSHConfigImporter.parseHosts(sample)
  #expect(hosts.map(\.alias) == ["nibi", "narval", "trillium-gpu", "gpu_server"])
  #expect(hosts[1] == SSHConfigHost(alias: "narval", hostName: "narval.alliancecan.ca", user: "leihan"))
}
@Test func knownDomains() {
  #expect(SSHConfigImporter.isKnownClusterDomain("trillium-gpu.scinet.utoronto.ca"))
  #expect(!SSHConfigImporter.isKnownClusterDomain("gpuclient.cs.torontomu.ca"))
}
@Test func emptyConfigYieldsNoHosts() { #expect(SSHConfigImporter.parseHosts("").isEmpty) }
@Test func presetsOneUsername() {
  let cs = AlliancePresets.clusters(username: "alice", selected: ["nibi", "trillium-gpu"])
  #expect(cs.map(\.name) == ["nibi", "trillium-gpu"])
  #expect(cs.allSatisfy { $0.username == "alice" })
  #expect(cs[1].requiresKey && !cs[0].requiresKey)
  #expect(AlliancePresets.all.count == 8)
}
```

- [ ] **Step 2:** `swift test --filter SSHConfigImporterTests` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test --filter SSHConfigImporterTests` → PASS.
- [ ] **Step 5:** Commit `feat: alliance presets and ssh config importer`.

---

### Task 3: Slurm query script and parser

**Files:**
- Create: `Sources/SlurmMonitorCore/Slurm/SlurmModels.swift`, `Sources/SlurmMonitorCore/Slurm/SlurmTime.swift`, `Sources/SlurmMonitorCore/Slurm/SlurmQuery.swift`
- Test: `Tests/SlurmMonitorCoreTests/SlurmTimeTests.swift`, `Tests/SlurmMonitorCoreTests/SlurmQueryTests.swift`

**Interfaces:**
- Produces:
  - `public enum JobState: String, Codable, Sendable { case running, pending, completing, completed, failed, timeout, outOfMemory, cancelled, other }` with `init(slurm: String)`: uses first word, uppercased; `RUNNING→running, PENDING→pending, COMPLETING→completing, COMPLETED→completed, FAILED/NODE_FAIL/BOOT_FAIL→failed, TIMEOUT/DEADLINE→timeout, OUT_OF_MEMORY→outOfMemory, CANCELLED→cancelled` (so `"CANCELLED by 123"` → cancelled), else other; `var isTerminal: Bool` (completed, failed, timeout, outOfMemory, cancelled).
  - `public struct ActiveJob: Codable, Hashable, Sendable { id, name, state: JobState, partition, account: String; elapsed: TimeInterval?; timeLimit: TimeInterval?; nodes: Int?; cpus: Int?; memory: String?; gpus: Int?; reasonOrNodes: String; submitTime: Date?; startTime: Date?; workDir: String?; estimatedStart: Date? }`
  - `public struct EndedJob: Codable, Hashable, Sendable { id, name: String; state: JobState; exitCode: String; endTime: Date?; elapsed: TimeInterval? }`
  - `public struct ClusterSnapshot: Codable, Hashable, Sendable { clusterID: UUID; fetchedAt: Date; active: [ActiveJob]; ended: [EndedJob] }`
  - `public enum SlurmTime { static func duration(_ s: String) -> TimeInterval?; static func date(_ s: String) -> Date?; static func gpuCount(_ gres: String) -> Int? }`
  - `public enum SlurmQueryError: Error, Equatable { case commandFailed(String), malformed }`
  - `public enum SlurmQuery { static let remoteScript: String; static func parse(_ output: String, clusterID: UUID, fetchedAt: Date) throws -> ClusterSnapshot }`

`remoteScript` (exact; run via `bash -l -s` on stdin, Task 5):

```bash
echo '@@ACTIVE'
squeue -u "$USER" -h -o '%i|%j|%T|%P|%a|%M|%l|%D|%C|%m|%b|%R|%V|%S|%Z' || echo "@@ERR squeue $?"
echo '@@START'
squeue -u "$USER" -h -t PD --start -o '%i|%S' 2>/dev/null || true
echo '@@ENDED'
sacct -u "$USER" -X -n -P -S now-7days -o JobID,JobName,State,ExitCode,End,Elapsed 2>/dev/null || true
echo '@@DONE'
```

Parser rules: missing `@@DONE` → `.malformed`; a `@@ERR` line → `.commandFailed(line)`; active rows have 15 fields — if more, the extra fields belong to the name (fields `1...(1+extra)` joined with `|`); "N/A", "(null)", "Unknown", "None", "" → nil for optional fields; ended section keeps only rows whose state `isTerminal` (sacct with `-P` also splits on `|`; apply the same name-join rule with 6 fields). `estimatedStart` is filled from `@@START` rows by job ID. Durations: `D-HH:MM:SS`, `HH:MM:SS`, `MM:SS`; `UNLIMITED`/`INVALID`/`NOT_SET` → nil. Dates: `yyyy-MM-dd'T'HH:mm:ss` in the **local** time zone. `gpuCount`: sum of trailing integers of comma-separated `gpu` entries (`gres/gpu:4`→4, `gpu:h100:2`→2, `gres/gpu:a100=1`→1, `N/A`→nil).

- [ ] **Step 1: Write failing tests**

```swift
@Test func durations() {
  #expect(SlurmTime.duration("1-02:03:04") == 93784)
  #expect(SlurmTime.duration("02:03:04") == 7384)
  #expect(SlurmTime.duration("03:04") == 184)
  #expect(SlurmTime.duration("UNLIMITED") == nil)
}
@Test func gpus() {
  #expect(SlurmTime.gpuCount("gres/gpu:4") == 4)
  #expect(SlurmTime.gpuCount("gpu:h100:2") == 2)
  #expect(SlurmTime.gpuCount("N/A") == nil)
}
let out = """
@@ACTIVE
4321|train|llm|RUNNING|gpubase_bygpu_b3|def-alice_gpu|21:00:00|1-00:00:00|1|32|128G|gres/gpu:4|ng10201|2026-11-24T10:00:00|2026-11-24T18:00:00|/home/alice/run
4322_7|eval_big|PENDING|cpubase_bycore_b1|rrg-alice|0:00|10:00:00|2|64|256G|N/A|(Priority)|2026-11-25T09:00:00|N/A|/home/alice
@@START
4322_7|2026-11-25T18:30:00
@@ENDED
4100|sweep_06|COMPLETED|0:0|2026-11-25T14:00:00|05:00:00
4101|test_x|FAILED|1:0|2026-11-25T12:00:00|00:10:00
4102|still|RUNNING|0:0|Unknown|01:00:00
4103|killed|CANCELLED by 123|0:15|2026-11-24T08:00:00|00:01:00
@@DONE
"""
@Test func parsesFullOutput() throws {
  let id = UUID(); let now = Date()
  let s = try SlurmQuery.parse(out, clusterID: id, fetchedAt: now)
  #expect(s.active.count == 2)
  #expect(s.active[0].name == "train|llm")              // pipe in name
  #expect(s.active[0].gpus == 4 && s.active[0].cpus == 32 && s.active[0].timeLimit == 86400)
  #expect(s.active[1].id == "4322_7" && s.active[1].state == .pending)
  #expect(s.active[1].reasonOrNodes == "(Priority)" && s.active[1].estimatedStart == SlurmTime.date("2026-11-25T18:30:00"))
  #expect(s.ended.map(\.id) == ["4100", "4101", "4103"])  // RUNNING row dropped
  #expect(s.ended[2].state == .cancelled && s.ended[1].exitCode == "1:0")
}
@Test func emptyClusterIsValid() throws {
  let s = try SlurmQuery.parse("@@ACTIVE\n@@START\n@@ENDED\n@@DONE\n", clusterID: UUID(), fetchedAt: Date())
  #expect(s.active.isEmpty && s.ended.isEmpty)
}
@Test func squeueFailure() {
  #expect(throws: SlurmQueryError.commandFailed("@@ERR squeue 127")) {
    try SlurmQuery.parse("@@ACTIVE\n@@ERR squeue 127\n@@START\n@@ENDED\n@@DONE\n", clusterID: UUID(), fetchedAt: Date())
  }
}
@Test func truncatedOutputIsMalformed() {
  #expect(throws: SlurmQueryError.malformed) { try SlurmQuery.parse("@@ACTIVE\n", clusterID: UUID(), fetchedAt: Date()) }
}
```

- [ ] **Step 2:** `swift test --filter Slurm` → FAIL.
- [ ] **Step 3:** Implement models, `SlurmTime`, `SlurmQuery`.
- [ ] **Step 4:** `swift test --filter Slurm` → PASS.
- [ ] **Step 5:** Commit `feat: slurm query script and parser`.

---

### Task 4: `ssh -G` parsing, ControlPath resolution, generated SSH config

**Files:**
- Create: `Sources/SlurmMonitorCore/SSH/CommandRunner.swift`, `Sources/SlurmMonitorCore/SSH/SSHGOutput.swift`, `Sources/SlurmMonitorCore/SSH/ControlPathResolver.swift`, `Sources/SlurmMonitorCore/SSH/GeneratedSSHConfig.swift`
- Create: `Tests/SlurmMonitorCoreTests/Fakes.swift` (FakeRunner)
- Test: `Tests/SlurmMonitorCoreTests/ControlPathResolverTests.swift`, `Tests/SlurmMonitorCoreTests/GeneratedSSHConfigTests.swift`

**Interfaces:**
- Consumes: `ClusterConfig`.
- Produces:
  - `public struct CommandResult: Sendable, Equatable { exitCode: Int32; stdout: String; stderr: String; timedOut: Bool }`
  - `public protocol CommandRunner: Sendable { func run(_ executable: String, _ args: [String], stdin: String?, timeout: TimeInterval) async -> CommandResult }`
  - `public struct ProcessCommandRunner: CommandRunner` — `Process` + pipes; on timeout terminates the process and returns `timedOut: true, exitCode: -1`.
  - `public enum SSHGOutput { static func parse(_ text: String) -> [String: [String]] }` — lowercase key → all values in order.
  - `public enum ControlPathResolver { static func userTemplate(configText: String, alias: String?, hostName: String) -> String?; static func resolve(cluster: ClusterConfig, userConfigText: String, appTemplate: String, runner: CommandRunner) async -> (controlPath: String, sshG: [String: [String]]) }`
  - `public enum GeneratedSSHConfig { static let copiedKeys: [String]; static func block(for: ClusterConfig, sshG: [String: [String]], controlPath: String) -> String; static func write(blocks: [String], to: URL) throws }`

`userTemplate` rules: walk lines; `Host p1 p2…` and `Match …` open blocks; a `Host` block applies if any non-negated pattern matches `alias` or `hostName` and no negated pattern does (`*`/`?` globbing, comma lists); a `Match` block applies if it has `all`, or its `host`/`originalhost` pattern list matches, or it has no host criteria at all (other criteria such as `exec`, `final`, `user` are treated as satisfied); lines before the first block apply globally. First `ControlPath` in an applicable block wins (ssh first-obtained rule); value `none` → nil. `Include` is not followed.

`resolve`: template = `userTemplate(...) ?? appTemplate`; runs `/usr/bin/ssh -G -o ControlPath=<template> <cluster.sshTarget>`; returns the parsed `controlpath` value and the full map. On ssh failure falls back to the template with `~` expanded.

`copiedKeys` = `hostname, user, port, identityfile, identitiesonly, identityagent, proxyjump, proxycommand, hostkeyalias, userknownhostsfile, addkeystoagent` (skip a key whose value is `none`; `identityfile` copied only for files that exist). `block` renders:

```
Host <cluster.generatedAlias>
  <copied keys…>
  ControlPath "<controlPath>"
  ControlPersist yes
  ServerAliveInterval 30
  ServerAliveCountMax 20
  ConnectTimeout 10
  IgnoreUnknown UseKeychain
  UseKeychain yes
```
`write` joins blocks, writes atomically with permissions 0600, creating `~/.slurm-monitor/` (0700).

- [ ] **Step 1: Write failing tests** (reuse `sample` style from Task 2; include the real top block)

```swift
let userCfg = """
Match final host *.alliancecan.ca,trillium-gpu.scinet.utoronto.ca exec "/bin/bash ~/.ssh/x.sh '%n' '%C'"
    ControlMaster auto
    ControlPath ~/.ssh/cmfa-%C
Match all
Host gpu_server
  HostName gpuclient.cs.torontomu.ca
Host other
  ControlPath none
"""
@Test func templateFromMatchBlock() {
  #expect(ControlPathResolver.userTemplate(configText: userCfg, alias: "nibi", hostName: "nibi.alliancecan.ca") == "~/.ssh/cmfa-%C")
  #expect(ControlPathResolver.userTemplate(configText: userCfg, alias: nil, hostName: "trillium-gpu.scinet.utoronto.ca") == "~/.ssh/cmfa-%C")
  #expect(ControlPathResolver.userTemplate(configText: userCfg, alias: "gpu_server", hostName: "gpuclient.cs.torontomu.ca") == nil)
  #expect(ControlPathResolver.userTemplate(configText: userCfg, alias: "other", hostName: "other") == nil)
  #expect(ControlPathResolver.userTemplate(configText: "", alias: nil, hostName: "nibi.alliancecan.ca") == nil)
}
@Test func resolveUsesSshG() async {
  let runner = FakeRunner(default: CommandResult(exitCode: 0, stdout: "user leihan\nhostname nibi.alliancecan.ca\nport 22\ncontrolpath /Users/mac/.ssh/cmfa-a906e9a034ed7acf37581f12c4cae7cd3733ae47\n", stderr: "", timedOut: false))
  let c = ClusterConfig(name: "nibi", host: "nibi.alliancecan.ca", username: "leihan", sshAlias: "nibi")
  let r = await ControlPathResolver.resolve(cluster: c, userConfigText: userCfg, appTemplate: "~/.slurm-monitor/cm-%C", runner: runner)
  #expect(r.controlPath == "/Users/mac/.ssh/cmfa-a906e9a034ed7acf37581f12c4cae7cd3733ae47")
  #expect(runner.calls[0].args == ["-G", "-o", "ControlPath=~/.ssh/cmfa-%C", "nibi"])
}
@Test func generatedBlock() {
  let g = SSHGOutput.parse("hostname nibi.alliancecan.ca\nuser leihan\nport 22\nproxyjump none\ncontrolmaster false\n")
  let c = ClusterConfig(name: "nibi", host: "nibi.alliancecan.ca", username: "leihan")
  let b = GeneratedSSHConfig.block(for: c, sshG: g, controlPath: "/tmp/cm-x")
  #expect(b.hasPrefix("Host smon-nibi\n"))
  #expect(b.contains("  hostname nibi.alliancecan.ca") && b.contains("  ControlPath \"/tmp/cm-x\""))
  #expect(b.contains("  ServerAliveInterval 30") && b.contains("  ServerAliveCountMax 20") && b.contains("  ControlPersist yes"))
  #expect(!b.contains("proxyjump") && !b.contains("controlmaster"))
}
@Test func processRunnerOutputAndTimeout() async {
  let ok = await ProcessCommandRunner().run("/bin/echo", ["hi"], stdin: nil, timeout: 2)
  #expect(ok.stdout == "hi\n" && ok.exitCode == 0 && !ok.timedOut)
  let slow = await ProcessCommandRunner().run("/bin/sleep", ["5"], stdin: nil, timeout: 0.5)
  #expect(slow.timedOut && slow.exitCode == -1)
}
```

- [ ] **Step 2:** `swift test --filter "ControlPath|GeneratedSSHConfig|processRunner"` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Same command → PASS.
- [ ] **Step 5:** Commit `feat: control path resolution and generated ssh config`.

---

### Task 5: Error classification, transports and connection chain

**Files:**
- Create: `Sources/SlurmMonitorCore/SSH/ClusterErrorClassifier.swift`, `Sources/SlurmMonitorCore/Transport/ClusterTransport.swift`, `Sources/SlurmMonitorCore/Transport/SharedSSHTransport.swift`
- Modify: `Tests/SlurmMonitorCoreTests/Fakes.swift` (add FakeTransport)
- Test: `Tests/SlurmMonitorCoreTests/ClusterErrorClassifierTests.swift`, `Tests/SlurmMonitorCoreTests/TransportTests.swift`

**Interfaces:**
- Consumes: `CommandRunner`, `CommandResult`, `ConnectionMethodKind`.
- Produces:
  - `public enum ClusterError: Codable, Hashable, Sendable, Error { case needsLogin, needsSSHKey, noAccess, unreachable, mfaFailed, slurmFailed(String) }` with `var hint: String` (copy: "Log in to refresh", "Upload an SSH key in CCDB", "Request access to this cluster in CCDB", "Cluster unreachable", "MFA was denied or timed out", "Slurm command failed").
  - `public enum ClusterErrorClassifier { static func classify(_ r: CommandResult) -> ClusterError }`
  - `public enum TransportState: Equatable, Sendable { case usable, unavailable(ClusterError) }`
  - `public protocol ClusterTransport: Sendable { var kind: ConnectionMethodKind { get }; func probe() async -> TransportState; func run(_ script: String, timeout: TimeInterval) async throws -> String }` (throws `ClusterError`)
  - `public struct SharedSSHTransport: ClusterTransport { init(alias: String, configPath: String, runner: CommandRunner); func stopStaleMaster() async }`
  - `public struct ConnectionChain: Sendable { init(_ transports: [ClusterTransport]); func firstUsable() async -> Result<ClusterTransport, ClusterError> }` — first `.usable` in order; if none, the error from the last transport; empty chain → `.needsLogin`.

Classifier order: `timedOut` → unreachable; stderr contains `Permission denied (publickey)` exactly (only publickey offered) → needsSSHKey; `Could not resolve hostname`, `Connection refused`, `Operation timed out`, `No route to host`, `Network is unreachable` → unreachable; `not allowed`, `account is not`, `Access denied` (case-insensitive) → noAccess; `Control socket connect`, `No such file or directory`, `Permission denied`, `Host key verification failed` → needsLogin; otherwise needsLogin.

`SharedSSHTransport` argv (executable `/usr/bin/ssh`):
- probe: `["-F", configPath, "-O", "check", alias]`, timeout 5 → exit 0 ⇒ `.usable`, else `.unavailable(.needsLogin)`.
- run: `["-F", configPath, "-o", "BatchMode=yes", "-o", "ControlMaster=no", alias, "bash", "-l", "-s"]`, stdin = script → exit 0 ⇒ stdout; else throw `classify(result)`.
- stopStaleMaster: `["-F", configPath, "-O", "stop", alias]` (never `exit`).

- [ ] **Step 1: Write failing tests**

```swift
@Test func classifies() {
  func r(_ e: String, t: Bool = false) -> CommandResult { .init(exitCode: 255, stdout: "", stderr: e, timedOut: t) }
  #expect(ClusterErrorClassifier.classify(r("leihan@trillium: Permission denied (publickey).")) == .needsSSHKey)
  #expect(ClusterErrorClassifier.classify(r("Permission denied (publickey,keyboard-interactive).")) == .needsLogin)
  #expect(ClusterErrorClassifier.classify(r("ssh: Could not resolve hostname x")) == .unreachable)
  #expect(ClusterErrorClassifier.classify(r("", t: true)) == .unreachable)
}
@Test func probeAndRunArgv() async throws {
  let runner = FakeRunner(default: .init(exitCode: 0, stdout: "OUT", stderr: "", timedOut: false))
  let t = SharedSSHTransport(alias: "smon-nibi", configPath: "/c", runner: runner)
  #expect(await t.probe() == .usable)
  #expect(try await t.run("SCRIPT", timeout: 15) == "OUT")
  await t.stopStaleMaster()
  #expect(runner.calls.map(\.args) == [
    ["-F", "/c", "-O", "check", "smon-nibi"],
    ["-F", "/c", "-o", "BatchMode=yes", "-o", "ControlMaster=no", "smon-nibi", "bash", "-l", "-s"],
    ["-F", "/c", "-O", "stop", "smon-nibi"]])
  #expect(runner.calls[1].stdin == "SCRIPT")
  #expect(!runner.calls.flatMap(\.args).contains("exit"))
}
@Test func chainSkipsUnusable() async {
  let robot = FakeTransport(kind: .robot, probeResult: .unavailable(.unreachable))
  let shared = FakeTransport(kind: .sharedSSH, probeResult: .usable)
  let r = await ConnectionChain([robot, shared]).firstUsable()
  #expect((try? r.get())?.kind == .sharedSSH)
  let none = await ConnectionChain([robot]).firstUsable()
  #expect(none.failureValue == .unreachable)   // add tiny Result helper in Fakes.swift
}
```

- [ ] **Step 2:** `swift test --filter "Classifier|Transport"` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** → PASS.
- [ ] **Step 5:** Commit `feat: ssh transport, error classification, connection chain`.

---

### Task 6: Snapshot cache and dashboard aggregation

**Files:**
- Create: `Sources/SlurmMonitorCore/Monitor/SnapshotCache.swift`, `Sources/SlurmMonitorCore/Monitor/Dashboard.swift`
- Test: `Tests/SlurmMonitorCoreTests/DashboardTests.swift`

**Interfaces:**
- Consumes: `ClusterConfig`, `ClusterSnapshot`, `ActiveJob`, `EndedJob`, `ClusterError`.
- Produces:
  - `public final class SnapshotCache: Sendable { init(directory: URL); func load(_ id: UUID) -> ClusterSnapshot?; func save(_ s: ClusterSnapshot) throws }` — one `<uuid>.json` per cluster.
  - `public enum ClusterStatus: Equatable, Sendable { case live, stale, loggingIn, error(ClusterError) }` (`needsLogin` is `.error(.needsLogin)`)
  - `public struct ClusterView: Equatable, Sendable { config: ClusterConfig; status: ClusterStatus; snapshot: ClusterSnapshot?; methodInUse: ConnectionMethodKind? }`
  - `public struct JobRef<J: Hashable & Sendable>: Hashable, Sendable { cluster: ClusterConfig; job: J }`
  - `public struct Dashboard: Sendable { init(clusters: [ClusterView], now: Date); runningCount: Int; pendingCount: Int; gpusInUse: Int; endingSoon: [JobRef<ActiveJob>]; waiting: [JobRef<ActiveJob>]; recentlyEnded: [JobRef<EndedJob>]; liveCount: Int; enabledCount: Int; hasStale: Bool; menuBarText: String; static func ageText(_ seconds: TimeInterval) -> String }`

Rules: only enabled clusters; jobs from stale/error clusters **are** counted (last known data); running = state running or completing; gpusInUse sums `gpus ?? 0` of running jobs; `endingSoon` = running jobs sorted by `timeLimit - elapsed` ascending, nil limits last; `waiting` = pending jobs sorted by `estimatedStart` (nil last); `recentlyEnded` = all ended jobs across clusters sorted by `endTime` desc, `prefix(3)`; `hasStale` = any enabled cluster not `.live`/`.loggingIn` that has a snapshot; `menuBarText` = `"▶ \(running)  ⏸ \(pending)"`; `ageText`: `<60s` "just now", `<3600` "Nm ago", `<86400` "Nh ago", else "Nd ago".

- [ ] **Step 1: Write failing tests**

```swift
@Test func aggregatesAcrossClustersIncludingStale() {
  // build two ClusterViews: nibi .live with 2 running (gpus 4 and nil) + 1 pending; narval .stale with 1 running (gpus 2)
  // ended: nibi [e1 end now-10m, e2 end now-3h], narval [e3 end now-1h, e4 end now-2d]
  let d = Dashboard(clusters: views, now: now)
  #expect(d.runningCount == 3 && d.pendingCount == 1 && d.gpusInUse == 6)
  #expect(d.recentlyEnded.map(\.job.id) == ["e1", "e3", "e2"])
  #expect(d.menuBarText == "▶ 3  ⏸ 1")
  #expect(d.hasStale && d.liveCount == 1)
}
@Test func endingSoonOrder() { /* job A 21h/24h, job B 6h/10h, job C no limit → [A, B, C] */ }
@Test func cacheSurvivesRelaunch() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let snap = ClusterSnapshot(clusterID: UUID(), fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), active: [], ended: [])
  try SnapshotCache(directory: dir).save(snap)
  #expect(SnapshotCache(directory: dir).load(snap.clusterID) == snap)
}
@Test func ages() { #expect(Dashboard.ageText(30) == "just now"); #expect(Dashboard.ageText(3700) == "1h ago") }
```

- [ ] **Step 2:** `swift test --filter DashboardTests` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** → PASS.
- [ ] **Step 5:** Commit `feat: snapshot cache and dashboard aggregation`.

---

### Task 7: MonitorModel (state, refresh execution, offline start)

**Files:**
- Create: `Sources/SlurmMonitorCore/Monitor/RefreshPolicy.swift`, `Sources/SlurmMonitorCore/Monitor/MonitorModel.swift`
- Test: `Tests/SlurmMonitorCoreTests/MonitorModelTests.swift`

**Interfaces:**
- Consumes: `ClusterStore`, `SnapshotCache`, `ClusterTransport`, `ConnectionChain`, `SlurmQuery`, `Dashboard`, `ClusterView`.
- Produces:
  - `public enum RefreshReason: Sendable { case panelOpened, background, manual, afterLogin, wakeOrNetwork }`
  - `public enum RefreshPolicy { static let panelOpenThreshold: TimeInterval = 60; static func shouldRefresh(reason: RefreshReason, lastFetched: Date?, now: Date, isLoggingIn: Bool) -> Bool }` — loggingIn → false; panelOpened → `lastFetched == nil || now - lastFetched > 60`; others → true.
  - `@MainActor public final class MonitorModel: ObservableObject { @Published private(set) var clusters: [ClusterView]; var dashboard: Dashboard; init(store: ClusterStore, cache: SnapshotCache, transports: @escaping @Sendable (ClusterConfig) -> [ClusterTransport], now: @escaping @Sendable () -> Date = Date.init); func reloadClusters() throws; func setClusters(_ configs: [ClusterConfig]) throws; func refreshAll(_ reason: RefreshReason) async; func refresh(_ id: UUID, _ reason: RefreshReason) async; func setLoggingIn(_ id: UUID, _ value: Bool); func liveCount() -> Int }`

Behaviour: `init` loads clusters and their cached snapshots; every cluster with a cached snapshot starts `.stale`, without one `.error(.needsLogin)`. `refresh`: if `!shouldRefresh` return; `ConnectionChain(transports(config)).firstUsable()` → failure: status `.error(e)` if no snapshot, else `.stale` (keep the error for the Clusters tab via `lastError: [UUID: ClusterError]` published dictionary); success: `run(SlurmQuery.remoteScript, timeout: 15)` → parse → save to cache → `.live`, `methodInUse = transport.kind`. Parse `commandFailed` → `lastError = .slurmFailed(msg)`, snapshot kept, status `.stale` (or `.error(.slurmFailed)` if none). `refreshAll` runs enabled clusters concurrently (`withTaskGroup`).

- [ ] **Step 1: Write failing tests** (FakeTransport returning canned script output from Task 3)

```swift
@MainActor @Test func offlineStartShowsCachedAsStale() throws { /* save snapshot to cache, store 1 cluster → model.clusters[0].status == .stale && snapshot != nil */ }
@MainActor @Test func successfulRefreshGoesLive() async { /* FakeTransport usable + valid output → .live, methodInUse == .sharedSSH, cache file written */ }
@MainActor @Test func unusableKeepsSnapshot() async { /* cached snapshot + transport .unavailable(.needsLogin) → status .stale, snapshot unchanged, lastError[id] == .needsLogin */ }
@MainActor @Test func slurmFailureKeepsSnapshot() async { /* output "@@ACTIVE\n@@ERR squeue 127\n..." → lastError == .slurmFailed("@@ERR squeue 127"), snapshot unchanged */ }
@Test func policy() {
  let now = Date()
  #expect(!RefreshPolicy.shouldRefresh(reason: .panelOpened, lastFetched: now.addingTimeInterval(-30), now: now, isLoggingIn: false))
  #expect(RefreshPolicy.shouldRefresh(reason: .panelOpened, lastFetched: now.addingTimeInterval(-61), now: now, isLoggingIn: false))
  #expect(!RefreshPolicy.shouldRefresh(reason: .background, lastFetched: nil, now: now, isLoggingIn: true))
}
```

- [ ] **Step 2:** `swift test --filter "MonitorModel|policy"` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** → PASS.
- [ ] **Step 5:** Commit `feat: monitor model with refresh policy and offline cache`.

---

### Task 8: Login during refresh guard

**Files:**
- Modify: `Sources/SlurmMonitorCore/Monitor/MonitorModel.swift`
- Test: `Tests/SlurmMonitorCoreTests/MonitorModelTests.swift`

**Interfaces:**
- Consumes/Produces: `MonitorModel.setLoggingIn(_:_:)`, `refreshAll(_:)` from Task 7. `setLoggingIn(id, true)` sets status `.loggingIn`; `setLoggingIn(id, false)` restores the previous status (does not refresh — the caller triggers `refresh(id, .afterLogin)`).

- [ ] **Step 1: Write failing test**

```swift
@MainActor @Test func noQueryWhileLoggingIn() async {
  // FakeTransport counting runCount; model.setLoggingIn(id, true); await model.refreshAll(.background)
  #expect(fake.runCount == 0)
  #expect(model.clusters[0].status == .loggingIn)
}
```

- [ ] **Step 2:** Run → FAIL if Task 7 didn't already gate by status; if it passes already, keep the test and skip Step 3.
- [ ] **Step 3:** Gate `refresh` on `.loggingIn`.
- [ ] **Step 4:** `swift test` → all PASS.
- [ ] **Step 5:** Commit `test: no refresh while logging in`.

---

### Task 9: PTY process and login session

**Files:**
- Create: `Sources/SlurmMonitorCore/Login/PTYProcess.swift`, `Sources/SlurmMonitorCore/Login/LoginPromptClassifier.swift`, `Sources/SlurmMonitorCore/Login/LoginSession.swift`
- Test: `Tests/SlurmMonitorCoreTests/LoginPromptClassifierTests.swift`, `Tests/SlurmMonitorCoreTests/PTYProcessTests.swift`

**Interfaces:**
- Consumes: `ClusterError`.
- Produces:
  - `public final class PTYProcess: @unchecked Sendable { init(executable: String, args: [String]) throws; var output: AsyncStream<String>; func write(_ s: String); func waitForExit() async -> Int32; func terminate() }`
  - `public struct MFAOption: Equatable, Sendable { number: Int; label: String }`
  - `public enum LoginPrompt: Equatable, Sendable { case hostKey(fingerprint: String), password, passphrase, mfa(options: [MFAOption]), denied(ClusterError) }`
  - `public enum LoginPromptClassifier { static func classify(_ buffer: String) -> LoginPrompt? }` — inspects the text since the last answered prompt.
  - `public enum LoginEvent: Sendable, Equatable { case transcript(String), prompt(LoginPrompt), succeeded, failed(ClusterError) }`
  - `public final class LoginSession: @unchecked Sendable { init(alias: String, configPath: String, executable: String = "/usr/bin/ssh"); var events: AsyncStream<LoginEvent>; func start() throws; func answer(_ text: String); func cancel() }`

PTY algorithm (not determined by the signature — fork is unsafe in Swift):
1. `openpty(&master, &slave, nil, nil, nil)`; `slavePath = String(cString: ttyname(slave))`.
2. `posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)`.
3. File actions: `addopen(0, slavePath, O_RDWR, 0)` (opening after setsid makes it the controlling tty — ssh reads prompts from `/dev/tty`), `adddup2(0, 1)`, `adddup2(0, 2)`.
4. `posix_spawn`, close `slave` in parent; read `master` on a background `DispatchSource`/thread into the `AsyncStream`; `write` writes to `master`; `waitForExit` uses `waitpid` off the main thread.

LoginSession argv: `["-F", configPath, "-o", "ControlMaster=yes", "-o", "ControlPersist=yes", "-N", "-f", alias]` (`-f` backgrounds after auth, so exit 0 = success). Emits `.prompt` when the classifier finds a prompt, `.succeeded` on exit 0, `.failed(classified)` otherwise (reuse `ClusterErrorClassifier` on transcript). Answers are written with `\n`; never stored or logged (`transcript` events omit answered text since PTY echo is off for passwords; for MFA menu numbers echo is fine).

Classifier patterns: `(yes/no/[fingerprint])` → `.hostKey` with the `SHA256:\S+` token; `Enter passphrase for key` → `.passphrase`; `password:` at end (case-insensitive) → `.password`; `Passcode or option` → `.mfa` with options parsed from lines matching `^\s*(\d+)\.\s+(.+)$`; `Permission denied (publickey)` → `.denied(.needsSSHKey)`; `Login timed out`/`Access denied` → `.denied(.mfaFailed)`.

- [ ] **Step 1: Write failing tests**

```swift
@Test func duoMenu() {
  let t = "Duo two-factor login for leihan\n\nEnter a passcode or select one of the following options:\n\n 1. Duo Push to iPhone (iOS)\n 2. Phone call\n\nPasscode or option (1-2): "
  #expect(LoginPromptClassifier.classify(t) == .mfa(options: [.init(number: 1, label: "Duo Push to iPhone (iOS)"), .init(number: 2, label: "Phone call")]))
}
@Test func hostKeyAndPassword() {
  #expect(LoginPromptClassifier.classify("ED25519 key fingerprint is SHA256:abc123.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ") == .hostKey(fingerprint: "SHA256:abc123"))  // trailing "." trimmed
  #expect(LoginPromptClassifier.classify("leihan@nibi.alliancecan.ca's password: ") == .password)
  #expect(LoginPromptClassifier.classify("Enter passphrase for key '/Users/a/.ssh/id_ed25519': ") == .passphrase)
}
@Test func ptyHasControllingTTY() async throws {
  let p = try PTYProcess(executable: "/bin/sh", args: ["-c", "printf 'Password: ' > /dev/tty; read x < /dev/tty; echo got:$x"])
  var seen = ""
  for await chunk in p.output { seen += chunk; if seen.contains("Password: ") { p.write("s3cret\n") }; if seen.contains("got:s3cret") { break } }
  #expect(await p.waitForExit() == 0)
}
```

- [ ] **Step 2:** `swift test --filter "LoginPrompt|PTY"` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** → PASS.
- [ ] **Step 5:** Commit `feat: pty login session and prompt classifier`.

---

### Task 10: Key manager and power policy

**Files:**
- Create: `Sources/SlurmMonitorCore/Keys/KeyManager.swift`, `Sources/SlurmMonitorCore/Power/PowerPolicy.swift`
- Test: `Tests/SlurmMonitorCoreTests/KeyManagerTests.swift`, `Tests/SlurmMonitorCoreTests/PowerPolicyTests.swift`

**Interfaces:**
- Consumes: `CommandRunner`.
- Produces:
  - `public enum KeyManager { static let candidateNames = ["id_ed25519", "id_ecdsa", "id_rsa"]; static func existingKeys(sshDir: URL) -> [URL]; static func agentHasKeys(runner: CommandRunner) async -> Bool; static func generate(at: URL, passphrase: String, runner: CommandRunner) async throws -> String /* public key text */ }`
  - `public enum PowerPolicy { static func shouldHoldAssertion(enabled: Bool, onACPower: Bool, liveConnections: Int) -> Bool }` — all three must hold (`liveConnections >= 1`).

`existingKeys`: private key file exists **and** `<name>.pub` exists. `agentHasKeys`: `/usr/bin/ssh-add -l` exit 0. `generate`: refuses if the file exists (throws); runs `/usr/bin/ssh-keygen -t ed25519 -f <path> -N <passphrase> -C slurm-monitor`; returns contents of `<path>.pub`.

- [ ] **Step 1: Write failing tests**

```swift
@Test func findsKeyPairsOnly() throws {
  let dir = tmpDir(); try "k".write(to: dir/"id_ed25519"); try "p".write(to: dir/"id_ed25519.pub"); try "k".write(to: dir/"id_rsa")
  #expect(KeyManager.existingKeys(sshDir: dir).map(\.lastPathComponent) == ["id_ed25519"])
  #expect(KeyManager.existingKeys(sshDir: tmpDir()).isEmpty)
}
@Test func generatesRealKey() async throws {
  let path = tmpDir().appendingPathComponent("id_ed25519")
  let pub = try await KeyManager.generate(at: path, passphrase: "", runner: ProcessCommandRunner())
  #expect(pub.hasPrefix("ssh-ed25519 ") && pub.contains("slurm-monitor"))
}
@Test func power() {
  #expect(PowerPolicy.shouldHoldAssertion(enabled: true, onACPower: true, liveConnections: 1))
  #expect(!PowerPolicy.shouldHoldAssertion(enabled: true, onACPower: false, liveConnections: 3))
  #expect(!PowerPolicy.shouldHoldAssertion(enabled: false, onACPower: true, liveConnections: 3))
  #expect(!PowerPolicy.shouldHoldAssertion(enabled: true, onACPower: true, liveConnections: 0))
}
```

- [ ] **Step 2:** `swift test --filter "KeyManager|power"` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** → PASS.
- [ ] **Step 5:** Commit `feat: key manager and power policy`.

---

### Task 11: App wiring and the floating panel (Overview / Jobs / Clusters)

**Files:**
- Create: `Sources/SlurmMonitorApp/AppEnvironment.swift`, `Sources/SlurmMonitorApp/Views/PanelView.swift`, `Views/OverviewTab.swift`, `Views/JobsTab.swift`, `Views/ClustersTab.swift`, `Views/SettingsView.swift`, `Views/Components.swift`
- Modify: `Sources/SlurmMonitorApp/SlurmMonitorApp.swift`

**Interfaces:**
- Consumes: `MonitorModel`, `Dashboard`, `ClusterView`, `ClusterStatus`, `ClusterError.hint`, `AppSettings`, `ControlPathResolver`, `GeneratedSSHConfig`, `SharedSSHTransport`, `ProcessCommandRunner`.
- Produces: `@MainActor final class AppEnvironment: ObservableObject { let model: MonitorModel; @Published var settings: AppSettings; let paths: AppPaths; func regenerateSSHConfig() async; func startTimers() }` and `struct AppPaths { root = ~/.slurm-monitor; clusters = root/clusters.json; cache = root/cache; sshConfig = root/ssh_config; socketTemplate = "~/.slurm-monitor/cm-%C" }`.

Behaviour:
- `regenerateSSHConfig()`: reads `~/.ssh/config` (empty string if missing), for each enabled cluster calls `ControlPathResolver.resolve` then `GeneratedSSHConfig.block`, writes all; called at launch, after cluster edits, and when `~/.ssh/config` mtime changed since last run (checked on each refresh tick).
- Transport factory: `[SharedSSHTransport(alias: cluster.generatedAlias, configPath: paths.sshConfig.path, runner:)]` (`.robot` entries in `methods` are skipped — no implementation).
- `MenuBarExtra { PanelView() } label: { Text(dashboard.menuBarText) + orange dot when hasStale }` with `.menuBarExtraStyle(.window)`; panel width 380.
- `.onAppear` of the panel → `refreshAll(.panelOpened)`. Timer every `settings.refreshIntervalMinutes` min → `refreshAll(.background)` (this is the §5.4a check-in).
- PanelView: header "Slurm Jobs · <username of first cluster>", "● live/enabled live", "Updated <ageText>" + ⟳ (`.manual`); segmented tabs Overview / Jobs / Clusters; footer ⚙ (SettingsView popover: refresh interval stepper 1–30, "Stay awake while plugged in" toggle with the §5.4a limits help text, "Launch at login" toggle via `SMAppService.mainApp`) and ⏻ quit.
- Overview / Jobs / Clusters content exactly per spec §5.7 (cards; ending-soon bar = elapsed/limit; waiting row = reason + "~starts <relative>"; Recently ended (last 3) with ✓/✗ state + exit code + age; cluster grid with ● ◐ ○ and age). Clusters tab rows: status, `lastError.hint`, method label ("via shared connection"; robot shows "via robot (coming soon)" — never selectable), last success age, **Log in** button (wired in Task 12), Edit (name/host/username/alias/enabled sheet) / Remove, "Add cluster" (opens WelcomeView in add mode), "Log in to stale clusters".
- Read-only: no job action buttons anywhere.

- [ ] **Step 1:** Implement wiring + views; empty-state: if `model.clusters.isEmpty` show `WelcomeView` placeholder text "Add your clusters" (real view in Task 12).
- [ ] **Step 2:** `swift build` → succeeds with no warnings in `SlurmMonitorApp`.
- [ ] **Step 3:** Manual check: `swift run SlurmMonitorApp`; with your existing `cmfa-*` master live for nibi (open one with `ssh nibi` in Terminal first), the menu bar shows `▶ n  ⏸ m`, the panel lists nibi jobs matching `sq` output on nibi, and other clusters show greyed "needs login". Kill the app; relaunch with Wi-Fi off → cached jobs appear with ◐ and age.
- [ ] **Step 4:** `swift test` → all PASS.
- [ ] **Step 5:** Commit `feat: menu bar panel with overview, jobs and clusters tabs`.

---

### Task 12: Welcome flow, login sheet and key setup UI

**Files:**
- Create: `Sources/SlurmMonitorApp/Views/WelcomeView.swift`, `Sources/SlurmMonitorApp/Views/LoginSheet.swift`
- Modify: `Views/ClustersTab.swift`, `Views/PanelView.swift`, `AppEnvironment.swift`

**Interfaces:**
- Consumes: `AlliancePresets`, `SSHConfigImporter`, `KeyManager`, `LoginSession`, `LoginEvent`, `LoginPrompt`, `SharedSSHTransport.stopStaleMaster()`, `MonitorModel.setLoggingIn/refresh/setClusters`.
- Produces: `AppEnvironment.login(_ ids: [UUID])` — sequential queue presenting `LoginSheet` per cluster.

Behaviour:
- WelcomeView per spec §6 sketch: segmented *Alliance clusters* (default) / *Import from SSH config* (hidden when `parseHosts` is empty) / *Custom host*; one "Alliance username" field; checklist of all 8 presets ticked; key status line: "✓ found ~/.ssh/<name>" or "agent has keys", else **Create a key for me** (passphrase field optional; generates `~/.ssh/id_ed25519` only if absent, else `~/.ssh/id_ed25519_slurm_monitor`) → shows public key with **Copy** and **Open CCDB SSH keys page** (`https://ccdb.alliancecan.ca/ssh_authorized_keys`) and the note "New keys can take a while to reach clusters"; skippable. Import mode lists hosts with known-domain ones preselected. **Log in to all** saves clusters, regenerates ssh config, then `login(allIDs)`.
- `login(ids)`: for each id: `setLoggingIn(id, true)`; probe — if already usable, skip to refresh; else `stopStaleMaster()` then present LoginSheet running `LoginSession(alias:configPath:)`. Sheet shows cluster name, transcript (monospaced, last lines), and the control for the current prompt: host key → fingerprint + Trust / Cancel (`yes`); password/passphrase → `SecureField` + Continue; MFA → one button per option (e.g. "1 · Duo Push to iPhone") plus a passcode field; denied → `ClusterError.hint` + Close. Buttons "Skip this cluster" and "Stop". On `.succeeded`: `setLoggingIn(false)`, `refresh(id, .afterLogin)`, next cluster. Cancel/skip: `setLoggingIn(false)`, next/stop.
- Trillium-type (`requiresKey`) clusters failing with `.needsSSHKey` show the CCDB key hint plus "Trillium also requires access to be requested in CCDB".
- Clusters tab **Log in** → `login([id])`; **Log in to stale clusters** → `login(ids of non-live enabled clusters)`.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** `swift build` → succeeds.
- [ ] **Step 3:** Manual check on a fresh profile: `mv ~/.slurm-monitor ~/.slurm-monitor.bak` (if present), run, complete Welcome with username `leihan`, log into nibi (Duo push) → nibi turns ● live with jobs; then in Terminal `ssh nibi hostname` succeeds **without** MFA (shared socket). Log in to trillium with a key → works; with a missing key → "needs SSH key" hint. Restore backup afterwards.
- [ ] **Step 4:** `swift test` → all PASS.
- [ ] **Step 5:** Commit `feat: welcome flow, login sheet and key setup`.

---

### Task 13: Keep-alive platform pieces (stay awake, wake/network re-probe)

**Files:**
- Create: `Sources/SlurmMonitorApp/Platform/StayAwakeController.swift`, `Sources/SlurmMonitorApp/Platform/SystemEventsMonitor.swift`
- Modify: `AppEnvironment.swift`

**Interfaces:**
- Consumes: `PowerPolicy.shouldHoldAssertion`, `MonitorModel.liveCount()`, `refreshAll(.wakeOrNetwork)`, `AppSettings.stayAwakeWhilePluggedIn`.
- Produces: `final class StayAwakeController { func update(enabled: Bool, liveConnections: Int) ; deinit releases }`, `final class SystemEventsMonitor { init(onChange: @escaping () -> Void) }`.

Behaviour: `StayAwakeController.update` reads AC state via `IOPSCopyPowerSourcesInfo` + `IOPSGetProvidingPowerSourceType` (`kIOPMACPowerKey`), creates `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionLevelOn, "Slurm Monitor keeping cluster connections alive")` when policy says hold, releases otherwise; called after every refresh, on settings change, and on quit. `SystemEventsMonitor`: `NSWorkspace.didWakeNotification` + `NWPathMonitor` path changes (debounced 3 s) → `refreshAll(.wakeOrNetwork)` — probe/query only, never login.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** `swift build` → succeeds.
- [ ] **Step 3:** Manual check: enable "Stay awake while plugged in" with ≥1 live cluster on AC → `pmset -g assertions | grep -i "Slurm Monitor"` shows a `PreventUserIdleSystemSleep` entry; unplug (or disable) → entry gone. Toggle Wi-Fi off/on → clusters re-probe; no login sheet appears.
- [ ] **Step 4:** Commit `feat: stay-awake option and wake/network re-probe`.

---

### Task 14: App bundle packaging

**Files:**
- Create: `scripts/build-app.sh`, `Resources/Info.plist`

**Interfaces:**
- Consumes: `SlurmMonitorApp` executable product.
- Produces: `build/Slurm Monitor.app`.

Info.plist values: `CFBundleIdentifier` `io.github.slurm-monitor`, `CFBundleName` `Slurm Monitor`, `CFBundleExecutable` `SlurmMonitorApp`, `LSUIElement` `true`, `LSMinimumSystemVersion` `14.0`, `CFBundleShortVersionString` `0.1.0`, `CFBundleVersion` `1`.

Script: `set -euo pipefail`; `swift build -c release --arch arm64` (add `--arch x86_64` when it builds; then `lipo` not needed — SwiftPM emits a universal binary under `.build/apple/Products/Release`); create `build/Slurm Monitor.app/Contents/{MacOS,Resources}`; copy binary and Info.plist; `codesign --force --deep --sign - "build/Slurm Monitor.app"`; `codesign --verify --verbose "build/Slurm Monitor.app"`.

- [ ] **Step 1:** Write files; `chmod +x scripts/build-app.sh`.
- [ ] **Step 2:** Run `scripts/build-app.sh` → ends with `valid on disk` / `satisfies its Designated Requirement`.
- [ ] **Step 3:** `open "build/Slurm Monitor.app"` → menu-bar item appears, no Dock icon; "Launch at login" toggle registers without error.
- [ ] **Step 4:** Commit `build: app bundle packaging script`.

---

## Self-review notes

- Spec coverage: §5.1 → T1/T14; §5.2 → T1/T2; §5.3 → T5 (robot enum + label only, T11); §5.4 → T4/T5/T9/T12; §5.4a → T4 (keep-alive options), T11 (5-min background refresh = check-in), T10/T13 (stay awake), T13 (wake/network); §5.5 → T3; §5.6 → T7/T8/T11; §5.7 → T6/T11; §6 → T10/T12; error states → T5/T12.
- Deliberate simplification: the §5.4a "check-in" is the background refresh query itself (spec allows merging), so no separate `true` command.
