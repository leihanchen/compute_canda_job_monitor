import AppKit
import Foundation
import Network
import os

private struct SendableObserverToken: @unchecked Sendable {
    let token: NSObjectProtocol
}

private final class SystemEventsMonitorCore: @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var isRunning = false
        var hasSeenInitialPath = false
        var pathMonitor: NWPathMonitor?
        var wakeObserver: SendableObserverToken?
        var debounceTask: Task<Void, Never>?
        var debounceGeneration: UInt64 = 0
    }

    private let debounceInterval: Duration
    private let notificationCenter: NotificationCenter
    private let onChange: @MainActor () -> Void
    private let monitorQueue = DispatchQueue(label: "ca.slurmmonitor.system-events", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        debounceInterval: Duration,
        notificationCenter: NotificationCenter,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.debounceInterval = debounceInterval
        self.notificationCenter = notificationCenter
        self.onChange = onChange
    }

    func start() {
        let shouldStart = state.withLock { state -> Bool in
            guard !state.isRunning else { return false }
            state.isRunning = true
            state.hasSeenInitialPath = false
            return true
        }
        guard shouldStart else { return }

        let observer = SendableObserverToken(
            token: notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.scheduleDebouncedChange()
            }
        )

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            self?.handlePathUpdate()
        }

        let stored = state.withLock { state -> Bool in
            guard state.isRunning else { return false }
            state.wakeObserver = observer
            state.pathMonitor = monitor
            return true
        }

        if stored {
            monitor.start(queue: monitorQueue)
        } else {
            notificationCenter.removeObserver(observer.token)
            monitor.pathUpdateHandler = nil
            monitor.cancel()
        }
    }

    func stop() {
        let (observer, monitor, task) = state.withLock { state -> (SendableObserverToken?, NWPathMonitor?, Task<Void, Never>?) in
            state.isRunning = false
            state.hasSeenInitialPath = false
            state.debounceGeneration &+= 1
            let observer = state.wakeObserver
            let monitor = state.pathMonitor
            let task = state.debounceTask
            state.wakeObserver = nil
            state.pathMonitor = nil
            state.debounceTask = nil
            return (observer, monitor, task)
        }

        task?.cancel()
        if let observer {
            notificationCenter.removeObserver(observer.token)
        }
        if let monitor {
            monitor.pathUpdateHandler = nil
            monitor.cancel()
        }
    }

    private func handlePathUpdate() {
        let shouldNotify = state.withLock { state -> Bool in
            guard state.isRunning else { return false }
            // Skip the initial path callback emitted immediately on NWPathMonitor.start(queue:).
            if !state.hasSeenInitialPath {
                state.hasSeenInitialPath = true
                return false
            }
            return true
        }
        if shouldNotify {
            scheduleDebouncedChange()
        }
    }

    private func scheduleDebouncedChange() {
        let interval = debounceInterval
        let (previousTask, generation) = state.withLock { state -> (Task<Void, Never>?, UInt64) in
            guard state.isRunning else { return (nil, 0) }
            state.debounceGeneration &+= 1
            let gen = state.debounceGeneration
            let previous = state.debounceTask
            state.debounceTask = nil
            return (previous, gen)
        }
        previousTask?.cancel()
        guard generation != 0 else { return }

        let newTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard let self else { return }
            let shouldFire = self.state.withLock { state -> Bool in
                guard state.isRunning,
                      state.debounceGeneration == generation,
                      !Task.isCancelled else {
                    return false
                }
                state.debounceTask = nil
                return true
            }
            guard shouldFire else { return }
            self.onChange()
        }

        let cancelNewTask = state.withLock { state -> Bool in
            guard state.isRunning, state.debounceGeneration == generation else {
                return true
            }
            state.debounceTask = newTask
            return false
        }
        if cancelNewTask {
            newTask.cancel()
        }
    }
}

/// Observes system wake and network path changes, debouncing callbacks on `@MainActor`.
@MainActor
final class SystemEventsMonitor {
    private let core: SystemEventsMonitorCore

    init(
        debounceInterval: Duration = .seconds(3),
        autoStart: Bool = true,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.core = SystemEventsMonitorCore(
            debounceInterval: debounceInterval,
            notificationCenter: notificationCenter,
            onChange: onChange
        )
        if autoStart {
            start()
        }
    }

    deinit {
        core.stop()
    }

    /// Starts observing `NSWorkspace.didWakeNotification` and `NWPathMonitor` updates.
    func start() {
        core.start()
    }

    /// Stops observing wake and network events and cancels any pending debounce timer.
    nonisolated func stop() {
        core.stop()
    }
}
