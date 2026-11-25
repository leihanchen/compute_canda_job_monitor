import Foundation
import Testing
@testable import SlurmMonitorCore

@Test func probeAndRunArgv() async throws {
    let runner = FakeRunner(default: .init(exitCode: 0, stdout: "OUT", stderr: "", timedOut: false))
    let t = SharedSSHTransport(alias: "smon-nibi", configPath: "/c", runner: runner)
    #expect(t.kind == .sharedSSH)
    #expect(await t.probe() == .usable)
    #expect(try await t.run("SCRIPT", timeout: 15) == "OUT")
    await t.stopStaleMaster()

    #expect(runner.calls.map(\.executable) == ["/usr/bin/ssh", "/usr/bin/ssh", "/usr/bin/ssh"])
    #expect(runner.calls.map(\.args) == [
        ["-F", "/c", "-O", "check", "smon-nibi"],
        ["-F", "/c", "-o", "BatchMode=yes", "-o", "ControlMaster=no", "smon-nibi", "bash", "-l", "-s"],
        ["-F", "/c", "-O", "stop", "smon-nibi"],
    ])
    #expect(runner.calls[0].stdin == nil)
    #expect(runner.calls[1].stdin == "SCRIPT")
    #expect(runner.calls[2].stdin == nil)
    #expect(runner.timeouts == [5, 15, 5])
    #expect(!runner.calls.flatMap(\.args).contains("exit"))
}

@Test func probeFailureReturnsUnavailableNeedsLogin() async {
    let runner = FakeRunner()
    runner.enqueue(
        where: { _, args, _ in args.contains("check") },
        result: CommandResult(
            exitCode: 255,
            stdout: "",
            stderr: "Control socket connect(/tmp/s): Connection refused",
            timedOut: false
        )
    )
    let t = SharedSSHTransport(alias: "smon-fir", configPath: "/tmp/cfg", runner: runner)
    #expect(await t.probe() == .unavailable(.needsLogin))

    runner.enqueue(
        where: { _, args, _ in args.contains("check") },
        result: CommandResult(exitCode: 0, stdout: "", stderr: "", timedOut: true)
    )
    #expect(await t.probe() == .unavailable(.needsLogin))
}

@Test func runFailureThrowsClassifiedClusterError() async {
    let runner = FakeRunner()
    let t = SharedSSHTransport(alias: "smon-trillium", configPath: "/tmp/cfg", runner: runner)

    runner.enqueue(
        where: { _, args, _ in args.contains("BatchMode=yes") },
        result: CommandResult(
            exitCode: 255,
            stdout: "",
            stderr: "leihan@trillium: Permission denied (publickey).",
            timedOut: false
        )
    )
    await #expect(throws: ClusterError.needsSSHKey) {
        _ = try await t.run("echo hi", timeout: 15)
    }

    runner.enqueue(
        where: { _, args, _ in args.contains("BatchMode=yes") },
        result: CommandResult(
            exitCode: 255,
            stdout: "",
            stderr: "Access denied for user leihan",
            timedOut: false
        )
    )
    await #expect(throws: ClusterError.noAccess) {
        _ = try await t.run("echo hi", timeout: 15)
    }

    runner.enqueue(
        where: { _, args, _ in args.contains("BatchMode=yes") },
        result: CommandResult(exitCode: 0, stdout: "partial", stderr: "", timedOut: true)
    )
    await #expect(throws: ClusterError.unreachable) {
        _ = try await t.run("echo hi", timeout: 15)
    }
}

@Test func chainSkipsUnusable() async {
    let robot = FakeTransport(kind: .robot, probeResult: .unavailable(.unreachable))
    let shared = FakeTransport(kind: .sharedSSH, probeResult: .usable)
    let r = await ConnectionChain([robot, shared]).firstUsable()
    #expect((try? r.get())?.kind == .sharedSSH)
    #expect(robot.probeCount == 1)
    #expect(shared.probeCount == 1)

    let none = await ConnectionChain([robot]).firstUsable()
    #expect(none.failureValue == .unreachable)
}

@Test func chainShortCircuitsAndHandlesMultiFailureAndEmptyChain() async throws {
    let first = FakeTransport(kind: .robot, probeResult: .usable, runResult: .success("ROBOT_OUT"))
    let second = FakeTransport(kind: .sharedSSH, probeResult: .usable)
    let chain = ConnectionChain([first, second])
    let selected = try await chain.firstUsable().get()
    #expect(selected.kind == .robot)
    #expect(first.probeCount == 1)
    #expect(second.probeCount == 0)

    let out = try await selected.run("SCRIPT_1", timeout: 10)
    #expect(out == "ROBOT_OUT")
    #expect(first.runCount == 1)
    #expect(first.scripts == ["SCRIPT_1"])

    let t1 = FakeTransport(kind: .robot, probeResult: .unavailable(.unreachable))
    let t2 = FakeTransport(kind: .sharedSSH, probeResult: .unavailable(.noAccess))
    let allFailed = await ConnectionChain([t1, t2]).firstUsable()
    #expect(allFailed.failureValue == .noAccess)
    #expect(t1.probeCount == 1)
    #expect(t2.probeCount == 1)

    let emptyResult = await ConnectionChain([]).firstUsable()
    #expect(emptyResult.failureValue == .needsLogin)
}

@Test func fakeTransportTracksCountsThroughExistentialAndSupportsRunHandler() async throws {
    let fake = FakeTransport(
        kind: .sharedSSH,
        probeResult: .usable,
        runHandler: { script, timeout in
            if script == "FAIL" {
                throw ClusterError.slurmFailed("bad")
            }
            return "\(script):\(Int(timeout))"
        }
    )
    let transports: [ClusterTransport] = [fake]
    let usable = try await ConnectionChain(transports).firstUsable().get()
    #expect(try await usable.run("OK", timeout: 12) == "OK:12")
    await #expect(throws: ClusterError.slurmFailed("bad")) {
        _ = try await usable.run("FAIL", timeout: 15)
    }
    #expect(fake.probeCount == 1)
    #expect(fake.runCount == 2)
    #expect(fake.scripts == ["OK", "FAIL"])
    #expect(fake.timeouts == [12, 15])
}
