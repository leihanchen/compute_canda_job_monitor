import Foundation
import Testing
@testable import SlurmMonitorCore

@Test func classifies() {
    func r(_ e: String, t: Bool = false) -> CommandResult {
        .init(exitCode: 255, stdout: "", stderr: e, timedOut: t)
    }

    #expect(ClusterErrorClassifier.classify(r("leihan@trillium: Permission denied (publickey).")) == .needsSSHKey)
    #expect(ClusterErrorClassifier.classify(r("Permission denied (publickey,keyboard-interactive).")) == .needsLogin)
    #expect(ClusterErrorClassifier.classify(r("ssh: Could not resolve hostname x")) == .unreachable)
    #expect(ClusterErrorClassifier.classify(r("", t: true)) == .unreachable)
}

@Test func classifiesPrecedenceAndAllErrorCategories() {
    func r(_ stderr: String, exitCode: Int32 = 255, timedOut: Bool = false) -> CommandResult {
        CommandResult(exitCode: exitCode, stdout: "", stderr: stderr, timedOut: timedOut)
    }

    // 1. Timeout takes precedence over everything in stderr
    #expect(ClusterErrorClassifier.classify(r("Permission denied (publickey).", timedOut: true)) == .unreachable)

    // 2. Publickey-only takes precedence over unreachable and login patterns
    #expect(ClusterErrorClassifier.classify(r("Permission denied (publickey). Connection refused")) == .needsSSHKey)
    #expect(ClusterErrorClassifier.classify(r("Permission denied (publickey,password).")) == .needsLogin)

    // 3. Unreachable network errors
    #expect(ClusterErrorClassifier.classify(r("ssh: connect to host x port 22: Connection refused")) == .unreachable)
    #expect(ClusterErrorClassifier.classify(r("ssh: connect to host x port 22: Operation timed out")) == .unreachable)
    #expect(ClusterErrorClassifier.classify(r("ssh: connect to host x port 22: No route to host")) == .unreachable)
    #expect(ClusterErrorClassifier.classify(r("ssh: connect to host x port 22: Network is unreachable")) == .unreachable)

    // 4. No access (case-insensitive)
    #expect(ClusterErrorClassifier.classify(r("User leihan is NOT ALLOWED on trillium")) == .noAccess)
    #expect(ClusterErrorClassifier.classify(r("Your ACCOUNT IS NOT enabled on this cluster")) == .noAccess)
    #expect(ClusterErrorClassifier.classify(r("access denied by administrator")) == .noAccess)
    #expect(ClusterErrorClassifier.classify(r("Access Denied")) == .noAccess)

    // 5. Login-required patterns and fallback
    #expect(ClusterErrorClassifier.classify(r("Control socket connect(/tmp/s): No such file or directory")) == .needsLogin)
    #expect(ClusterErrorClassifier.classify(r("unix_listener: No such file or directory")) == .needsLogin)
    #expect(ClusterErrorClassifier.classify(r("Permission denied, please try again.")) == .needsLogin)
    #expect(ClusterErrorClassifier.classify(r("Host key verification failed.")) == .needsLogin)
    #expect(ClusterErrorClassifier.classify(r("unexpected ssh diagnostic")) == .needsLogin)
    #expect(ClusterErrorClassifier.classify(r("")) == .needsLogin)
}

@Test func clusterErrorHintsAndCodable() throws {
    #expect(ClusterError.needsLogin.hint == "Log in to refresh")
    #expect(ClusterError.needsSSHKey.hint == "Upload an SSH key in CCDB")
    #expect(ClusterError.noAccess.hint == "Request access to this cluster in CCDB")
    #expect(ClusterError.unreachable.hint == "Cluster unreachable")
    #expect(ClusterError.mfaFailed.hint == "MFA was denied or timed out")
    #expect(ClusterError.slurmFailed("squeue 127").hint == "Slurm command failed")

    let allCases: [ClusterError] = [
        .needsLogin,
        .needsSSHKey,
        .noAccess,
        .unreachable,
        .mfaFailed,
        .slurmFailed("@@ERR squeue 1"),
    ]
    let encoded = try JSONEncoder().encode(allCases)
    let decoded = try JSONDecoder().decode([ClusterError].self, from: encoded)
    #expect(decoded == allCases)
}
