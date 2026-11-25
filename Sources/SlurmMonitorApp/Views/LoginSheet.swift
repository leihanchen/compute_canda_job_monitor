import SlurmMonitorCore
import SwiftUI

/// Outcome of a single cluster's interactive login attempt within `AppEnvironment.login(_:)`.
enum LoginAttemptOutcome: Sendable {
    case succeeded
    case skipped(ClusterError?)
    case stopped(ClusterError?)
}

/// Active presentation state for the sequential `LoginSheet` queue.
@MainActor
enum ActiveLoginState {
    case preparing(cluster: ClusterConfig, position: Int, total: Int, status: String)
    case session(LoginSessionController)
}

/// Main-actor state controller wrapping `LoginSession` for one cluster without retaining secrets.
@MainActor
final class LoginSessionController: ObservableObject {
    enum Phase: Equatable {
        case connecting
        case prompt(LoginPrompt)
        case waiting(String)
        case succeeded
        case failed(ClusterError, detail: String?)
    }

    let attemptID = UUID()
    let cluster: ClusterConfig
    let position: Int
    let total: Int

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var transcript = ""

    private let configPath: String
    private let executable: String
    private var session: LoginSession?
    private var eventTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<LoginAttemptOutcome, Never>?
    private var transcriptBuffer = ""
    private var terminalError: ClusterError?
    private var finalOutcome: LoginAttemptOutcome?
    private var isCancelled = false
    private var isFinished = false

    var recordedError: ClusterError? {
        terminalError
    }

    private static let maxTranscriptCharacters = 8_192
    private static let maxTranscriptLines = 120

    init(
        cluster: ClusterConfig,
        configPath: String,
        position: Int,
        total: Int,
        executable: String = "/usr/bin/ssh"
    ) {
        self.cluster = cluster
        self.configPath = configPath
        self.position = position
        self.total = total
        self.executable = executable
    }

    /// Starts the underlying `LoginSession` and suspends until the attempt succeeds, is skipped, or is stopped.
    func run() async -> LoginAttemptOutcome {
        if let finalOutcome {
            return finalOutcome
        }
        if isCancelled {
            return .stopped(terminalError)
        }

        startSession()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if let finalOutcome {
                    cont.resume(returning: finalOutcome)
                } else if isCancelled {
                    cont.resume(returning: .stopped(terminalError))
                } else {
                    self.continuation = cont
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
    }

    /// Trusts the presented SSH host key fingerprint by answering `"yes"`.
    func answerHostKeyTrust() {
        sendAnswer("yes", waitingMessage: "Verifying host key…")
    }

    /// Sends a password or passphrase directly to `LoginSession` without storing it.
    func answerSecret(_ secret: String) {
        sendAnswer(secret, waitingMessage: "Authenticating…")
    }

    /// Sends an MFA option number or passcode directly to `LoginSession` without storing it.
    func answerMFA(_ response: String) {
        sendAnswer(response, waitingMessage: "Waiting for Duo approval…")
    }

    /// Cancels the active SSH login attempt and advances to the next queued cluster.
    func skip() {
        cancelSession()
        resolve(.skipped(terminalError))
    }

    /// Cancels the active SSH login attempt and halts the remaining queue.
    func stop() {
        cancelSession()
        resolve(.stopped(terminalError))
    }

    private func startSession() {
        let newSession = LoginSession(
            alias: cluster.generatedAlias,
            configPath: configPath,
            executable: executable
        )
        self.session = newSession

        do {
            try newSession.start()
        } catch {
            terminalError = .needsLogin
            phase = .failed(.needsLogin, detail: error.localizedDescription)
            return
        }

        eventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in newSession.events {
                if Task.isCancelled || self.isCancelled {
                    break
                }
                self.handleEvent(event)
            }
            if !self.isCancelled && !self.isFinished {
                let fallback = self.terminalError ?? .needsLogin
                self.terminalError = fallback
                if case .failed = self.phase {
                    return
                }
                self.phase = .failed(fallback, detail: nil)
            }
        }
    }

    private func handleEvent(_ event: LoginEvent) {
        switch event {
        case .transcript(let chunk):
            appendTranscript(chunk)

        case .prompt(let prompt):
            if case .denied(let err) = prompt {
                terminalError = err
                phase = .failed(err, detail: nil)
            } else {
                phase = .prompt(prompt)
            }

        case .succeeded:
            isFinished = true
            phase = .succeeded
            resolve(.succeeded)

        case .failed(let err):
            isFinished = true
            terminalError = err
            phase = .failed(err, detail: nil)
        }
    }

    private func sendAnswer(_ response: String, waitingMessage: String) {
        guard let session, !isCancelled, !isFinished else { return }
        phase = .waiting(waitingMessage)
        session.answer(response)
    }

    private func cancelSession() {
        isCancelled = true
        session?.cancel()
        session = nil
        eventTask?.cancel()
        eventTask = nil
    }

    private func resolve(_ outcome: LoginAttemptOutcome) {
        finalOutcome = outcome
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: outcome)
    }

    private func appendTranscript(_ chunk: String) {
        transcriptBuffer.append(chunk)
        if transcriptBuffer.count > Self.maxTranscriptCharacters {
            transcriptBuffer = String(transcriptBuffer.suffix(Self.maxTranscriptCharacters))
        }
        let lines = transcriptBuffer.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > Self.maxTranscriptLines {
            transcriptBuffer = lines.suffix(Self.maxTranscriptLines).joined(separator: "\n")
        }
        transcript = transcriptBuffer
    }
}

/// Interactive sheet driving sequential SSH / MFA login sessions without storing credentials.
struct LoginSheet: View {
    @EnvironmentObject private var env: AppEnvironment

    let state: ActiveLoginState

    var body: some View {
        Group {
            switch state {
            case .preparing(let cluster, let position, let total, let status):
                PreparingLoginView(
                    cluster: cluster,
                    position: position,
                    total: total,
                    status: status,
                    onStop: { env.cancelLogin() }
                )

            case .session(let controller):
                LoginSessionBody(controller: controller)
                    .id(controller.attemptID)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}

private struct PreparingLoginView: View {
    let cluster: ClusterConfig
    let position: Int
    let total: Int
    let status: String
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LoginHeaderView(cluster: cluster, position: position, total: total)

            Card {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            HStack {
                Spacer()
                Button("Stop", role: .cancel) {
                    onStop()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
            }
        }
    }
}

private struct LoginSessionBody: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var controller: LoginSessionController

    @State private var secretInput = ""
    @State private var mfaCodeInput = ""
    @FocusState private var focusedField: InputField?

    private static let ccdbKeysURL = URL(string: "https://ccdb.alliancecan.ca/ssh_authorized_keys")!
    private static let ccdbPortalURL = URL(string: "https://ccdb.alliancecan.ca/")!

    private enum InputField: Hashable {
        case secret
        case mfaCode
    }

    private var hasMoreClusters: Bool {
        controller.position < controller.total
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LoginHeaderView(
                cluster: controller.cluster,
                position: controller.position,
                total: controller.total
            )

            transcriptCard
            promptCard
            footer
        }
        .onChange(of: controller.phase) { _, newPhase in
            secretInput = ""
            mfaCodeInput = ""
            updateFocus(for: newPhase)
        }
        .onAppear {
            updateFocus(for: controller.phase)
        }
        .onDisappear {
            secretInput = ""
            mfaCodeInput = ""
        }
    }

    private var transcriptCard: some View {
        Card("SSH output") {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(controller.transcript.isEmpty ? "Connecting to \(controller.cluster.host)…" : controller.transcript)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(controller.transcript.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear
                            .frame(height: 1)
                            .id("transcript-bottom")
                    }
                }
                .frame(height: 120)
                .onChange(of: controller.transcript) { _, _ in
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var promptCard: some View {
        switch controller.phase {
        case .connecting:
            waitingCard("Starting SSH login…")

        case .waiting(let message):
            waitingCard(message)

        case .succeeded:
            Card {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Connected")
                        .font(.caption.weight(.medium))
                }
                .padding(.vertical, 2)
            }

        case .prompt(let prompt):
            switch prompt {
            case .hostKey(let fingerprint):
                hostKeyCard(fingerprint: fingerprint)
            case .password:
                secretCard(title: "Enter password", placeholder: "Password", note: "Sent directly to ssh and never stored.")
            case .passphrase:
                secretCard(title: "Enter SSH key passphrase", placeholder: "Passphrase", note: "Sent directly to ssh and never stored.")
            case .mfa(let options):
                mfaCard(options: options)
            case .denied(let error):
                deniedCard(error: error, detail: nil)
            }

        case .failed(let error, let detail):
            deniedCard(error: error, detail: detail)
        }
    }

    private func waitingCard(_ message: String) -> some View {
        Card {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private func hostKeyCard(fingerprint: String) -> some View {
        Card("Verify host key") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Confirm this host's SSH fingerprint before trusting it:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(fingerprint.isEmpty ? "Fingerprint unavailable in SSH prompt." : fingerprint)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )

                HStack {
                    Spacer()
                    Button("Cancel") {
                        clearLocalInputs()
                        controller.stop()
                    }
                    .controlSize(.small)

                    Button("Trust") {
                        clearLocalInputs()
                        controller.answerHostKeyTrust()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func secretCard(title: String, placeholder: String, note: String) -> some View {
        Card(title) {
            VStack(alignment: .leading, spacing: 8) {
                SecureField(placeholder, text: $secretInput)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .secret)
                    .onSubmit {
                        submitSecret()
                    }

                HStack {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Continue") {
                        submitSecret()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(secretInput.isEmpty)
                }
            }
        }
    }

    private func mfaCard(options: [MFAOption]) -> some View {
        Card("Multi-factor authentication") {
            VStack(alignment: .leading, spacing: 8) {
                if !options.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(options, id: \.self) { option in
                            Button {
                                mfaCodeInput = ""
                                controller.answerMFA("\(option.number)")
                            } label: {
                                Text("\(option.number) · \(option.label)")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .controlSize(.small)
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("Passcode or option", text: $mfaCodeInput)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .mfaCode)
                        .onSubmit {
                            submitMFA()
                        }

                    Button("Submit") {
                        submitMFA()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(mfaCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func deniedCard(error: ClusterError, detail: String?) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(error.hint, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if controller.cluster.requiresKey, error == .needsSSHKey || error == .noAccess {
                    Text("Trillium also requires access to be requested in CCDB")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Open CCDB") {
                        let url = error == .needsSSHKey ? Self.ccdbKeysURL : Self.ccdbPortalURL
                        openURL(url)
                    }
                    .controlSize(.small)
                }

                if !hasMoreClusters {
                    HStack {
                        Spacer()
                        Button("Close") {
                            clearLocalInputs()
                            controller.stop()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()

            if hasMoreClusters {
                Button("Skip this cluster") {
                    clearLocalInputs()
                    controller.skip()
                }
                .controlSize(.small)

                Button("Stop", role: .cancel) {
                    clearLocalInputs()
                    controller.stop()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
            } else if !isFailedPhase {
                Button("Stop", role: .cancel) {
                    clearLocalInputs()
                    controller.stop()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
            }
        }
    }

    private var isFailedPhase: Bool {
        if case .failed = controller.phase {
            return true
        }
        return false
    }

    private func submitSecret() {
        guard !secretInput.isEmpty else { return }
        let value = secretInput
        secretInput = ""
        controller.answerSecret(value)
    }

    private func submitMFA() {
        let trimmed = mfaCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mfaCodeInput = ""
        controller.answerMFA(trimmed)
    }

    private func clearLocalInputs() {
        secretInput = ""
        mfaCodeInput = ""
    }

    private func updateFocus(for phase: LoginSessionController.Phase) {
        switch phase {
        case .prompt(.password), .prompt(.passphrase):
            focusedField = .secret
        case .prompt(.mfa):
            focusedField = .mfaCode
        default:
            focusedField = nil
        }
    }
}

private struct LoginHeaderView: View {
    let cluster: ClusterConfig
    let position: Int
    let total: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Log in · \(cluster.name)")
                    .font(.headline)
                Text(cluster.sshTarget)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if total > 1 {
                Text("\(position) of \(total)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
            }
        }
    }
}
