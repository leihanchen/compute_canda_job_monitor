import Combine
import Foundation
import SlurmMonitorCore

/// Standard filesystem locations used by Slurm Monitor under `~/.slurm-monitor`.
struct AppPaths: Sendable {
    let root: URL
    let clusters: URL
    let cache: URL
    let sshConfig: URL
    let userSSHConfig: URL
    let socketTemplate: String

    static let `default`: AppPaths = AppPaths()

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".slurm-monitor", isDirectory: true),
        userSSHConfig: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false),
        socketTemplate: String = "~/.slurm-monitor/cm-%C"
    ) {
        self.root = root
        self.clusters = root.appendingPathComponent("clusters.json", isDirectory: false)
        self.cache = root.appendingPathComponent("cache", isDirectory: true)
        self.sshConfig = root.appendingPathComponent("ssh_config", isDirectory: false)
        self.userSSHConfig = userSSHConfig
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

    // Presentation hooks extended in Task 12 (WelcomeView / LoginSheet).
    @Published var isAddingCluster = false
    @Published var loginQueue: [UUID] = []

    // Platform hook extended in Task 13 (StayAwakeController / SystemEventsMonitor).
    var onStateChange: (@MainActor () -> Void)?

    private let userDefaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []
    private var timerTask: Task<Void, Never>?
    private var activeSSHConfigTask: Task<Void, Never>?
    private var hasGeneratedSSHConfig = false
    private var lastUserSSHConfigMTime: Date?
    private var activeRefreshCount = 0
    private var didBootstrap = false

    init(
        paths: AppPaths = .default,
        runner: CommandRunner = ProcessCommandRunner(),
        userDefaults: UserDefaults = .standard,
        autoStart: Bool = true
    ) {
        self.paths = paths
        self.runner = runner
        self.userDefaults = userDefaults

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
        while let existing = activeSSHConfigTask {
            await existing.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRegenerateSSHConfig()
        }
        activeSSHConfigTask = task
        await task.value
        if activeSSHConfigTask == task {
            activeSSHConfigTask = nil
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
    }

    /// Persists updated cluster definitions, regenerates the app SSH config, and refreshes non-interactively.
    func saveClusters(_ configs: [ClusterConfig], refreshTargetID: UUID? = nil) async throws {
        try model.setClusters(configs)
        await regenerateSSHConfig()
        if let refreshTargetID {
            await model.refresh(refreshTargetID, .manual)
        }
        onStateChange?()
    }

    /// Queues interactive login for the specified cluster IDs (implemented with `LoginSheet` in Task 12).
    func login(_ ids: [UUID]) {
        let validIDs = Set(model.clusters.filter(\.config.enabled).map(\.config.id))
        let filtered = ids.filter { validIDs.contains($0) }
        loginQueue = filtered
    }

    /// Clears any queued login presentation state.
    func cancelLogin() {
        loginQueue = []
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

    private func regenerateSSHConfigIfUserConfigChanged() async {
        let currentMTime = Self.modificationDate(of: paths.userSSHConfig)
        if !hasGeneratedSSHConfig || currentMTime != lastUserSSHConfigMTime {
            await regenerateSSHConfig()
        }
    }

    private func performRegenerateSSHConfig() async {
        let mtime = Self.modificationDate(of: paths.userSSHConfig)
        let userConfigText = (try? String(contentsOf: paths.userSSHConfig, encoding: .utf8)) ?? ""
        lastUserSSHConfigMTime = mtime
        hasGeneratedSSHConfig = true

        let enabledClusters = model.clusters.map(\.config).filter(\.enabled)
        let appTemplate = paths.socketTemplate
        let runner = self.runner

        let blocks = await withTaskGroup(of: (Int, String).self) { group in
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
                    return (index, block)
                }
            }

            var ordered = Array(repeating: "", count: enabledClusters.count)
            for await (index, block) in group {
                ordered[index] = block
            }
            return ordered
        }

        try? GeneratedSSHConfig.write(blocks: blocks, to: paths.sshConfig)
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
