import Foundation
import Testing
@testable import SlurmMonitorCore

@Suite struct PTYProcessTests {
    @Test func ptyHasControllingTTY() async throws {
        let p = try PTYProcess(
            executable: "/bin/sh",
            args: ["-c", "printf 'Password: ' > /dev/tty; read x < /dev/tty; echo got:$x"]
        )
        var seen = ""
        for await chunk in p.output {
            seen += chunk
            if seen.contains("Password: ") {
                p.write("s3cret\n")
            }
            if seen.contains("got:s3cret") {
                break
            }
        }
        #expect(await p.waitForExit() == 0)
    }

    @Test func ptyDrainsOutputAndCapturesNonZeroExitCode() async throws {
        let p = try PTYProcess(
            executable: "/bin/sh",
            args: ["-c", "printf 'first\\nsecond\\n'; exit 42"]
        )
        var output = ""
        for await chunk in p.output {
            output += chunk
        }
        #expect(output.contains("first"))
        #expect(output.contains("second"))
        #expect(await p.waitForExit() == 42)
        #expect(await p.waitForExit() == 42)
    }

    @Test func ptyTerminateStopsRunningChild() async throws {
        let p = try PTYProcess(
            executable: "/bin/sh",
            args: ["-c", "printf 'ready\\n'; exec sleep 30"]
        )
        var seen = ""
        for await chunk in p.output {
            seen += chunk
            if seen.contains("ready") {
                p.terminate()
                break
            }
        }
        let code = await p.waitForExit()
        #expect(code != 0)
    }

    @Test func ptyMissingExecutableThrows() {
        #expect(throws: Error.self) {
            _ = try PTYProcess(
                executable: "/nonexistent/path/slurm_monitor_missing_binary",
                args: []
            )
        }
    }

    @Test func loginSessionMockSuccessFlowOmitsEchoedSecret() async throws {
        let scriptURL = try writeMockSSHScript(
            body: """
            #!/bin/sh
            set -eu
            if [ "$*" != "-F /tmp/test_ssh_config -o ControlMaster=yes -o ControlPersist=yes -N -f smon-nibi" ]; then
                printf 'unexpected args: %s\n' "$*" > /dev/tty
                exit 99
            fi
            printf 'ED25519 key fingerprint is SHA256:mockfp123.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ' > /dev/tty
            IFS= read -r host_answer < /dev/tty
            if [ "$host_answer" != "yes" ]; then
                exit 91
            fi
            stty -f /dev/tty -echo
            printf "leihan@nibi.alliancecan.ca's password: " > /dev/tty
            IFS= read -r pw_answer < /dev/tty
            stty -f /dev/tty echo
            printf '\n' > /dev/tty
            if [ "$pw_answer" != "hunter2" ]; then
                exit 92
            fi
            printf 'Duo two-factor login for leihan\n\nEnter a passcode or select one of the following options:\n\n 1. Duo Push to iPhone\n 2. Phone call\n\nPasscode or option (1-2): ' > /dev/tty
            IFS= read -r mfa_answer < /dev/tty
            if [ "$mfa_answer" != "1" ]; then
                exit 93
            fi
            printf 'Success. Logging you in...\n' > /dev/tty
            exit 0
            """
        )
        defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

        let session = LoginSession(
            alias: "smon-nibi",
            configPath: "/tmp/test_ssh_config",
            executable: scriptURL.path
        )
        try session.start()

        var prompts: [LoginPrompt] = []
        var transcript = ""
        var terminalEvents: [LoginEvent] = []

        for await event in session.events {
            switch event {
            case .transcript(let chunk):
                transcript += chunk
            case .prompt(let prompt):
                prompts.append(prompt)
                switch prompt {
                case .hostKey:
                    session.answer("yes")
                case .password:
                    session.answer("hunter2")
                case .mfa:
                    session.answer("1")
                case .passphrase, .denied:
                    break
                }
            case .succeeded, .failed:
                terminalEvents.append(event)
            }
        }

        #expect(prompts == [
            .hostKey(fingerprint: "SHA256:mockfp123"),
            .password,
            .mfa(options: [
                .init(number: 1, label: "Duo Push to iPhone"),
                .init(number: 2, label: "Phone call"),
            ]),
        ])
        #expect(terminalEvents == [.succeeded])
        #expect(!transcript.contains("hunter2"))
    }

    @Test func loginSessionMockFailureClassifications() async throws {
        let keyDeniedScript = try writeMockSSHScript(
            body: """
            #!/bin/sh
            printf 'leihan@trillium.alliancecan.ca: Permission denied (publickey).\n' > /dev/tty
            exit 255
            """
        )
        defer { try? FileManager.default.removeItem(at: keyDeniedScript.deletingLastPathComponent()) }

        let s1 = LoginSession(alias: "smon-trillium", configPath: "/tmp/c", executable: keyDeniedScript.path)
        try s1.start()
        var events1: [LoginEvent] = []
        for await event in s1.events {
            if case .transcript = event { continue }
            events1.append(event)
        }
        #expect(events1 == [.prompt(.denied(.needsSSHKey)), .failed(.needsSSHKey)])

        let mfaTimeoutScript = try writeMockSSHScript(
            body: """
            #!/bin/sh
            printf 'Duo two-factor login for leihan\n\n 1. Duo Push\n\nPasscode or option (1-1): ' > /dev/tty
            IFS= read -r _ < /dev/tty
            printf 'Login timed out\n' > /dev/tty
            exit 255
            """
        )
        defer { try? FileManager.default.removeItem(at: mfaTimeoutScript.deletingLastPathComponent()) }

        let s2 = LoginSession(alias: "smon-nibi", configPath: "/tmp/c", executable: mfaTimeoutScript.path)
        try s2.start()
        var events2: [LoginEvent] = []
        for await event in s2.events {
            if case .transcript = event { continue }
            events2.append(event)
            if case .prompt(.mfa) = event {
                s2.answer("1")
            }
        }
        #expect(events2 == [
            .prompt(.mfa(options: [.init(number: 1, label: "Duo Push")])),
            .prompt(.denied(.mfaFailed)),
            .failed(.mfaFailed),
        ])

        let unreachableScript = try writeMockSSHScript(
            body: """
            #!/bin/sh
            printf 'ssh: Could not resolve hostname bad.example: nodename nor servname provided\n' > /dev/tty
            exit 255
            """
        )
        defer { try? FileManager.default.removeItem(at: unreachableScript.deletingLastPathComponent()) }

        let s3 = LoginSession(alias: "smon-bad", configPath: "/tmp/c", executable: unreachableScript.path)
        try s3.start()
        var events3: [LoginEvent] = []
        for await event in s3.events {
            if case .transcript = event { continue }
            events3.append(event)
        }
        #expect(events3 == [.failed(.unreachable)])
    }

    @Test func loginSessionCancelStopsSessionWithoutSucceeded() async throws {
        let hangingScript = try writeMockSSHScript(
            body: """
            #!/bin/sh
            printf "leihan@nibi.alliancecan.ca's password: " > /dev/tty
            IFS= read -r _ < /dev/tty
            sleep 30
            """
        )
        defer { try? FileManager.default.removeItem(at: hangingScript.deletingLastPathComponent()) }

        let session = LoginSession(alias: "smon-nibi", configPath: "/tmp/c", executable: hangingScript.path)
        try session.start()

        var sawPassword = false
        var terminalEvents: [LoginEvent] = []
        for await event in session.events {
            switch event {
            case .prompt(.password):
                sawPassword = true
                session.cancel()
            case .succeeded, .failed:
                terminalEvents.append(event)
            case .transcript, .prompt:
                break
            }
        }
        #expect(sawPassword)
        #expect(terminalEvents.isEmpty)
    }

    @Test func loginSessionHandlesChunkedPromptsAndPassphrase() async throws {
        let scriptURL = try writeMockSSHScript(
            body: """
            #!/bin/sh
            set -eu
            printf 'ED25519 key fingerprint is SHA256:chunk' > /dev/tty
            sleep 0.05
            printf 'ed123.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ' > /dev/tty
            IFS= read -r host_answer < /dev/tty
            if [ "$host_answer" != "yes" ]; then exit 91; fi

            stty -f /dev/tty -echo
            printf "Enter passphrase for key '/Users/a/.ssh/id_ed25519': " > /dev/tty
            IFS= read -r pass_answer < /dev/tty
            stty -f /dev/tty echo
            printf '\n' > /dev/tty
            if [ "$pass_answer" != "passphrase123" ]; then exit 92; fi

            printf 'Duo two-factor login for leihan\n\n 1. Duo Push\n' > /dev/tty
            sleep 0.05
            printf '\nPasscode or option (1-1): ' > /dev/tty
            IFS= read -r mfa_answer < /dev/tty
            if [ "$mfa_answer" != "1" ]; then exit 93; fi
            exit 0
            """
        )
        defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

        let session = LoginSession(
            alias: "smon-fir",
            configPath: "/tmp/cfg",
            executable: scriptURL.path
        )
        try session.start()

        var prompts: [LoginPrompt] = []
        var transcript = ""
        var terminalEvents: [LoginEvent] = []
        for await event in session.events {
            switch event {
            case .transcript(let chunk):
                transcript += chunk
            case .prompt(let prompt):
                prompts.append(prompt)
                switch prompt {
                case .hostKey:
                    session.answer("yes")
                case .passphrase:
                    session.answer("passphrase123")
                case .mfa:
                    session.answer("1")
                case .password, .denied:
                    break
                }
            case .succeeded, .failed:
                terminalEvents.append(event)
            }
        }

        #expect(prompts == [
            .hostKey(fingerprint: "SHA256:chunked123"),
            .passphrase,
            .mfa(options: [.init(number: 1, label: "Duo Push")]),
        ])
        #expect(terminalEvents == [.succeeded])
        #expect(!transcript.contains("passphrase123"))
    }

    @Test func ptyPreservesMultibyteUTF8AcrossWrites() async throws {
        let p = try PTYProcess(
            executable: "/bin/sh",
            args: ["-c", "printf '\\360\\237'; sleep 0.03; printf '\\232\\200\\n'"]
        )
        var seen = ""
        for await chunk in p.output {
            seen += chunk
        }
        #expect(seen.contains("🚀"))
        #expect(!seen.contains("\u{FFFD}"))
        #expect(await p.waitForExit() == 0)
    }

    private func writeMockSSHScript(body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slurm-monitor-pty-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mock-ssh.sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
