import Foundation
import Testing
@testable import SlurmMonitorCore

@Test func generatedBlock() {
    let g = SSHGOutput.parse("hostname nibi.alliancecan.ca\nuser leihan\nport 22\nproxyjump none\ncontrolmaster false\n")
    let c = ClusterConfig(name: "nibi", host: "nibi.alliancecan.ca", username: "leihan")
    let b = GeneratedSSHConfig.block(for: c, sshG: g, controlPath: "/tmp/cm-x")
    #expect(b.hasPrefix("Host smon-nibi\n"))
    #expect(b.contains("  hostname nibi.alliancecan.ca") && b.contains("  ControlPath \"/tmp/cm-x\""))
    #expect(b.contains("  ServerAliveInterval 30") && b.contains("  ServerAliveCountMax 20") && b.contains("  ControlPersist yes"))
    #expect(b.contains("  ConnectTimeout 10"))
    #expect(b.contains("  IgnoreUnknown UseKeychain"))
    #expect(b.contains("  UseKeychain yes"))
    #expect(!b.contains("proxyjump") && !b.contains("controlmaster"))
}

@Test func generatedBlockCopiesAllowedKeysAndFiltersIdentityFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let existingKey1 = dir.appendingPathComponent("id_ed25519")
    let existingKey2 = dir.appendingPathComponent("id_ecdsa")
    let missingKey = dir.appendingPathComponent("id_missing")
    try Data("k1".utf8).write(to: existingKey1)
    try Data("k2".utf8).write(to: existingKey2)

    #expect(GeneratedSSHConfig.copiedKeys == [
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
    ])

    let sshGText = """
    hostname trillium-gpu.scinet.utoronto.ca
    user leihan
    port 2222
    identityfile ~/.ssh/definitely_nonexistent_smon_test_key_99999
    identityfile \(existingKey1.path)
    identityfile \(missingKey.path)
    identityfile \(existingKey2.path)
    identitiesonly yes
    identityagent /tmp/agent.sock
    proxyjump bastion.example.org
    proxycommand none
    hostkeyalias trillium-alias
    userknownhostsfile ~/.ssh/known_hosts
    addkeystoagent yes
    controlmaster auto
    """
    let g = SSHGOutput.parse(sshGText)
    let c = ClusterConfig(name: "trillium-gpu", host: "trillium-gpu.scinet.utoronto.ca", username: "leihan", requiresKey: true)
    let b = GeneratedSSHConfig.block(for: c, sshG: g, controlPath: "/tmp/cm-tri")

    #expect(b.contains("  hostname trillium-gpu.scinet.utoronto.ca"))
    #expect(b.contains("  user leihan"))
    #expect(b.contains("  port 2222"))
    #expect(b.contains("  identityfile \(existingKey1.path)"))
    #expect(b.contains("  identityfile \(existingKey2.path)"))
    #expect(!b.contains(missingKey.path))
    #expect(!b.contains("definitely_nonexistent_smon_test_key_99999"))
    #expect(b.contains("  identitiesonly yes"))
    #expect(b.contains("  identityagent /tmp/agent.sock"))
    #expect(b.contains("  proxyjump bastion.example.org"))
    #expect(!b.contains("proxycommand"))
    #expect(b.contains("  hostkeyalias trillium-alias"))
    #expect(b.contains("  userknownhostsfile ~/.ssh/known_hosts"))
    #expect(b.contains("  addkeystoagent yes"))
    #expect(!b.contains("controlmaster"))
}

@Test func generatedBlockHandlesClusterIdentityFileAndEmptySshGFallback() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let validKey = dir.appendingPathComponent("id_cluster")
    let brokenKey = dir.appendingPathComponent("id_broken")
    try Data("key".utf8).write(to: validKey)

    // Duplicate identityFile present in both cluster.identityFile and sshG should appear once
    let gWithDup = SSHGOutput.parse("hostname nibi.alliancecan.ca\nuser leihan\nidentityfile \(validKey.path)\n")
    let cWithValid = ClusterConfig(name: "nibi", host: "nibi.alliancecan.ca", username: "leihan", identityFile: validKey.path)
    let bDup = GeneratedSSHConfig.block(for: cWithValid, sshG: gWithDup, controlPath: "/tmp/cm-nibi")
    let linesDup = bDup.split(separator: "\n").filter { $0.contains("identityfile \(validKey.path)") }
    #expect(linesDup.count == 1)

    // Broken cluster.identityFile should not be emitted
    let cWithBroken = ClusterConfig(name: "nibi", host: "nibi.alliancecan.ca", username: "leihan", identityFile: brokenKey.path)
    let bBroken = GeneratedSSHConfig.block(for: cWithBroken, sshG: gWithDup, controlPath: "/tmp/cm-nibi")
    #expect(!bBroken.contains(brokenKey.path))
    #expect(bBroken.contains("  identityfile \(validKey.path)"))

    // Empty sshG (e.g. ssh -G failed) falls back to cluster host, user, and existing identityFile
    let bFallback = GeneratedSSHConfig.block(for: cWithValid, sshG: [:], controlPath: "/tmp/cm-nibi")
    #expect(bFallback.contains("  hostname nibi.alliancecan.ca"))
    #expect(bFallback.contains("  user leihan"))
    #expect(bFallback.contains("  identityfile \(validKey.path)"))
}

@Test func writeCreatesSecureDirectoryAndFileAtomically() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let smonDir = root.appendingPathComponent(".slurm-monitor")
    let fileURL = smonDir.appendingPathComponent("ssh_config")

    let block1 = "Host smon-a\n  hostname a.example.org\n"
    let block2 = "Host smon-b\n  hostname b.example.org\n"
    try GeneratedSSHConfig.write(blocks: [block1, block2], to: fileURL)

    let written = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(written.contains("Host smon-a"))
    #expect(written.contains("Host smon-b"))

    let dirAttrs = try FileManager.default.attributesOfItem(atPath: smonDir.path)
    let fileAttrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    #expect((dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect((fileAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    // Atomic overwrite preserves 0600 and replaces content
    try GeneratedSSHConfig.write(blocks: [block2], to: fileURL)
    let overwritten = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(!overwritten.contains("Host smon-a"))
    #expect(overwritten.contains("Host smon-b"))
    let fileAttrsAfter = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    #expect((fileAttrsAfter[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}
