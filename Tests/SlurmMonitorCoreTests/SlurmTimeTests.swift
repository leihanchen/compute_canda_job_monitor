import Foundation
import Testing
import SlurmMonitorCore

@Test func durations() {
    #expect(SlurmTime.duration("1-02:03:04") == 93784)
    #expect(SlurmTime.duration("02:03:04") == 7384)
    #expect(SlurmTime.duration("03:04") == 184)
    #expect(SlurmTime.duration("0:00") == 0)
    #expect(SlurmTime.duration("48:00:00") == 172800)
    #expect(SlurmTime.duration("10-00:00:00") == 864000)
    #expect(SlurmTime.duration("UNLIMITED") == nil)
    #expect(SlurmTime.duration("INVALID") == nil)
    #expect(SlurmTime.duration("NOT_SET") == nil)
    #expect(SlurmTime.duration("N/A") == nil)
    #expect(SlurmTime.duration("(null)") == nil)
    #expect(SlurmTime.duration("Unknown") == nil)
    #expect(SlurmTime.duration("None") == nil)
    #expect(SlurmTime.duration("") == nil)
    #expect(SlurmTime.duration("-1:00") == nil)
    #expect(SlurmTime.duration("bad") == nil)
}

@Test func datesUseLocalTimeZoneAndRejectSentinels() throws {
    let parsed = try #require(SlurmTime.date("2026-11-25T18:30:05"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed)
    #expect(components.year == 2026)
    #expect(components.month == 11)
    #expect(components.day == 25)
    #expect(components.hour == 18)
    #expect(components.minute == 30)
    #expect(components.second == 5)

    #expect(SlurmTime.date("N/A") == nil)
    #expect(SlurmTime.date("(null)") == nil)
    #expect(SlurmTime.date("Unknown") == nil)
    #expect(SlurmTime.date("None") == nil)
    #expect(SlurmTime.date("") == nil)
    #expect(SlurmTime.date("2026-13-40T00:00:00") == nil)
    #expect(SlurmTime.date("not-a-date") == nil)
}

@Test func gpus() {
    #expect(SlurmTime.gpuCount("gres/gpu:4") == 4)
    #expect(SlurmTime.gpuCount("gpu:h100:2") == 2)
    #expect(SlurmTime.gpuCount("gres/gpu:a100=1") == 1)
    #expect(SlurmTime.gpuCount("gpu:2(S:0-1)") == 2)
    #expect(SlurmTime.gpuCount("gres/gpu:0") == 0)
    #expect(SlurmTime.gpuCount("cpu=32,mem=128G,gres/gpu:h100:2,gres/gpu:a100=1") == 3)
    #expect(SlurmTime.gpuCount("cpu=16,mem=64G") == nil)
    #expect(SlurmTime.gpuCount("gpu:a100") == nil)
    #expect(SlurmTime.gpuCount("N/A") == nil)
    #expect(SlurmTime.gpuCount("(null)") == nil)
    #expect(SlurmTime.gpuCount("Unknown") == nil)
    #expect(SlurmTime.gpuCount("None") == nil)
    #expect(SlurmTime.gpuCount("") == nil)
}

@Test func jobStateMappingAndTerminality() {
    #expect(JobState(slurm: "RUNNING") == .running)
    #expect(JobState(slurm: "running") == .running)
    #expect(JobState(slurm: "PENDING") == .pending)
    #expect(JobState(slurm: "COMPLETING") == .completing)
    #expect(JobState(slurm: "COMPLETED") == .completed)
    #expect(JobState(slurm: "FAILED") == .failed)
    #expect(JobState(slurm: "NODE_FAIL") == .failed)
    #expect(JobState(slurm: "BOOT_FAIL") == .failed)
    #expect(JobState(slurm: "TIMEOUT") == .timeout)
    #expect(JobState(slurm: "DEADLINE") == .timeout)
    #expect(JobState(slurm: "OUT_OF_MEMORY") == .outOfMemory)
    #expect(JobState(slurm: "CANCELLED") == .cancelled)
    #expect(JobState(slurm: "CANCELLED by 123") == .cancelled)
    #expect(JobState(slurm: "  cancelled by 999  ") == .cancelled)
    #expect(JobState(slurm: "PREEMPTED") == .other)
    #expect(JobState(slurm: "") == .other)

    #expect(!JobState.running.isTerminal)
    #expect(!JobState.pending.isTerminal)
    #expect(!JobState.completing.isTerminal)
    #expect(!JobState.other.isTerminal)

    #expect(JobState.completed.isTerminal)
    #expect(JobState.failed.isTerminal)
    #expect(JobState.timeout.isTerminal)
    #expect(JobState.outOfMemory.isTerminal)
    #expect(JobState.cancelled.isTerminal)
}
