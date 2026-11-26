import Foundation

/// Transport that reuses an existing OpenSSH `ControlMaster` socket via the app-generated SSH config.
public struct SharedSSHTransport: ClusterTransport {
    private static let sshExecutable = "/usr/bin/ssh"
    private static let controlTimeout: TimeInterval = 5

    public let kind: ConnectionMethodKind = .sharedSSH
    public let alias: String
    public let configPath: String
    public let runner: CommandRunner

    public init(
        alias: String,
        configPath: String,
        runner: CommandRunner = ProcessCommandRunner()
    ) {
        self.alias = alias
        self.configPath = configPath
        self.runner = runner
    }

    /// Checks whether an authenticated `ControlMaster` socket is currently alive for `alias`.
    public func probe() async -> TransportState {
        let result = await runner.run(
            Self.sshExecutable,
            ["-F", configPath, "-O", "check", alias],
            stdin: nil,
            timeout: Self.controlTimeout
        )
        if !result.timedOut && result.exitCode == 0 {
            return .usable
        }
        return .unavailable(.needsLogin)
    }

    /// Executes `script` non-interactively over the shared connection using `bash -l -s`.
    public func run(_ script: String, timeout: TimeInterval) async throws -> String {
        let result = await runner.run(
            Self.sshExecutable,
            ["-F", configPath, "-o", "BatchMode=yes", "-o", "ControlMaster=no", alias, "bash", "-l", "-s"],
            stdin: script,
            timeout: timeout
        )
        if !result.timedOut && result.exitCode == 0 {
            return result.stdout
        }
        throw ClusterErrorClassifier.classify(result)
    }

    /// Frees a stale master socket with `-O stop` (never `-O exit`, preserving existing Terminal sessions).
    public func stopStaleMaster() async {
        _ = await runner.run(
            Self.sshExecutable,
            ["-F", configPath, "-O", "stop", alias],
            stdin: nil,
            timeout: Self.controlTimeout
        )
    }
}
