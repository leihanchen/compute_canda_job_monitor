import Foundation

/// Events emitted while driving an interactive SSH `ControlMaster` login session.
public enum LoginEvent: Sendable, Equatable {
    case transcript(String)
    case prompt(LoginPrompt)
    case succeeded
    case failed(ClusterError)
}

/// Drives `/usr/bin/ssh` in a PTY to authenticate a shared `ControlMaster` connection without storing secrets.
public final class LoginSession: @unchecked Sendable {
    public let events: AsyncStream<LoginEvent>

    private let alias: String
    private let configPath: String
    private let executable: String
    private let continuation: AsyncStream<LoginEvent>.Continuation
    private let lock = NSLock()

    private var process: PTYProcess?
    private var driverTask: Task<Void, Never>?
    private var started = false
    private var cancelled = false
    private var finished = false
    private var unansweredBuffer = ""
    private var fullTranscript = ""
    private var activePrompt: LoginPrompt?
    private var lastDeniedError: ClusterError?

    public init(
        alias: String,
        configPath: String,
        executable: String = "/usr/bin/ssh"
    ) {
        self.alias = alias
        self.configPath = configPath
        self.executable = executable

        var capturedContinuation: AsyncStream<LoginEvent>.Continuation!
        self.events = AsyncStream<LoginEvent> { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation

        self.continuation.onTermination = { [weak self] _ in
            self?.cancel()
        }
    }

    /// Launches the SSH login process in a PTY and begins emitting `LoginEvent`s.
    public func start() throws {
        lock.lock()
        if started || cancelled || finished {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        let args = [
            "-F", configPath,
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=yes",
            "-N",
            "-f",
            alias,
        ]

        let pty: PTYProcess
        do {
            pty = try PTYProcess(executable: executable, args: args)
        } catch {
            lock.lock()
            finished = true
            lock.unlock()
            continuation.finish()
            throw error
        }

        lock.lock()
        if cancelled || finished {
            lock.unlock()
            pty.terminate()
            return
        }
        self.process = pty
        let task = Task {
            await self.drive(pty: pty)
        }
        self.driverTask = task
        lock.unlock()
    }

    /// Sends an interactive response (with trailing newline) to the PTY and resets prompt matching for subsequent output.
    public func answer(_ text: String) {
        let pty: PTYProcess?
        lock.lock()
        guard !cancelled, !finished else {
            lock.unlock()
            return
        }
        unansweredBuffer = ""
        activePrompt = nil
        lastDeniedError = nil
        pty = process
        lock.unlock()

        let line = text.hasSuffix("\n") ? text : text + "\n"
        pty?.write(line)
    }

    /// Cancels the login session, terminates the child PTY process, and finishes `events`.
    public func cancel() {
        let pty: PTYProcess?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        cancelled = true
        finished = true
        unansweredBuffer = ""
        activePrompt = nil
        lastDeniedError = nil
        pty = process
        process = nil
        driverTask = nil
        lock.unlock()

        pty?.terminate()
        continuation.finish()
    }

    private func drive(pty: PTYProcess) async {
        for await chunk in pty.output {
            if isCancelledOrFinished() {
                break
            }
            let transcriptChunk = LoginPromptClassifier.sanitizeForTranscript(chunk)
            if !transcriptChunk.isEmpty {
                emitIfActive(.transcript(transcriptChunk))
            }
            if let prompt = appendChunkAndClassify(chunk) {
                emitIfActive(.prompt(prompt))
            }
        }

        let exitCode = await pty.waitForExit()
        finishWithExitCode(exitCode)
    }

    private func isCancelledOrFinished() -> Bool {
        lock.lock()
        let result = cancelled || finished
        lock.unlock()
        return result
    }

    private func emitIfActive(_ event: LoginEvent) {
        lock.lock()
        let shouldEmit = !cancelled && !finished
        lock.unlock()
        if shouldEmit {
            continuation.yield(event)
        }
    }

    private func appendChunkAndClassify(_ chunk: String) -> LoginPrompt? {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, !finished else { return nil }

        fullTranscript.append(chunk)
        if fullTranscript.count > 65_536 {
            fullTranscript = String(fullTranscript.suffix(65_536))
        }

        unansweredBuffer.append(chunk)
        guard let classified = LoginPromptClassifier.classify(unansweredBuffer) else {
            return nil
        }

        if case .denied(let error) = classified {
            lastDeniedError = error
        }

        if classified == activePrompt {
            return nil
        }
        activePrompt = classified
        return classified
    }

    private func finishWithExitCode(_ exitCode: Int32) {
        lock.lock()
        guard !cancelled, !finished else {
            process = nil
            driverTask = nil
            lock.unlock()
            return
        }
        finished = true
        let deniedError = lastDeniedError
        let failureOutput = unansweredBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fullTranscript
            : unansweredBuffer
        process = nil
        driverTask = nil
        lock.unlock()

        if exitCode == 0 {
            continuation.yield(.succeeded)
        } else {
            let error = Self.classifyFailure(
                exitCode: exitCode,
                deniedError: deniedError,
                transcript: failureOutput
            )
            continuation.yield(.failed(error))
        }
        continuation.finish()
    }

    private static func classifyFailure(
        exitCode: Int32,
        deniedError: ClusterError?,
        transcript: String
    ) -> ClusterError {
        if let deniedError {
            return deniedError
        }
        let normalized = LoginPromptClassifier.normalize(transcript)
        if case .denied(let classified) = LoginPromptClassifier.classify(normalized) {
            return classified
        }
        return ClusterErrorClassifier.classify(
            CommandResult(exitCode: exitCode, stdout: "", stderr: normalized, timedOut: false)
        )
    }
}
