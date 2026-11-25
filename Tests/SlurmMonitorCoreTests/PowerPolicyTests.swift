import Testing
import SlurmMonitorCore

@Test func power() {
    #expect(PowerPolicy.shouldHoldAssertion(enabled: true, onACPower: true, liveConnections: 1))
    #expect(!PowerPolicy.shouldHoldAssertion(enabled: true, onACPower: false, liveConnections: 3))
    #expect(!PowerPolicy.shouldHoldAssertion(enabled: false, onACPower: true, liveConnections: 3))
    #expect(!PowerPolicy.shouldHoldAssertion(enabled: true, onACPower: true, liveConnections: 0))
}

@Test func powerPolicyHandlesMultipleAndNegativeConnections() {
    #expect(PowerPolicy.shouldHoldAssertion(enabled: true, onACPower: true, liveConnections: 5))
    #expect(!PowerPolicy.shouldHoldAssertion(enabled: true, onACPower: true, liveConnections: -1))
    #expect(!PowerPolicy.shouldHoldAssertion(enabled: false, onACPower: false, liveConnections: 0))
}
