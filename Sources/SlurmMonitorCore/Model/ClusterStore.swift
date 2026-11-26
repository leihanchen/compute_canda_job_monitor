import Foundation

/// Persists monitored cluster configurations as JSON on disk.
public final class ClusterStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Loads configured clusters from disk, returning an empty list when the file does not exist yet.
    public func load() throws -> [ClusterConfig] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ClusterConfig].self, from: data)
    }

    /// Saves configured clusters atomically, creating missing parent directories as needed.
    public func save(_ clusters: [ClusterConfig]) throws {
        let parentDirectory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(clusters)
        try data.write(to: fileURL, options: .atomic)
    }
}
