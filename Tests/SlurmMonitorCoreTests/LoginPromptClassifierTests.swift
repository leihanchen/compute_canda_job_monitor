import Foundation
import Testing
@testable import SlurmMonitorCore

@Suite struct LoginPromptClassifierTests {
    @Test func duoMenu() {
        let t = "Duo two-factor login for leihan\n\nEnter a passcode or select one of the following options:\n\n 1. Duo Push to iPhone (iOS)\n 2. Phone call\n\nPasscode or option (1-2): "
        #expect(
            LoginPromptClassifier.classify(t) == .mfa(options: [
                .init(number: 1, label: "Duo Push to iPhone (iOS)"),
                .init(number: 2, label: "Phone call"),
            ])
        )
    }

    @Test func hostKeyAndPassword() {
        #expect(
            LoginPromptClassifier.classify(
                "ED25519 key fingerprint is SHA256:abc123.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? "
            ) == .hostKey(fingerprint: "SHA256:abc123")
        )
        #expect(
            LoginPromptClassifier.classify("leihan@nibi.alliancecan.ca's password: ") == .password
        )
        #expect(
            LoginPromptClassifier.classify("Enter passphrase for key '/Users/a/.ssh/id_ed25519': ") == .passphrase
        )
    }

    @Test func normalizesPTYLineEndingsAndANSIEscapes() {
        let duoWithCRLFAndANSI =
            "\u{1B}[0mDuo two-factor login for leihan\r\n\r\n" +
            "Enter a passcode or select one of the following options:\r\n\r\n" +
            "  1. Duo Push to iPhone\r\n" +
            "  2. SMS passcodes\r\n" +
            "  3. YubiKey passcode\r\n\r\n" +
            "\u{1B}[1mPasscode or option (1-3):\u{1B}[0m "
        #expect(
            LoginPromptClassifier.classify(duoWithCRLFAndANSI) == .mfa(options: [
                .init(number: 1, label: "Duo Push to iPhone"),
                .init(number: 2, label: "SMS passcodes"),
                .init(number: 3, label: "YubiKey passcode"),
            ])
        )

        let hostKeyWithCRLF =
            "The authenticity of host 'nibi.alliancecan.ca' can't be established.\r\n" +
            "ED25519 key fingerprint is SHA256:ab+cd/ef12=.\r\n" +
            "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
        #expect(
            LoginPromptClassifier.classify(hostKeyWithCRLF) == .hostKey(fingerprint: "SHA256:ab+cd/ef12=")
        )
    }

    @Test func passwordMatchingAndNonMatches() {
        #expect(LoginPromptClassifier.classify("Password: ") == .password)
        #expect(
            LoginPromptClassifier.classify("Permission denied, please try again.\r\nleihan@fir.alliancecan.ca's PASSWORD:\r\n") == .password
        )
        #expect(LoginPromptClassifier.classify("Permission denied (publickey,password).") == nil)
        #expect(LoginPromptClassifier.classify("Duo two-factor login for leihan\r\n 1. Duo Push\r\n") == nil)
        #expect(LoginPromptClassifier.classify("") == nil)
    }

    @Test func mfaWithoutNumberedOptions() {
        #expect(LoginPromptClassifier.classify("Passcode or option: ") == .mfa(options: []))
    }

    @Test func deniedClassifications() {
        #expect(
            LoginPromptClassifier.classify("leihan@trillium.alliancecan.ca: Permission denied (publickey).\r\n")
                == .denied(.needsSSHKey)
        )
        #expect(
            LoginPromptClassifier.classify("Permission denied (publickey,keyboard-interactive).\r\n") == nil
        )
        #expect(
            LoginPromptClassifier.classify("Duo push failed.\r\nLogin timed out\r\n")
                == .denied(.mfaFailed)
        )
        #expect(
            LoginPromptClassifier.classify("Access denied\r\n")
                == .denied(.mfaFailed)
        )
    }

    @Test func mfaIgnoresNumberedPreAuthBannerLines() {
        let bannerPlusDuo =
            "Authorized users only. Notice:\r\n" +
            " 1. Activity on this system may be monitored.\r\n" +
            " 2. Do not share credentials.\r\n\r\n" +
            "Duo two-factor login for leihan\r\n\r\n" +
            "Enter a passcode or select one of the following options:\r\n\r\n" +
            " 1. Duo Push to iPhone\r\n" +
            " 2. Phone call\r\n\r\n" +
            "Passcode or option (1-2): "
        #expect(
            LoginPromptClassifier.classify(bannerPlusDuo) == .mfa(options: [
                .init(number: 1, label: "Duo Push to iPhone"),
                .init(number: 2, label: "Phone call"),
            ])
        )
    }
}
