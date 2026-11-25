import CPTYHelper
import Darwin
import Foundation

/// Runs a subprocess attached to a pseudo-terminal with a controlling TTY (`/dev/tty`).
public final class PTYProcess: @unchecked Sendable {
    public let output: AsyncStream<String>

    private let queue = DispatchQueue(label: "com.slurm-monitor.pty-process")
    private let pid: pid_t
    private let outputContinuation: AsyncStream<String>.Continuation

    private var masterFD: Int32
    private var readSource: DispatchSourceRead?
    private var postExitDrainTimer: DispatchSourceTimer?
    private var killTimer: DispatchSourceTimer?

    private var pendingUTF8: [UInt8] = []
    private var readEOF = false
    private var streamFinished = false
    private var streamConsumerCancelled = false
    private var processExited = false
    private var exitCode: Int32 = -1
    private var terminated = false
    private var waitContinuations: [CheckedContinuation<Int32, Never>] = []
    private var retainedSelf: PTYProcess?

    public init(executable: String, args: [String]) throws {
        let allArgs = [executable] + args
        var cStrings: [UnsafeMutablePointer<CChar>?] = allArgs.map { strdup($0) }
        cStrings.append(nil)
        defer {
            for ptr in cStrings where ptr != nil {
                free(ptr)
            }
        }

        if cStrings.dropLast().contains(where: { $0 == nil }) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
        }

        let spawnResult = executable.withCString { execPtr in
            cStrings.withUnsafeMutableBufferPointer { buffer in
                cpty_spawn(execPtr, buffer.baseAddress!)
            }
        }

        guard spawnResult.error_number == 0, spawnResult.pid > 0, spawnResult.master_fd >= 0 else {
            let code = spawnResult.error_number != 0 ? Int(spawnResult.error_number) : Int(EIO)
            throw NSError(domain: NSPOSIXErrorDomain, code: code)
        }

        self.pid = spawnResult.pid
        self.masterFD = spawnResult.master_fd

        let flags = fcntl(spawnResult.master_fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(spawnResult.master_fd, F_SETFL, flags | O_NONBLOCK)
        }
        _ = fcntl(spawnResult.master_fd, F_SETNOSIGPIPE, 1)

        var capturedContinuation: AsyncStream<String>.Continuation!
        self.output = AsyncStream<String> { continuation in
            capturedContinuation = continuation
        }
        self.outputContinuation = capturedContinuation
        self.retainedSelf = self

        let queue = self.queue
        self.outputContinuation.onTermination = { [weak self] _ in
            queue.async {
                self?.streamConsumerCancelled = true
            }
        }

        let fd = spawnResult.master_fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainMasterFD()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        self.readSource = source
        source.resume()

        let spawnedPID = spawnResult.pid
        Thread.detachNewThread { [weak self] in
            _ = cpty_wait_no_reap(spawnedPID)
            queue.async {
                self?.handleChildReadyToReap()
            }
        }
    }

    /// Writes `s` to the PTY master file descriptor without logging or retaining its contents.
    public func write(_ s: String) {
        let bytes = Array(s.utf8)
        guard !bytes.isEmpty else { return }

        queue.async {
            let fd = self.masterFD
            guard fd >= 0, !self.readEOF, !self.terminated, !self.streamFinished else {
                return
            }

            var offset = 0
            var eagainRetries = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes { rawBuffer -> ssize_t in
                    guard let base = rawBuffer.baseAddress else { return 0 }
                    return Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                }
                if written > 0 {
                    offset += written
                    eagainRetries = 0
                } else if written == -1 && errno == EINTR {
                    continue
                } else if written == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) && eagainRetries < 50 {
                    eagainRetries += 1
                    usleep(1_000)
                } else {
                    break
                }
            }
        }
    }

    /// Suspends until the child process has exited and been reaped, returning its decoded exit code.
    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.processExited && self.streamFinished {
                    continuation.resume(returning: self.exitCode)
                } else {
                    self.waitContinuations.append(continuation)
                }
            }
        }
    }

    /// Terminates the PTY process group (`SIGTERM`, escalating to `SIGKILL` after 200ms) and closes output.
    public func terminate() {
        queue.async {
            if self.terminated {
                return
            }
            self.terminated = true

            if !self.processExited {
                self.sendSignal(SIGTERM)

                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + .milliseconds(200))
                timer.setEventHandler { [weak self] in
                    guard let self, !self.processExited else { return }
                    self.sendSignal(SIGKILL)
                }
                self.killTimer = timer
                timer.resume()
            }

            self.finishOutputStream()
            self.resolveWaitersIfReady()
        }
    }

    private func sendSignal(_ sig: Int32) {
        if Darwin.kill(-pid, sig) != 0 && errno == ESRCH {
            _ = Darwin.kill(pid, sig)
        }
    }

    private func handleChildReadyToReap() {
        var code: Int32 = -1
        _ = cpty_reap_exit_status(pid, &code)

        processExited = true
        exitCode = code
        killTimer?.cancel()
        killTimer = nil

        if !readEOF && !streamFinished {
            drainMasterFD()
        }

        if !streamFinished {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(50))
            timer.setEventHandler { [weak self] in
                self?.finishOutputStream()
                self?.resolveWaitersIfReady()
            }
            postExitDrainTimer = timer
            timer.resume()
        }

        resolveWaitersIfReady()
    }

    private func drainMasterFD() {
        let fd = masterFD
        guard fd >= 0, !readEOF else { return }

        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                if !streamConsumerCancelled && !streamFinished {
                    let text = decodeUTF8Chunk(Array(buffer[..<count]))
                    if !text.isEmpty {
                        outputContinuation.yield(text)
                    }
                }
            } else if count == 0 {
                markReadEOF()
                return
            } else {
                let err = errno
                if err == EINTR {
                    continue
                }
                if err == EAGAIN || err == EWOULDBLOCK {
                    return
                }
                // On macOS PTYs, slave closure may report EIO / ENXIO.
                markReadEOF()
                return
            }
        }
    }

    private func markReadEOF() {
        guard !readEOF else { return }
        readEOF = true
        finishOutputStream()
        resolveWaitersIfReady()
    }

    private func finishOutputStream() {
        postExitDrainTimer?.cancel()
        postExitDrainTimer = nil

        if masterFD >= 0 {
            masterFD = -1
            readSource?.cancel()
            readSource = nil
        }

        if !streamFinished {
            streamFinished = true
            if !pendingUTF8.isEmpty && !streamConsumerCancelled {
                let trailing = String(decoding: pendingUTF8, as: UTF8.self)
                if !trailing.isEmpty {
                    outputContinuation.yield(trailing)
                }
            }
            pendingUTF8.removeAll()
            outputContinuation.finish()
        }
    }

    private func resolveWaitersIfReady() {
        guard processExited && streamFinished else { return }
        let waiters = waitContinuations
        waitContinuations.removeAll()
        let code = exitCode
        for waiter in waiters {
            waiter.resume(returning: code)
        }
        retainedSelf = nil
    }

    private func decodeUTF8Chunk(_ newBytes: [UInt8]) -> String {
        var bytes = pendingUTF8
        bytes.append(contentsOf: newBytes)
        pendingUTF8.removeAll()

        let splitIndex = utf8CompletePrefixEndIndex(bytes)
        if splitIndex < bytes.count {
            pendingUTF8 = Array(bytes[splitIndex...])
        }
        guard splitIndex > 0 else { return "" }
        return String(decoding: bytes[..<splitIndex], as: UTF8.self)
    }

    private func utf8CompletePrefixEndIndex(_ bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }
        let maxLookback = min(3, bytes.count)
        for offset in 1...maxLookback {
            let idx = bytes.count - offset
            let b = bytes[idx]
            if (b & 0xC0) == 0x80 {
                continue
            }
            let expectedLength: Int
            if b < 0x80 {
                expectedLength = 1
            } else if (b & 0xE0) == 0xC0 {
                expectedLength = 2
            } else if (b & 0xF0) == 0xE0 {
                expectedLength = 3
            } else if (b & 0xF8) == 0xF0 {
                expectedLength = 4
            } else {
                return bytes.count
            }
            let available = bytes.count - idx
            return available < expectedLength ? idx : bytes.count
        }
        return bytes.count
    }
}
