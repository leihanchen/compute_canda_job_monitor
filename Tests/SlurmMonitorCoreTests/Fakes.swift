import Foundation
@testable import SlurmMonitorCore

final class FakeRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(executable: String, args: [String], stdin: String?)] = []
    private var _timeouts: [TimeInterval] = []
    private var queued: [(predicate: @Sendable (String, [String], String?) -> Bool, result: CommandResult)] = []
    private let defaultResult: CommandResult

    init(
        default defaultResult: CommandResult = CommandResult(
            exitCode: 0,
            stdout: "",
            stderr: "",
            timedOut: false
        )
    ) {
        self.defaultResult = defaultResult
    }

    var calls: [(executable: String, args: [String], stdin: String?)] {
        withLock { _calls }
    }

    var timeouts: [TimeInterval] {
        withLock { _timeouts }
    }

    func enqueue(
        where predicate: @escaping @Sendable (String, [String], String?) -> Bool,
        result: CommandResult
    ) {
        withLock {
            queued.append((predicate, result))
        }
    }

    func run(
        _ executable: String,
        _ args: [String],
        stdin: String?,
        timeout: TimeInterval
    ) async -> CommandResult {
        recordCall(executable, args: args, stdin: stdin, timeout: timeout)
    }

    private func recordCall(
        _ executable: String,
        args: [String],
        stdin: String?,
        timeout: TimeInterval
    ) -> CommandResult {
        withLock {
            _calls.append((executable: executable, args: args, stdin: stdin))
            _timeouts.append(timeout)
            if let index = queued.firstIndex(where: { $0.predicate(executable, args, stdin) }) {
                return queued.remove(at: index).result
            }
            return defaultResult
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class FakeTransport: ClusterTransport, @unchecked Sendable {
    let kind: ConnectionMethodKind
    private let lock = NSLock()
    private var _probeResult: TransportState
    private var _runResult: Result<String, Error>
    private var _runHandler: (@Sendable (String, TimeInterval) async throws -> String)?
    private var _probeCount = 0
    private var _runCount = 0
    private var _scripts: [String] = []
    private var _timeouts: [TimeInterval] = []

    init(
        kind: ConnectionMethodKind = .sharedSSH,
        probeResult: TransportState = .usable,
        runResult: Result<String, Error> = .success(""),
        runHandler: (@Sendable (String, TimeInterval) async throws -> String)? = nil
    ) {
        self.kind = kind
        self._probeResult = probeResult
        self._runResult = runResult
        self._runHandler = runHandler
    }

    var probeResult: TransportState {
        get { withLock { _probeResult } }
        set { withLock { _probeResult = newValue } }
    }

    var runResult: Result<String, Error> {
        get { withLock { _runResult } }
        set { withLock { _runResult = newValue } }
    }

    var runHandler: (@Sendable (String, TimeInterval) async throws -> String)? {
        get { withLock { _runHandler } }
        set { withLock { _runHandler = newValue } }
    }

    var probeCount: Int {
        withLock { _probeCount }
    }

    var runCount: Int {
        withLock { _runCount }
    }

    var scripts: [String] {
        withLock { _scripts }
    }

    var timeouts: [TimeInterval] {
        withLock { _timeouts }
    }

    func probe() async -> TransportState {
        withLock {
            _probeCount += 1
            return _probeResult
        }
    }

    func run(_ script: String, timeout: TimeInterval) async throws -> String {
        let (handler, result) = withLock {
            _runCount += 1
            _scripts.append(script)
            _timeouts.append(timeout)
            return (_runHandler, _runResult)
        }
        if let handler {
            return try await handler(script, timeout)
        }
        return try result.get()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self {
            return error
        }
        return nil
    }
}
