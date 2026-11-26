import Darwin
import Foundation

/// Renders and persists the app-managed SSH configuration (`~/.slurm-monitor/ssh_config`).
public enum GeneratedSSHConfig {
    /// Lowercase `ssh -G` option keys copied into each generated `Host` block, in output order.
    public static let copiedKeys: [String] = [
        "hostname",
        "user",
        "port",
        "identityfile",
        "identitiesonly",
        "identityagent",
        "proxyjump",
        "proxycommand",
        "hostkeyalias",
        "userknownhostsfile",
        "addkeystoagent",
    ]

    /// Renders a single `Host <generatedAlias>` SSH config block from resolved `ssh -G` options.
    public static func block(
        for cluster: ClusterConfig,
        sshG: [String: [String]],
        controlPath: String
    ) -> String {
        var lines = ["Host \(cluster.generatedAlias)"]

        for key in copiedKeys {
            switch key {
            case "identityfile":
                appendIdentityFiles(cluster: cluster, sshG: sshG, to: &lines)
            case "identityagent":
                appendValues(sshG["identityagent"], key: "identityagent", fallback: nil, quoteWhitespace: true, to: &lines)
            case "hostname":
                appendValues(sshG["hostname"], key: "hostname", fallback: cluster.host, to: &lines)
            case "user":
                appendValues(sshG["user"], key: "user", fallback: cluster.username, to: &lines)
            default:
                appendValues(sshG[key], key: key, fallback: nil, to: &lines)
            }
        }

        lines.append("  ControlPath \"\(controlPath)\"")
        lines.append("  ControlPersist yes")
        lines.append("  ServerAliveInterval 30")
        lines.append("  ServerAliveCountMax 20")
        lines.append("  ConnectTimeout 10")
        lines.append("  IgnoreUnknown UseKeychain")
        lines.append("  UseKeychain yes")

        return lines.joined(separator: "\n") + "\n"
    }

    /// Joins `blocks` and writes the SSH config atomically with `0600` file permissions
    /// inside a `0700` parent directory.
    public static func write(blocks: [String], to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let dirExisted = FileManager.default.fileExists(atPath: dir.path)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !dirExisted || dir.lastPathComponent == ".slurm-monitor" {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }

        let normalized = blocks
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
        let content = normalized.isEmpty ? "" : normalized.joined(separator: "\n\n") + "\n"
        let data = Data(content.utf8)

        let tmpURL = dir.appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: tmpURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var renamed = false
        defer {
            if !renamed {
                try? FileManager.default.removeItem(at: tmpURL)
            }
        }

        let handle = try FileHandle(forWritingTo: tmpURL)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpURL.path)
        if Darwin.rename(tmpURL.path, url.path) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        renamed = true
    }

    private static func appendValues(
        _ values: [String]?,
        key: String,
        fallback: String?,
        quoteWhitespace: Bool = false,
        to lines: inout [String]
    ) {
        let valid = (values ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased() != "none" }

        if valid.isEmpty {
            if let fallback = fallback?.trimmingCharacters(in: .whitespaces), !fallback.isEmpty {
                let formatted = quoteWhitespace ? quoteIfNeeded(fallback) : fallback
                lines.append("  \(key) \(formatted)")
            }
            return
        }

        for value in valid {
            let formatted = quoteWhitespace ? quoteIfNeeded(value) : value
            lines.append("  \(key) \(formatted)")
        }
    }

    private static func appendIdentityFiles(
        cluster: ClusterConfig,
        sshG: [String: [String]],
        to lines: inout [String]
    ) {
        var candidates: [String] = []
        if let clusterKey = cluster.identityFile {
            candidates.append(clusterKey)
        }
        if let sshGKeys = sshG["identityfile"] {
            candidates.append(contentsOf: sshGKeys)
        }

        var seenCanonicalPaths = Set<String>()
        for raw in candidates {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { continue }

            let expanded = ControlPathResolver.expandTilde(trimmed)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }

            let canonical = URL(fileURLWithPath: expanded).standardizedFileURL.path
            guard seenCanonicalPaths.insert(canonical).inserted else { continue }

            lines.append("  identityfile \(quoteIfNeeded(trimmed))")
        }
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        if value.contains(where: \.isWhitespace) && !(value.hasPrefix("\"") && value.hasSuffix("\"")) {
            return "\"\(value)\""
        }
        return value
    }
}
