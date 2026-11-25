import Foundation
import Testing
@testable import SlurmMonitorCore

private let userCfg = """
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

@Test func templateRulesRespectGlobalFirstMatchGlobbingNegationAndInclude() {
    let globalCfg = """
    ControlPath ~/.ssh/global-%C
    Host nibi
      ControlPath ~/.ssh/local-%C
    """
    #expect(ControlPathResolver.userTemplate(configText: globalCfg, alias: "nibi", hostName: "nibi.alliancecan.ca") == "~/.ssh/global-%C")

    let hostGlobCfg = """
    Include ~/.ssh/other_config
    Host *.alliancecan.ca,!login*.alliancecan.ca web-?
      ControlPath=~/.ssh/glob-%C
    Host other
      ControlPath none
    Host *
      ControlPath ~/.ssh/fallback-%C
    """
    #expect(ControlPathResolver.userTemplate(configText: hostGlobCfg, alias: "nibi", hostName: "nibi.alliancecan.ca") == "~/.ssh/glob-%C")
    #expect(ControlPathResolver.userTemplate(configText: hostGlobCfg, alias: "login1", hostName: "login1.alliancecan.ca") == "~/.ssh/fallback-%C")
    #expect(ControlPathResolver.userTemplate(configText: hostGlobCfg, alias: "web-1", hostName: "web-1.example.org") == "~/.ssh/glob-%C")
    #expect(ControlPathResolver.userTemplate(configText: hostGlobCfg, alias: "web-12", hostName: "web-12.example.org") == "~/.ssh/fallback-%C")
    #expect(ControlPathResolver.userTemplate(configText: hostGlobCfg, alias: "other", hostName: "other") == nil)

    let matchCfg = """
    Match user alice exec "echo host *.wrong"
      ControlPath ~/.ssh/no-host-criteria-%C
    """
    #expect(ControlPathResolver.userTemplate(configText: matchCfg, alias: nil, hostName: "any.example.org") == "~/.ssh/no-host-criteria-%C")

    let origHostCfg = """
    Match canonical originalhost=my-*
      ControlPath "~/.ssh/orig space/%C"
    """
    #expect(ControlPathResolver.userTemplate(configText: origHostCfg, alias: "my-cluster", hostName: "c.example.org") == "~/.ssh/orig space/%C")
    #expect(ControlPathResolver.userTemplate(configText: origHostCfg, alias: "other-cluster", hostName: "c.example.org") == nil)
}

@Test func resolveUsesSshG() async {
    let runner = FakeRunner(
        default: CommandResult(
            exitCode: 0,
            stdout: "user leihan\nhostname nibi.alliancecan.ca\nport 22\ncontrolpath /Users/mac/.ssh/cmfa-a906e9a034ed7acf37581f12c4cae7cd3733ae47\n",
            stderr: "",
            timedOut: false
        )
    )
    let c = ClusterConfig(name: "nibi", host: "nibi.alliancecan.ca", username: "leihan", sshAlias: "nibi")
    let r = await ControlPathResolver.resolve(cluster: c, userConfigText: userCfg, appTemplate: "~/.slurm-monitor/cm-%C", runner: runner)
    #expect(r.controlPath == "/Users/mac/.ssh/cmfa-a906e9a034ed7acf37581f12c4cae7cd3733ae47")
    #expect(runner.calls.count == 1)
    #expect(runner.calls[0].executable == "/usr/bin/ssh")
    #expect(runner.calls[0].args == ["-G", "-o", "ControlPath=~/.ssh/cmfa-%C", "nibi"])
    #expect(r.sshG["user"] == ["leihan"])
    #expect(r.sshG["port"] == ["22"])
}

@Test func resolveFallsBackToExpandedTemplateOnFailure() async {
    let runner = FakeRunner(
        default: CommandResult(
            exitCode: 255,
            stdout: "",
            stderr: "ssh error",
            timedOut: false
        )
    )
    let c = ClusterConfig(name: "fir", host: "fir.alliancecan.ca", username: "leihan")
    let r = await ControlPathResolver.resolve(
        cluster: c,
        userConfigText: "",
        appTemplate: "~/.slurm-monitor/cm-%C",
        runner: runner
    )
    let expectedPath = NSString(string: "~/.slurm-monitor/cm-%C").expandingTildeInPath
    #expect(ControlPathResolver.expandTilde("~/.slurm-monitor/cm-%C") == expectedPath)
    #expect(ControlPathResolver.expandTilde("/tmp/cm-%C") == "/tmp/cm-%C")
    #expect(r.controlPath == expectedPath)
    #expect(r.sshG.isEmpty)
    #expect(runner.calls[0].args == ["-G", "-o", "ControlPath=~/.slurm-monitor/cm-%C", "leihan@fir.alliancecan.ca"])
}

@Test func sshGOutputParsesLowercaseAndOrder() {
    let text = """
    User leihan
    HostName nibi.alliancecan.ca
    IdentityFile ~/.ssh/id_ed25519
    IdentityFile ~/.ssh/id_rsa
    ProxyCommand ssh -W %h:%p bastion

    """
    let parsed = SSHGOutput.parse(text)
    #expect(parsed["user"] == ["leihan"])
    #expect(parsed["hostname"] == ["nibi.alliancecan.ca"])
    #expect(parsed["identityfile"] == ["~/.ssh/id_ed25519", "~/.ssh/id_rsa"])
    #expect(parsed["proxycommand"] == ["ssh -W %h:%p bastion"])
}

@Test func processRunnerOutputAndTimeout() async {
    let ok = await ProcessCommandRunner().run("/bin/echo", ["hi"], stdin: nil, timeout: 2)
    #expect(ok.stdout == "hi\n" && ok.exitCode == 0 && !ok.timedOut)
    let slow = await ProcessCommandRunner().run("/bin/sleep", ["5"], stdin: nil, timeout: 0.5)
    #expect(slow.timedOut && slow.exitCode == -1)

    let err = await ProcessCommandRunner().run("/bin/sh", ["-c", "echo oops >&2; exit 42"], stdin: nil, timeout: 2)
    #expect(err.exitCode == 42 && !err.timedOut && err.stderr == "oops\n")

    let missing = await ProcessCommandRunner().run("/nonexistent/smon/binary", [], stdin: nil, timeout: 2)
    #expect(missing.exitCode == -1 && !missing.timedOut && !missing.stderr.isEmpty)
}

@Test func processRunnerLargePipesAndStdin() async {
    let runner = ProcessCommandRunner()
    let echoed = await runner.run("/bin/cat", [], stdin: "hello\nworld\n", timeout: 2)
    #expect(echoed.exitCode == 0 && !echoed.timedOut && echoed.stdout == "hello\nworld\n")

    // Child that exits immediately without reading stdin should not trigger SIGPIPE crash
    let payload = String(repeating: "x", count: 131_072)
    let quickExit = await runner.run("/usr/bin/true", [], stdin: payload, timeout: 2)
    #expect(quickExit.exitCode == 0 && !quickExit.timedOut)

    // Large simultaneous stdout and stderr (>128 KiB each) must not deadlock
    let bigScript = """
    python3 -c 'import sys; sys.stdout.write("A"*150000); sys.stderr.write("B"*150000)'
    """
    let big = await runner.run("/bin/sh", ["-c", bigScript], stdin: nil, timeout: 5)
    #expect(big.exitCode == 0 && !big.timedOut)
    #expect(big.stdout.count == 150_000)
    #expect(big.stderr.count == 150_000)
}
