import Foundation
@testable import SlurmMonitorCore

final class FakeRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(executable: String, args: [String], stdin: String?)] = []
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
        recordCall(executable, args: args, stdin: stdin)
    }

    private func recordCall(
        _ executable: String,
        args: [String],
        stdin: String?
    ) -> CommandResult {
        withLock {
            _calls.append((executable: executable, args: args, stdin: stdin))
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
