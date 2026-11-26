import Foundation

/// Global application preferences persisted in `UserDefaults`.
public struct AppSettings: Codable, Equatable, Sendable {
    private static let storageKey = "appSettings"

    public var refreshIntervalMinutes: Int
    public var stayAwakeWhilePluggedIn: Bool
    public var launchAtLogin: Bool
    /// Shows the app icon in the Dock (in addition to the menu bar item).
    public var showInDock: Bool

    public init(
        refreshIntervalMinutes: Int = 5,
        stayAwakeWhilePluggedIn: Bool = false,
        launchAtLogin: Bool = false,
        showInDock: Bool = true
    ) {
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.stayAwakeWhilePluggedIn = stayAwakeWhilePluggedIn
        self.launchAtLogin = launchAtLogin
        self.showInDock = showInDock
    }

    private enum CodingKeys: String, CodingKey {
        case refreshIntervalMinutes, stayAwakeWhilePluggedIn, launchAtLogin, showInDock
    }

    /// Missing keys fall back to defaults so settings saved by older versions still load.
    public init(from decoder: Decoder) throws {
        let defaults = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refreshIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes)
            ?? defaults.refreshIntervalMinutes
        stayAwakeWhilePluggedIn = try c.decodeIfPresent(Bool.self, forKey: .stayAwakeWhilePluggedIn)
            ?? defaults.stayAwakeWhilePluggedIn
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? defaults.showInDock
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
