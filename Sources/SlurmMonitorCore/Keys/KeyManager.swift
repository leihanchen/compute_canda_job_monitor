import Foundation

/// Errors thrown by `KeyManager` operations.
public enum KeyManagerError: Error, Sendable, Equatable, LocalizedError {
    case keyAlreadyExists(String)
    case generationFailed(exitCode: Int32, timedOut: Bool, message: String)

    public var errorDescription: String? {
        switch self {
        case .keyAlreadyExists(let path):
            return "SSH key file already exists at \(path)."
        case .generationFailed(let exitCode, let timedOut, let message):
            if timedOut {
                return "ssh-keygen timed out."
            }
            if message.isEmpty {
                return "ssh-keygen failed with exit code \(exitCode)."
            }
            return "ssh-keygen failed with exit code \(exitCode): \(message)"
        }
    }
}

/// Discovers, inspects, and generates SSH key pairs without modifying user configuration.
public enum KeyManager: Sendable {
    public static let candidateNames = ["id_ed25519", "id_ecdsa", "id_rsa"]

    private static let sshAddTimeout: TimeInterval = 5
    private static let sshKeygenTimeout: TimeInterval = 10

    /// Returns private-key URLs in `candidateNames` order where both `<name>` and `<name>.pub` exist as files.
    public static func existingKeys(sshDir: URL) -> [URL] {
        candidateNames.compactMap { name in
            let privateURL = sshDir.appendingPathComponent(name)
            let publicURL = URL(fileURLWithPath: privateURL.path + ".pub")
            guard isRegularFile(privateURL), isRegularFile(publicURL) else {
                return nil
            }
            return privateURL
        }
    }

    /// Returns `true` when the running SSH agent currently holds at least one loaded identity.
    public static func agentHasKeys(runner: CommandRunner) async -> Bool {
        let result = await runner.run(
            "/usr/bin/ssh-add",
            ["-l"],
            stdin: nil,
            timeout: sshAddTimeout
        )
        return !result.timedOut && result.exitCode == 0
    }

    /// Generates an Ed25519 SSH key pair at `at` and returns the trimmed contents of `<at>.pub`.
    public static func generate(
        at keyURL: URL,
        passphrase: String,
        runner: CommandRunner
    ) async throws -> String {
        let fileManager = FileManager.default
        let pubURL = URL(fileURLWithPath: keyURL.path + ".pub")

        if fileManager.fileExists(atPath: keyURL.path) {
            throw KeyManagerError.keyAlreadyExists(keyURL.path)
        }
        if fileManager.fileExists(atPath: pubURL.path) {
            throw KeyManagerError.keyAlreadyExists(pubURL.path)
        }

        let parentDir = keyURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let result = await runner.run(
            "/usr/bin/ssh-keygen",
            ["-t", "ed25519", "-f", keyURL.path, "-N", passphrase, "-C", "slurm-monitor"],
            stdin: nil,
            timeout: sshKeygenTimeout
        )

        guard !result.timedOut, result.exitCode == 0 else {
            throw KeyManagerError.generationFailed(
                exitCode: result.exitCode,
                timedOut: result.timedOut,
                message: sanitizeErrorOutput(result.stderr, passphrase: passphrase)
            )
        }

        let publicKey = try String(contentsOf: pubURL, encoding: .utf8)
        return publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    private static func sanitizeErrorOutput(_ stderr: String, passphrase: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !passphrase.isEmpty else { return trimmed }
        return trimmed.replacingOccurrences(of: passphrase, with: "<redacted>")
    }
}
