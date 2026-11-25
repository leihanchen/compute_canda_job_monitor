import Foundation

/// Global application preferences persisted in `UserDefaults`.
public struct AppSettings: Codable, Equatable, Sendable {
    private static let storageKey = "appSettings"

    public var refreshIntervalMinutes: Int
    public var stayAwakeWhilePluggedIn: Bool
    public var launchAtLogin: Bool

    public init(
        refreshIntervalMinutes: Int = 5,
        stayAwakeWhilePluggedIn: Bool = false,
        launchAtLogin: Bool = false
    ) {
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.stayAwakeWhilePluggedIn = stayAwakeWhilePluggedIn
        self.launchAtLogin = launchAtLogin
    }

    /// Loads saved settings from `defaults`, returning defaults when absent or unreadable.
    public static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    /// Persists settings to `defaults` under the `"appSettings"` key.
    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
