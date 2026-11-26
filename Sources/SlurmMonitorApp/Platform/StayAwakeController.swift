import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import os
import SlurmMonitorCore

private final class StayAwakeCallbackBox: @unchecked Sendable {
    private struct State {
        weak var controller: StayAwakeController?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(controller: StayAwakeController) {
        self.state = OSAllocatedUnfairLock(initialState: State(controller: controller))
    }

    func controller() -> StayAwakeController? {
        state.withLock { $0.controller }
    }

    func clear() {
        state.withLock { $0.controller = nil }
    }
}

private final class RunLoopSourceBox: @unchecked Sendable {
    private let source: CFRunLoopSource
    private let context: Unmanaged<StayAwakeCallbackBox>
    private var isInvalidated = false

    init(source: CFRunLoopSource, context: Unmanaged<StayAwakeCallbackBox>) {
        self.source = source
        self.context = context
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFRunLoopSourceInvalidate(source)
        context.release()
    }
}

private func powerSourceChangedCallback(context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let box = Unmanaged<StayAwakeCallbackBox>.fromOpaque(context).takeUnretainedValue()
    guard let controller = box.controller() else { return }
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            controller.handlePowerSourceChanged()
        }
    } else {
        Task { @MainActor in
            controller.handlePowerSourceChanged()
        }
    }
}

/// Manages an IOKit `PreventUserIdleSystemSleep` assertion while on AC power with live clusters.
@MainActor
final class StayAwakeController {
    typealias PowerSourceReader = @Sendable () -> Bool
    typealias AssertionCreator = @Sendable (String) -> IOPMAssertionID?
    typealias AssertionReleaser = @Sendable (IOPMAssertionID) -> Void

    private static let assertionReason = "Slurm Monitor keeping cluster connections alive"

    private struct State: @unchecked Sendable {
        var assertionID: IOPMAssertionID?
        var lastEnabled = false
        var lastLiveConnections = 0
        var observerBox: RunLoopSourceBox?
        var callbackBox: StayAwakeCallbackBox?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let isOnACPower: PowerSourceReader
    private let createAssertion: AssertionCreator
    private let releaseAssertion: AssertionReleaser

    /// Whether a power assertion is currently held.
    var isHoldingAssertion: Bool {
        state.withLock { $0.assertionID != nil }
    }

    init(
        observePowerSource: Bool = true,
        isOnACPower: @escaping PowerSourceReader = { StayAwakeController.readIsOnACPower() },
        createAssertion: @escaping AssertionCreator = { StayAwakeController.createPowerAssertion($0) },
        releaseAssertion: @escaping AssertionReleaser = { StayAwakeController.releasePowerAssertion($0) }
    ) {
        self.isOnACPower = isOnACPower
        self.createAssertion = createAssertion
        self.releaseAssertion = releaseAssertion

        if observePowerSource {
            startObservingPowerSource()
        }
    }

    deinit {
        let (activeID, observerBox, callbackBox) = state.withLock { state -> (IOPMAssertionID?, RunLoopSourceBox?, StayAwakeCallbackBox?) in
            let id = state.assertionID
            state.assertionID = nil
            let observer = state.observerBox
            state.observerBox = nil
            let callback = state.callbackBox
            state.callbackBox = nil
            return (id, observer, callback)
        }
        callbackBox?.clear()
        if let activeID {
            releaseAssertion(activeID)
        }
        Self.teardownObserver(observerBox)
    }

    /// Registers for immediate power-source notifications on the main run loop so AC-to-battery switches release promptly.
    func startObservingPowerSource() {
        let alreadyObserving = state.withLock { $0.observerBox != nil }
        guard !alreadyObserving else { return }

        let callbackBox = StayAwakeCallbackBox(controller: self)
        let unmanagedContext = Unmanaged.passRetained(callbackBox)

        guard let source = IOPSNotificationCreateRunLoopSource(
            powerSourceChangedCallback,
            unmanagedContext.toOpaque()
        )?.takeRetainedValue() else {
            unmanagedContext.release()
            return
        }

        let observerBox = RunLoopSourceBox(source: source, context: unmanagedContext)
        let stored = state.withLock { state -> Bool in
            guard state.observerBox == nil else { return false }
            state.callbackBox = callbackBox
            state.observerBox = observerBox
            return true
        }

        if stored {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        } else {
            callbackBox.clear()
            Self.teardownObserver(observerBox)
        }
    }

    /// Evaluates `PowerPolicy` against current AC state and acquires or releases the sleep assertion idempotently.
    func update(enabled: Bool, liveConnections: Int) {
        let onACPower = isOnACPower()
        let shouldHold = PowerPolicy.shouldHoldAssertion(
            enabled: enabled,
            onACPower: onACPower,
            liveConnections: liveConnections
        )

        if shouldHold {
            let existingID = state.withLock { state -> IOPMAssertionID? in
                state.lastEnabled = enabled
                state.lastLiveConnections = liveConnections
                return state.assertionID
            }
            if existingID == nil, let newID = createAssertion(Self.assertionReason) {
                let duplicateID = state.withLock { state -> IOPMAssertionID? in
                    if state.assertionID != nil {
                        return newID
                    }
                    state.assertionID = newID
                    return nil
                }
                if let duplicateID {
                    releaseAssertion(duplicateID)
                }
            }
        } else {
            let activeID = state.withLock { state -> IOPMAssertionID? in
                state.lastEnabled = enabled
                state.lastLiveConnections = liveConnections
                let id = state.assertionID
                state.assertionID = nil
                return id
            }
            if let activeID {
                releaseAssertion(activeID)
            }
        }
    }

    /// Immediately releases any held assertion and resets cached policy inputs.
    nonisolated func release() {
        let activeID = state.withLock { state -> IOPMAssertionID? in
            state.lastEnabled = false
            state.lastLiveConnections = 0
            let id = state.assertionID
            state.assertionID = nil
            return id
        }
        if let activeID {
            releaseAssertion(activeID)
        }
    }

    fileprivate func handlePowerSourceChanged() {
        let (enabled, liveConnections) = state.withLock { ($0.lastEnabled, $0.lastLiveConnections) }
        update(enabled: enabled, liveConnections: liveConnections)
    }

    private nonisolated static func teardownObserver(_ box: RunLoopSourceBox?) {
        guard let box else { return }
        if Thread.isMainThread {
            box.invalidate()
        } else {
            DispatchQueue.main.async {
                box.invalidate()
            }
        }
    }

    private nonisolated static func readIsOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourceType = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? else {
            return false
        }
        return sourceType == kIOPMACPowerKey
    }

    private nonisolated static func createPowerAssertion(_ reason: String) -> IOPMAssertionID? {
        var assertionID = IOPMAssertionID(kIOPMNullAssertionID)
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        guard status == kIOReturnSuccess, assertionID != IOPMAssertionID(kIOPMNullAssertionID) else {
            return nil
        }
        return assertionID
    }

    private nonisolated static func releasePowerAssertion(_ assertionID: IOPMAssertionID) {
        _ = IOPMAssertionRelease(assertionID)
    }
}
