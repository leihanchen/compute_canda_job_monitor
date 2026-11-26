import Foundation
import Testing
import SlurmMonitorCore

private let fullSampleOutput = """
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
    let id = UUID()
    let now = Date()
    let s = try SlurmQuery.parse(fullSampleOutput, clusterID: id, fetchedAt: now)
    #expect(s.clusterID == id)
    #expect(s.fetchedAt == now)
    #expect(s.active.count == 2)
    #expect(s.active[0].id == "4321")
    #expect(s.active[0].name == "train|llm")
    #expect(s.active[0].state == .running)
    #expect(s.active[0].partition == "gpubase_bygpu_b3")
    #expect(s.active[0].account == "def-alice_gpu")
    #expect(s.active[0].elapsed == 75600)
    #expect(s.active[0].timeLimit == 86400)
    #expect(s.active[0].nodes == 1)
    #expect(s.active[0].cpus == 32)
    #expect(s.active[0].memory == "128G")
    #expect(s.active[0].gpus == 4)
    #expect(s.active[0].reasonOrNodes == "ng10201")
    #expect(s.active[0].submitTime == SlurmTime.date("2026-11-24T10:00:00"))
    #expect(s.active[0].startTime == SlurmTime.date("2026-11-24T18:00:00"))
    #expect(s.active[0].workDir == "/home/alice/run")
    #expect(s.active[0].estimatedStart == nil)

    #expect(s.active[1].id == "4322_7")
    #expect(s.active[1].state == .pending)
    #expect(s.active[1].gpus == nil)
    #expect(s.active[1].startTime == nil)
    #expect(s.active[1].reasonOrNodes == "(Priority)")
    #expect(s.active[1].estimatedStart == SlurmTime.date("2026-11-25T18:30:00"))

    #expect(s.ended.map(\.id) == ["4100", "4101", "4103"])
    #expect(s.ended[0].state == .completed && s.ended[0].elapsed == 18000)
    #expect(s.ended[1].state == .failed && s.ended[1].exitCode == "1:0")
    #expect(s.ended[2].state == .cancelled && s.ended[2].exitCode == "0:15")
}

@Test func jobNamesWithPipesSpacesAndUnicodeStayAligned() throws {
    let out = """
    @@ACTIVE
    123+0|eval αβγ | stage 2 🚀 | v1|RUNNING|gpu_p|def-bob|01:02:03|04:05:06|2|16|64G|gpu:h100:2|node[01-02]|2026-11-25T08:00:00|2026-11-25T09:00:00|/scratch/bob/run dir
    999||leading trailing||PENDING|cpu_p|def-bob|0:00|UNLIMITED|1|4|None|N/A|(Resources)|2026-11-25T10:00:00|(null)|
    @@START
    999|2026-11-25T20:00:00
    @@ENDED
    888|sweep | β 🚀|1|TIMEOUT|0:0|2026-11-25T11:00:00|1-00:00:00
    @@DONE
    """
    let s = try SlurmQuery.parse(out, clusterID: UUID(), fetchedAt: Date())
    #expect(s.active.count == 2)

    let first = s.active[0]
    #expect(first.id == "123+0")
    #expect(first.name == "eval αβγ | stage 2 🚀 | v1")
    #expect(first.state == .running)
    #expect(first.partition == "gpu_p")
    #expect(first.account == "def-bob")
    #expect(first.elapsed == 3723)
    #expect(first.timeLimit == 14706)
    #expect(first.nodes == 2)
    #expect(first.cpus == 16)
    #expect(first.memory == "64G")
    #expect(first.gpus == 2)
    #expect(first.reasonOrNodes == "node[01-02]")
    #expect(first.submitTime == SlurmTime.date("2026-11-25T08:00:00"))
    #expect(first.startTime == SlurmTime.date("2026-11-25T09:00:00"))
    #expect(first.workDir == "/scratch/bob/run dir")

    let second = s.active[1]
    #expect(second.id == "999")
    #expect(second.name == "|leading trailing|")
    #expect(second.state == .pending)
    #expect(second.timeLimit == nil)
    #expect(second.memory == nil)
    #expect(second.gpus == nil)
    #expect(second.startTime == nil)
    #expect(second.workDir == nil)
    #expect(second.estimatedStart == SlurmTime.date("2026-11-25T20:00:00"))

    #expect(s.ended.count == 1)
    #expect(s.ended[0].id == "888")
    #expect(s.ended[0].name == "sweep | β 🚀|1")
    #expect(s.ended[0].state == .timeout)
    #expect(s.ended[0].exitCode == "0:0")
    #expect(s.ended[0].endTime == SlurmTime.date("2026-11-25T11:00:00"))
    #expect(s.ended[0].elapsed == 86400)
}

@Test func emptyClusterIsValid() throws {
    let id = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let s = try SlurmQuery.parse("@@ACTIVE\n@@START\n@@ENDED\n@@DONE\n", clusterID: id, fetchedAt: now)
    #expect(s.clusterID == id)
    #expect(s.fetchedAt == now)
    #expect(s.active.isEmpty && s.ended.isEmpty)
}

@Test func squeueFailure() {
    #expect(throws: SlurmQueryError.commandFailed("@@ERR squeue 127")) {
        try SlurmQuery.parse("@@ACTIVE\n@@ERR squeue 127\n@@START\n@@ENDED\n@@DONE\n", clusterID: UUID(), fetchedAt: Date())
    }
    #expect(throws: SlurmQueryError.commandFailed("@@ERR squeue 1")) {
        try SlurmQuery.parse("@@ACTIVE\n@@ERR squeue 1\n@@START\n@@ENDED\n@@DONE\n", clusterID: UUID(), fetchedAt: Date())
    }
}

@Test func truncatedOutputIsMalformed() {
    #expect(throws: SlurmQueryError.malformed) {
        try SlurmQuery.parse("@@ACTIVE\n", clusterID: UUID(), fetchedAt: Date())
    }
    #expect(throws: SlurmQueryError.malformed) {
        try SlurmQuery.parse("", clusterID: UUID(), fetchedAt: Date())
    }
    #expect(throws: SlurmQueryError.malformed) {
        try SlurmQuery.parse("@@ACTIVE\n@@START\n@@ENDED\n", clusterID: UUID(), fetchedAt: Date())
    }
}

@Test func ignoresLoginPreambleBeforeActiveMarker() throws {
    let out = """
    Welcome to Alliance Canada!
    Loading modules...
    @@ACTIVE
    @@START
    @@ENDED
    @@DONE
    """
    let s = try SlurmQuery.parse(out, clusterID: UUID(), fetchedAt: Date())
    #expect(s.active.isEmpty && s.ended.isEmpty)
}

@Test func remoteScriptContainsExactCommands() {
    let expected = #"""
    echo '@@ACTIVE'
    squeue -u "$USER" -h -o '%i|%j|%T|%P|%a|%M|%l|%D|%C|%m|%b|%R|%V|%S|%Z' || echo "@@ERR squeue $?"
    echo '@@START'
    squeue -u "$USER" -h -t PD --start -o '%i|%S' 2>/dev/null || true
    echo '@@ENDED'
    sacct -u "$USER" -X -n -P -S now-7days -o JobID,JobName,State,ExitCode,End,Elapsed 2>/dev/null || true
    echo '@@DONE'
    """#
    #expect(SlurmQuery.remoteScript == expected)
}

@Test func snapshotCodableRoundTrip() throws {
    let id = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let active = ActiveJob(
        id: "100",
        name: "manual",
        state: .running,
        partition: "gpu",
        account: "def-user",
        elapsed: 60,
        timeLimit: 3600,
        nodes: 1,
        cpus: 8,
        memory: "32G",
        gpus: 1,
        reasonOrNodes: "node01"
    )
    let ended = EndedJob(id: "99", name: "prev", state: .completed, exitCode: "0:0", endTime: now, elapsed: 120)
    let manualSnapshot = ClusterSnapshot(clusterID: id, fetchedAt: now, active: [active], ended: [ended])
    let parsedSnapshot = try SlurmQuery.parse(fullSampleOutput, clusterID: id, fetchedAt: now)

    for snapshot in [manualSnapshot, parsedSnapshot] {
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ClusterSnapshot.self, from: encoded)
        #expect(decoded == snapshot)
    }
}

@Test func parsesCRLFLineEndings() throws {
    let crlf = "@@ACTIVE\r\n101|crlf_job|RUNNING|p|a|00:10|01:00|1|2|4G|N/A|n1|2026-11-25T10:00:00|2026-11-25T10:01:00|/tmp\r\n@@START\r\n@@ENDED\r\n@@DONE\r\n"
    let s = try SlurmQuery.parse(crlf, clusterID: UUID(), fetchedAt: Date())
    #expect(s.active.count == 1)
    #expect(s.active[0].id == "101" && s.active[0].workDir == "/tmp")
}
