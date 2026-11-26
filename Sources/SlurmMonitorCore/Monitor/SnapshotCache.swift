import Foundation

/// Persists the most recent `ClusterSnapshot` per cluster as `<uuid>.json` on disk.
public final class SnapshotCache: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Loads the cached snapshot for `id`, returning `nil` when missing or unreadable.
    public func load(_ id: UUID) -> ClusterSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else {
            return nil
        }
        return try? JSONDecoder().decode(ClusterSnapshot.self, from: data)
    }

    /// Atomically writes `snapshot` to `<clusterID>.json`, creating the cache directory if needed.
    public func save(_ snapshot: ClusterSnapshot) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL(for: snapshot.clusterID), options: .atomic)
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
