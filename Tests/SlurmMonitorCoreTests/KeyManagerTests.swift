import Foundation
import Testing
import SlurmMonitorCore

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("KeyManagerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func findsKeyPairsOnly() throws {
    let dir = try makeTempDir()
    let missingDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("KeyManagerMissing-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: missingDir)
    }

    try "k".write(to: dir.appendingPathComponent("id_ed25519"), atomically: true, encoding: .utf8)
    try "p".write(to: dir.appendingPathComponent("id_ed25519.pub"), atomically: true, encoding: .utf8)
    try "k".write(to: dir.appendingPathComponent("id_rsa"), atomically: true, encoding: .utf8)

    #expect(KeyManager.existingKeys(sshDir: dir).map(\.lastPathComponent) == ["id_ed25519"])
    #expect(KeyManager.existingKeys(sshDir: missingDir).isEmpty)
}

@Test func existingKeysRespectsCandidateOrderAndIgnoresDirectories() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(KeyManager.candidateNames == ["id_ed25519", "id_ecdsa", "id_rsa"])

    // Create in reverse order plus an unlisted key and a directory masquerading as a key.
    try "k".write(to: dir.appendingPathComponent("id_rsa"), atomically: true, encoding: .utf8)
    try "p".write(to: dir.appendingPathComponent("id_rsa.pub"), atomically: true, encoding: .utf8)
    try "k".write(to: dir.appendingPathComponent("id_ecdsa"), atomically: true, encoding: .utf8)
    try "p".write(to: dir.appendingPathComponent("id_ecdsa.pub"), atomically: true, encoding: .utf8)
    try "k".write(to: dir.appendingPathComponent("id_custom"), atomically: true, encoding: .utf8)
    try "p".write(to: dir.appendingPathComponent("id_custom.pub"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("id_ed25519"),
        withIntermediateDirectories: true
    )
    try "p".write(to: dir.appendingPathComponent("id_ed25519.pub"), atomically: true, encoding: .utf8)

    #expect(KeyManager.existingKeys(sshDir: dir).map(\.lastPathComponent) == ["id_ecdsa", "id_rsa"])

    // Also reject when .pub is a directory.
    let ecdsaPub = dir.appendingPathComponent("id_ecdsa.pub")
    try FileManager.default.removeItem(at: ecdsaPub)
    try FileManager.default.createDirectory(at: ecdsaPub, withIntermediateDirectories: true)

    #expect(KeyManager.existingKeys(sshDir: dir).map(\.lastPathComponent) == ["id_rsa"])
}

@Test func agentHasKeysChecksSSHAddExitCodeAndTimeout() async {
    let successRunner = FakeRunner(
        default: CommandResult(exitCode: 0, stdout: "256 SHA256:abc user@host (ED25519)\n", stderr: "", timedOut: false)
    )
    #expect(await KeyManager.agentHasKeys(runner: successRunner))
    #expect(successRunner.calls.count == 1)
    #expect(successRunner.calls[0].executable == "/usr/bin/ssh-add")
    #expect(successRunner.calls[0].args == ["-l"])
    #expect(successRunner.calls[0].stdin == nil)
    #expect(successRunner.timeouts[0] > 0 && successRunner.timeouts[0] <= 10)

    let emptyAgentRunner = FakeRunner(
        default: CommandResult(exitCode: 1, stdout: "", stderr: "The agent has no identities.", timedOut: false)
    )
    #expect(!(await KeyManager.agentHasKeys(runner: emptyAgentRunner)))

    let timedOutRunner = FakeRunner(
        default: CommandResult(exitCode: 0, stdout: "", stderr: "", timedOut: true)
    )
    #expect(!(await KeyManager.agentHasKeys(runner: timedOutRunner)))
}

@Test func generateRefusesWhenPrivateOrPublicKeyAlreadyExists() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let privateOnly = dir.appendingPathComponent("id_ed25519")
    try "existing-private".write(to: privateOnly, atomically: true, encoding: .utf8)

    let runner1 = FakeRunner()
    do {
        _ = try await KeyManager.generate(at: privateOnly, passphrase: "secret", runner: runner1)
        Issue.record("Expected error when private key already exists")
    } catch let error as KeyManagerError {
        #expect(error == .keyAlreadyExists(privateOnly.path))
    }
    #expect(runner1.calls.isEmpty)

    let pubOnlyKey = dir.appendingPathComponent("id_other")
    let pubOnlyPub = dir.appendingPathComponent("id_other.pub")
    try "existing-pub".write(to: pubOnlyPub, atomically: true, encoding: .utf8)

    let runner2 = FakeRunner()
    do {
        _ = try await KeyManager.generate(at: pubOnlyKey, passphrase: "secret", runner: runner2)
        Issue.record("Expected error when public key already exists")
    } catch let error as KeyManagerError {
        #expect(error == .keyAlreadyExists(pubOnlyPub.path))
    }
    #expect(runner2.calls.isEmpty)
}

@Test func generateCreatesParentDir0700AndDoesNotLeakPassphraseOnFailure() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let parentDir = root.appendingPathComponent("ssh_dir", isDirectory: true)
    let keyPath = parentDir.appendingPathComponent("id_ed25519")
    let secret = "super-secret-passphrase-123!"

    let failingRunner = FakeRunner(
        default: CommandResult(
            exitCode: 1,
            stdout: "",
            stderr: "ssh-keygen failed near \(secret)",
            timedOut: false
        )
    )

    do {
        _ = try await KeyManager.generate(at: keyPath, passphrase: secret, runner: failingRunner)
        Issue.record("Expected KeyManager.generate to throw on non-zero exit")
    } catch {
        let description = "\(error) \(error.localizedDescription)"
        #expect(!description.contains(secret))
    }

    #expect(failingRunner.calls.count == 1)
    #expect(failingRunner.calls[0].executable == "/usr/bin/ssh-keygen")
    #expect(failingRunner.calls[0].args == ["-t", "ed25519", "-f", keyPath.path, "-N", secret, "-C", "slurm-monitor"])
    #expect(failingRunner.calls[0].stdin == nil)

    let attrs = try FileManager.default.attributesOfItem(atPath: parentDir.path)
    let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
    #expect(perms == 0o700)

    let timeoutRunner = FakeRunner(
        default: CommandResult(exitCode: 0, stdout: "", stderr: "", timedOut: true)
    )
    let secondKey = parentDir.appendingPathComponent("id_timeout")
    await #expect(throws: KeyManagerError.self) {
        _ = try await KeyManager.generate(at: secondKey, passphrase: secret, runner: timeoutRunner)
    }
}

@Test func generatesRealKey() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let path = dir.appendingPathComponent("id_ed25519")
    let pub = try await KeyManager.generate(at: path, passphrase: "", runner: ProcessCommandRunner())
    #expect(pub.hasPrefix("ssh-ed25519 ") && pub.contains("slurm-monitor"))
    #expect(KeyManager.existingKeys(sshDir: dir) == [path])
}
