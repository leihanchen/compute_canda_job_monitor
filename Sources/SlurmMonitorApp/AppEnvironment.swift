import Combine
import Foundation
import SlurmMonitorCore

/// Standard filesystem locations used by Slurm Monitor under `~/.slurm-monitor`.
struct AppPaths: Sendable {
    let root: URL
    let sshDirectory: URL
    let clusters: URL
    let cache: URL
    let sshConfig: URL
    let userSSHConfig: URL
    let socketTemplate: String

    static let `default`: AppPaths = AppPaths()

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".slurm-monitor", isDirectory: true),
        sshDirectory: URL? = nil,
        userSSHConfig: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false),
        socketTemplate: String = "~/.slurm-monitor/cm-%C"
    ) {
        self.root = root
        self.userSSHConfig = userSSHConfig
        self.sshDirectory = sshDirectory ?? userSSHConfig.deletingLastPathComponent()
        self.clusters = root.appendingPathComponent("clusters.json", isDirectory: false)
        self.cache = root.appendingPathComponent("cache", isDirectory: true)
        self.sshConfig = root.appendingPathComponent("ssh_config", isDirectory: false)
        self.socketTemplate = socketTemplate
    }
}

/// Main-actor coordinator binding `MonitorModel`, generated SSH config, timers, and UI presentation hooks.
@MainActor
final class AppEnvironment: ObservableObject {
    let model: MonitorModel
    let paths: AppPaths
    let runner: CommandRunner

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save(to: userDefaults)
            if settings.refreshIntervalMinutes != oldValue.refreshIntervalMinutes {
                startTimers()
            }
            if settings.stayAwakeWhilePluggedIn != oldValue.stayAwakeWhilePluggedIn {
                onStateChange?()
            }
        }
    }

    @Published private(set) var isRefreshing = false

    // Presentation hooks for WelcomeView / LoginSheet.
    @Published var isAddingCluster = false
    @Published var loginQueue: [UUID] = []
    @Published private(set) var activeLoginState: ActiveLoginState?
    @Published private(set) var loginErrors: [UUID: ClusterError] = [:]

    // Platform hook extended in Task 13 (StayAwakeController / SystemEventsMonitor).
    var onStateChange: (@MainActor () -> Void)?

    private let userDefaults: UserDefaults
    private let loginExecutable: String
    private var cancellables: Set<AnyCancellable> = []
    private var timerTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var loginGeneration: UInt64 = 0
    private var activeSSHConfigTask: Task<Void, Never>?
    private var requestedSSHConfigGeneration: UInt64 = 0
    private var attemptedSSHConfigGeneration: UInt64 = 0
    private var hasGeneratedSSHConfig = false
    private var lastUserSSHConfigMTime: Date?
    private var activeRefreshCount = 0
    private var didBootstrap = false
    private var pendingLoginAfterAddSheet: [UUID] = []
    private var resolvedControlPaths: [UUID: String] = [:]

    init(
        paths: AppPaths = .default,
        runner: CommandRunner = ProcessCommandRunner(),
        userDefaults: UserDefaults = .standard,
        loginExecutable: String = "/usr/bin/ssh",
        autoStart: Bool = true
    ) {
        self.paths = paths
        self.runner = runner
        self.userDefaults = userDefaults
        self.loginExecutable = loginExecutable

        var loadedSettings = AppSettings.load(from: userDefaults)
        loadedSettings.refreshIntervalMinutes = Self.clampedIntervalMinutes(loadedSettings.refreshIntervalMinutes)
        self.settings = loadedSettings

        let store = ClusterStore(fileURL: paths.clusters)
        let cache = SnapshotCache(directory: paths.cache)
        self.model = MonitorModel(
            store: store,
            cache: cache,
            transports: Self.makeTransportFactory(paths: paths, runner: runner)
        )

        self.model.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        if autoStart {
            bootstrap()
        }
    }

    /// Runs initial SSH config generation, background check-in, and starts the periodic refresh timer.
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        startTimers()
        Task { [weak self] in
            guard let self else { return }
            await self.regenerateSSHConfig()
            await self.refreshAll(.background)
        }
    }

    /// Reads `~/.ssh/config` safely, resolves `ControlPath` per enabled cluster, and writes `~/.slurm-monitor/ssh_config`.
    func regenerateSSHConfig() async {
        requestedSSHConfigGeneration &+= 1
        let targetGeneration = requestedSSHConfigGeneration

        while attemptedSSHConfigGeneration < targetGeneration {
            if let existing = activeSSHConfigTask {
                await existing.value
            } else {
                let runGeneration = requestedSSHConfigGeneration
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer {
                        self.activeSSHConfigTask = nil
                        self.attemptedSSHConfigGeneration = max(self.attemptedSSHConfigGeneration, runGeneration)
                    }
                    await self.performRegenerateSSHConfig()
                }
                activeSSHConfigTask = task
                await task.value
            }
        }
    }

    /// Starts (or restarts) the periodic background refresh and §5.4a keep-alive check-in timer.
    func startTimers() {
        timerTask?.cancel()
        let intervalMinutes = Self.clampedIntervalMinutes(settings.refreshIntervalMinutes)
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalMinutes * 60))
                guard !Task.isCancelled, let self else { break }
                await self.refreshAll(.background)
            }
        }
    }

    /// Regenerates SSH config if `~/.ssh/config` changed on disk, then refreshes monitored clusters.
    func refreshAll(_ reason: RefreshReason) async {
        activeRefreshCount += 1
        isRefreshing = true
        defer {
            activeRefreshCount = max(0, activeRefreshCount - 1)
            isRefreshing = activeRefreshCount > 0
            onStateChange?()
        }

        await regenerateSSHConfigIfUserConfigChanged()
        await model.refreshAll(reason)
        clearResolvedLoginErrors()
    }

    /// Persists updated cluster definitions, regenerates the app SSH config, and refreshes non-interactively.
    func saveClusters(_ configs: [ClusterConfig], refreshTargetID: UUID? = nil) async throws {
        try model.setClusters(configs)
        let validIDs = Set(configs.map(\.id))
        loginErrors = loginErrors.filter { validIDs.contains($0.key) }
        resolvedControlPaths = resolvedControlPaths.filter { validIDs.contains($0.key) }
        if let refreshTargetID {
            loginErrors.removeValue(forKey: refreshTargetID)
        }
        await regenerateSSHConfig()
        if let refreshTargetID {
            await model.refresh(refreshTargetID, .manual)
            syncLoginError(for: refreshTargetID)
        }
        onStateChange?()
    }

    /// Walks `ids` sequentially, probing existing shared connections and presenting `LoginSheet` only when login is required.
    func login(_ ids: [UUID]) {
        var seen = Set<UUID>()
        let validIDs = Set(model.clusters.filter(\.config.enabled).map(\.config.id))
        let filtered = ids.filter { validIDs.contains($0) && seen.insert($0).inserted }

        cancelLogin()
        guard !filtered.isEmpty else { return }

        loginGeneration &+= 1
        let generation = loginGeneration
        loginQueue = filtered
        loginTask = Task { @MainActor [weak self] in
            await self?.runLoginQueue(filtered, generation: generation)
        }
    }

    /// Closes the add-cluster sheet and launches `login(_:)` once sheet dismissal completes.
    func dismissAddClusterSheetAndLogin(_ ids: [UUID]) {
        pendingLoginAfterAddSheet = ids
        isAddingCluster = false
    }

    /// Runs any deferred login queue after the add-cluster sheet finishes dismissing.
    func handleSheetDismissed() {
        guard !isAddingCluster, !pendingLoginAfterAddSheet.isEmpty else { return }
        let ids = pendingLoginAfterAddSheet
        pendingLoginAfterAddSheet = []
        login(ids)
    }

    /// Cancels any active interactive login session and clears queued login state.
    func cancelLogin() {
        loginGeneration &+= 1
        pendingLoginAfterAddSheet = []
        if case .session(let controller) = activeLoginState {
            controller.stop()
        }
        loginTask?.cancel()
        loginTask = nil
        activeLoginState = nil
        loginQueue = []

        for view in model.clusters where view.status == .loggingIn {
            model.setLoggingIn(view.config.id, false)
        }
        onStateChange?()
    }

    /// Returns a cached or expanded default socket path immediately for display before async `ssh -G` resolution completes.
    func immediateControlPath(for cluster: ClusterConfig) -> String {
        if let cached = resolvedControlPaths[cluster.id], !cached.isEmpty {
            return cached
        }
        let userConfigText = (try? String(contentsOf: paths.userSSHConfig, encoding: .utf8)) ?? ""
        let template = ControlPathResolver.userTemplate(
            configText: userConfigText,
            alias: cluster.sshAlias,
            hostName: cluster.host
        ) ?? paths.socketTemplate
        return NSString(string: template).expandingTildeInPath
    }

    /// Resolves the live `ControlPath` socket path for `cluster` and reports whether `~/.ssh/config` already defines one.
    func resolvedControlPathInfo(for cluster: ClusterConfig) async -> (controlPath: String, fromUserConfig: Bool) {
        let userConfigText = (try? String(contentsOf: paths.userSSHConfig, encoding: .utf8)) ?? ""
        let userTemplate = ControlPathResolver.userTemplate(
            configText: userConfigText,
            alias: cluster.sshAlias,
            hostName: cluster.host
        )
        let resolved = await ControlPathResolver.resolve(
            cluster: cluster,
            userConfigText: userConfigText,
            appTemplate: paths.socketTemplate,
            runner: runner
        )
        return (resolved.controlPath, userTemplate != nil)
    }

    /// Formats an optional `~/.ssh/config` block allowing Terminal sessions to share the app's `ControlPath` socket.
    func sshReuseSnippet(for cluster: ClusterConfig, controlPath: String) -> String {
        let trimmedAlias = cluster.sshAlias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedName = cluster.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostAlias: String
        if !trimmedAlias.isEmpty {
            hostAlias = trimmedAlias
        } else if !trimmedName.isEmpty && !trimmedName.contains(where: \.isWhitespace) {
            hostAlias = trimmedName
        } else {
            hostAlias = cluster.generatedAlias
        }

        let formattedPath = controlPath.contains(where: \.isWhitespace)
            ? "\"\(controlPath)\""
            : controlPath

        return """
        Host \(hostAlias)
          HostName \(cluster.host)
          User \(cluster.username)
          ControlMaster auto
          ControlPath \(formattedPath)
          ControlPersist yes
        """
    }

    /// Username shown in the panel header, preferring the first enabled cluster.
    var displayUsername: String {
        if let enabledUser = model.clusters.first(where: { $0.config.enabled && !$0.config.username.isEmpty })?.config.username {
            return enabledUser
        }
        if let firstUser = model.clusters.first(where: { !$0.config.username.isEmpty })?.config.username {
            return firstUser
        }
        return NSUserName()
    }

    /// Most recent snapshot fetch date across enabled clusters.
    var latestSnapshotDate: Date? {
        model.clusters
            .filter(\.config.enabled)
            .compactMap(\.snapshot?.fetchedAt)
            .max()
    }

    /// Identifiers of enabled clusters that are not currently `.live` or `.loggingIn`.
    var staleOrErrorEnabledClusterIDs: [UUID] {
        model.clusters
            .filter { $0.config.enabled && $0.status != .live && $0.status != .loggingIn }
            .map(\.config.id)
    }

    private func runLoginQueue(_ ids: [UUID], generation: UInt64) async {
        defer {
            if loginGeneration == generation {
                loginTask = nil
                activeLoginState = nil
                loginQueue = []
                onStateChange?()
            }
        }

        await regenerateSSHConfigIfUserConfigChanged()
        guard !Task.isCancelled, loginGeneration == generation else { return }

        for (index, id) in ids.enumerated() {
            guard !Task.isCancelled, loginGeneration == generation else { break }
            let shouldContinue = await processQueuedCluster(
                id: id,
                position: index + 1,
                total: ids.count,
                generation: generation
            )
            if !shouldContinue {
                break
            }
        }
    }

    private func processQueuedCluster(
        id: UUID,
        position: Int,
        total: Int,
        generation: UInt64
    ) async -> Bool {
        guard let cluster = model.clusters.first(where: { $0.config.id == id && $0.config.enabled })?.config else {
            return true
        }

        loginErrors.removeValue(forKey: id)
        model.setLoggingIn(id, true)
        var didResetLoggingIn = false
        defer {
            if !didResetLoggingIn {
                model.setLoggingIn(id, false)
            }
        }

        if activeLoginState != nil {
            activeLoginState = .preparing(
                cluster: cluster,
                position: position,
                total: total,
                status: "Checking existing connection…"
            )
        }

        let transport = SharedSSHTransport(
            alias: cluster.generatedAlias,
            configPath: paths.sshConfig.path,
            runner: runner
        )

        if await transport.probe() == .usable {
            guard !Task.isCancelled, loginGeneration == generation else { return false }
            model.setLoggingIn(id, false)
            didResetLoggingIn = true
            await model.refresh(id, .afterLogin)
            syncLoginError(for: id)
            onStateChange?()
            return true
        }

        guard !Task.isCancelled, loginGeneration == generation else { return false }

        if activeLoginState != nil {
            activeLoginState = .preparing(
                cluster: cluster,
                position: position,
                total: total,
                status: "Freeing stale socket…"
            )
        }

        await transport.stopStaleMaster()
        guard !Task.isCancelled, loginGeneration == generation else { return false }

        let controller = LoginSessionController(
            cluster: cluster,
            configPath: paths.sshConfig.path,
            position: position,
            total: total,
            executable: loginExecutable
        )
        activeLoginState = .session(controller)

        let outcome = await controller.run()
        guard loginGeneration == generation else {
            return false
        }

        switch outcome {
        case .succeeded:
            loginErrors.removeValue(forKey: id)
            model.setLoggingIn(id, false)
            didResetLoggingIn = true
            await model.refresh(id, .afterLogin)
            syncLoginError(for: id)
            onStateChange?()
            return true

        case .skipped(let error):
            if let error {
                loginErrors[id] = error
            }
            model.setLoggingIn(id, false)
            didResetLoggingIn = true
            onStateChange?()
            return true

        case .stopped(let error):
            if let error {
                loginErrors[id] = error
            }
            model.setLoggingIn(id, false)
            didResetLoggingIn = true
            onStateChange?()
            return false
        }
    }

    private func clearResolvedLoginErrors() {
        for view in model.clusters where view.status == .live {
            loginErrors.removeValue(forKey: view.config.id)
        }
    }

    private func syncLoginError(for id: UUID) {
        if let view = model.clusters.first(where: { $0.config.id == id }), view.status == .live {
            loginErrors.removeValue(forKey: id)
        }
    }

    private func regenerateSSHConfigIfUserConfigChanged() async {
        while let existing = activeSSHConfigTask {
            await existing.value
        }
        let currentMTime = Self.modificationDate(of: paths.userSSHConfig)
        if !hasGeneratedSSHConfig
            || currentMTime != lastUserSSHConfigMTime
            || attemptedSSHConfigGeneration < requestedSSHConfigGeneration {
            await regenerateSSHConfig()
        }
    }

    private func performRegenerateSSHConfig() async {
        let mtime = Self.modificationDate(of: paths.userSSHConfig)
        let userConfigText = (try? String(contentsOf: paths.userSSHConfig, encoding: .utf8)) ?? ""

        let enabledClusters = model.clusters.map(\.config).filter(\.enabled)
        let appTemplate = paths.socketTemplate
        let runner = self.runner

        let resolvedResults = await withTaskGroup(of: (Int, UUID, String, String).self) { group in
            for (index, cluster) in enabledClusters.enumerated() {
                group.addTask {
                    let resolved = await ControlPathResolver.resolve(
                        cluster: cluster,
                        userConfigText: userConfigText,
                        appTemplate: appTemplate,
                        runner: runner
                    )
                    let block = GeneratedSSHConfig.block(
                        for: cluster,
                        sshG: resolved.sshG,
                        controlPath: resolved.controlPath
                    )
                    return (index, cluster.id, block, resolved.controlPath)
                }
            }

            var orderedBlocks = Array(repeating: "", count: enabledClusters.count)
            var pathsByID: [UUID: String] = [:]
            for await (index, id, block, controlPath) in group {
                orderedBlocks[index] = block
                pathsByID[id] = controlPath
            }
            return (orderedBlocks, pathsByID)
        }

        do {
            try GeneratedSSHConfig.write(blocks: resolvedResults.0, to: paths.sshConfig)
            resolvedControlPaths = resolvedResults.1
            lastUserSSHConfigMTime = mtime
            hasGeneratedSSHConfig = true
        } catch {
            // Leave generation state unchanged so subsequent refresh ticks retry the write.
        }
    }

    private static func makeTransportFactory(
        paths: AppPaths,
        runner: CommandRunner
    ) -> @Sendable (ClusterConfig) -> [ClusterTransport] {
        let sshConfigPath = paths.sshConfig.path
        return { cluster in
            cluster.methods.compactMap { method in
                switch method {
                case .sharedSSH:
                    return SharedSSHTransport(
                        alias: cluster.generatedAlias,
                        configPath: sshConfigPath,
                        runner: runner
                    )
                case .robot:
                    return nil
                }
            }
        }
    }

    private static func modificationDate(of fileURL: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    private static func clampedIntervalMinutes(_ value: Int) -> Int {
        max(1, min(30, value))
    }
}
