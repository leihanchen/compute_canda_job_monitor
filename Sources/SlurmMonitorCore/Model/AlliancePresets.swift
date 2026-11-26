import Foundation

/// A preconfigured Digital Research Alliance of Canada / SciNet cluster definition.
public struct PresetCluster: Sendable, Hashable {
    public let name: String
    public let host: String
    public let requiresKey: Bool

    public init(name: String, host: String, requiresKey: Bool = false) {
        self.name = name
        self.host = host
        self.requiresKey = requiresKey
    }
}

/// Built-in Alliance and SciNet cluster presets.
public enum AlliancePresets {
    public static let all: [PresetCluster] = [
        PresetCluster(name: "nibi", host: "nibi.alliancecan.ca", requiresKey: false),
        PresetCluster(name: "fir", host: "fir.alliancecan.ca", requiresKey: false),
        PresetCluster(name: "narval", host: "narval.alliancecan.ca", requiresKey: false),
        PresetCluster(name: "rorqual", host: "rorqual.alliancecan.ca", requiresKey: false),
        PresetCluster(name: "trillium", host: "trillium.scinet.utoronto.ca", requiresKey: true),
        PresetCluster(name: "trillium-gpu", host: "trillium-gpu.scinet.utoronto.ca", requiresKey: true),
        PresetCluster(name: "tamia", host: "tamia.alliancecan.ca", requiresKey: false),
        PresetCluster(name: "killarney", host: "killarney.alliancecan.ca", requiresKey: false),
    ]

    /// Builds `ClusterConfig` entries for the selected preset names using a single username.
    public static func clusters(username: String, selected: Set<String>) -> [ClusterConfig] {
        all
            .filter { selected.contains($0.name) }
            .map { preset in
                ClusterConfig(
                    name: preset.name,
                    host: preset.host,
                    username: username,
                    requiresKey: preset.requiresKey
                )
            }
    }
}
