import Darwin
import Foundation

/// Outcome of executing an external subprocess.
public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Abstraction for executing local processes (such as `/usr/bin/ssh`).
public protocol CommandRunner: Sendable {
    func run(
        _ executable: String,
        _ args: [String],
        stdin: String?,
        timeout: TimeInterval
    ) async -> CommandResult
}

/// Runs subprocesses via `Foundation.Process` with concurrent non-blocking pipe draining and timeout termination.
public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(
        _ executable: String,
        _ args: [String],
        stdin: String?,
        timeout: TimeInterval
    ) async -> CommandResult {
        await withCheckedContinuation { continuation in
            let execution = ProcessExecution(
                executable: executable,
                args: args,
                stdin: stdin,
                timeout: timeout,
                continuation: continuation
            )
            execution.start()
        }
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.slurm-monitor.process-runner")
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe: Pipe?
    private let stdinString: String?
    private let timeout: TimeInterval

    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutEOF = false
    private var stderrEOF = false
    private var processExited = false
    private var exitCode: Int32 = -1
    private var timedOut = false
    private var finished = false

    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var timeoutTimer: DispatchSourceTimer?
    private var forceKillTimer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<CommandResult, Never>?
    private var retainedSelf: ProcessExecution?

    init(
        executable: String,
        args: [String],
        stdin: String?,
        timeout: TimeInterval,
        continuation: CheckedContinuation<CommandResult, Never>
    ) {
        self.stdinString = stdin
        self.stdinPipe = stdin == nil ? nil : Pipe()
        self.timeout = max(0, timeout)
        self.continuation = continuation

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
    }

    func start() {
        retainedSelf = self
        queue.async {
            self.startOnQueue()
        }
    }

    private func startOnQueue() {
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            self?.queue.async {
                guard let self else { return }
                self.processExited = true
                self.exitCode = status
                self.finishIfReady()
            }
        }

        do {
            try process.run()
        } catch {
            closeAllPipesOnLaunchFailure()
            finish(with: CommandResult(
                exitCode: -1,
                stdout: "",
                stderr: error.localizedDescription,
                timedOut: false
            ))
            return
        }

        setupPipeSources()
        armTimeoutTimer()

        if let stdinString, let stdinPipe {
            writeStdinAsync(stdinString, to: stdinPipe.fileHandleForWriting)
        }
    }

    private func setupPipeSources() {
        guard !finished else { return }
        stdoutSource = makeReadSource(for: stdoutPipe.fileHandleForReading, isStdout: true)
        stderrSource = makeReadSource(for: stderrPipe.fileHandleForReading, isStdout: false)
        stdoutSource?.resume()
        stderrSource?.resume()
    }

    private func makeReadSource(for handle: FileHandle, isStdout: Bool) -> DispatchSourceRead {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainPipe(fd: fd, isStdout: isStdout, source: source)
        }
        source.setCancelHandler {
            try? handle.close()
        }
        return source
    }

    private func drainPipe(fd: Int32, isStdout: Bool, source: DispatchSourceRead) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                if isStdout {
                    stdoutData.append(contentsOf: buffer[..<count])
                } else {
                    stderrData.append(contentsOf: buffer[..<count])
                }
            } else if count == 0 {
                markEOF(isStdout: isStdout, source: source)
                return
            } else {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                markEOF(isStdout: isStdout, source: source)
                return
            }
        }
    }

    private func markEOF(isStdout: Bool, source: DispatchSourceRead) {
        if isStdout {
            stdoutEOF = true
            stdoutSource = nil
        } else {
            stderrEOF = true
            stderrSource = nil
        }
        source.cancel()
        finishIfReady()
    }

    private func armTimeoutTimer() {
        guard !finished else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            self?.handleTimeout()
        }
        timeoutTimer = timer
        timer.resume()
    }

    private func handleTimeout() {
        guard !finished else { return }
        timedOut = true
        if process.isRunning {
            process.terminate()
        }

        // Ensure stubborn children or inherited pipe descriptors cannot keep us waiting indefinitely.
        let killTimer = DispatchSource.makeTimerSource(queue: queue)
        killTimer.schedule(deadline: .now() + .milliseconds(150))
        killTimer.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            if self.process.isRunning {
                Darwin.kill(self.process.processIdentifier, SIGKILL)
            }
            self.finishNow()
        }
        forceKillTimer = killTimer
        killTimer.resume()
    }

    private func finishIfReady() {
        guard processExited && stdoutEOF && stderrEOF else { return }
        finishNow()
    }

    private func finishNow() {
        let finalExitCode = timedOut ? Int32(-1) : exitCode
        let result = CommandResult(
            exitCode: finalExitCode,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            timedOut: timedOut
        )
        finish(with: result)
    }

    private func finish(with result: CommandResult) {
        guard !finished, let cont = continuation else { return }
        finished = true
        continuation = nil

        timeoutTimer?.cancel()
        timeoutTimer = nil
        forceKillTimer?.cancel()
        forceKillTimer = nil
        stdoutSource?.cancel()
        stdoutSource = nil
        stderrSource?.cancel()
        stderrSource = nil
        retainedSelf = nil

        cont.resume(returning: result)
    }

    private func writeStdinAsync(_ text: String, to handle: FileHandle) {
        let data = Data(text.utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    private func closeAllPipesOnLaunchFailure() {
        try? stdoutPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForWriting.close()
        if let stdinPipe {
            try? stdinPipe.fileHandleForReading.close()
            try? stdinPipe.fileHandleForWriting.close()
        }
    }
}
