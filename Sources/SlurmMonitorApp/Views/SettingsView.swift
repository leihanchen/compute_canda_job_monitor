import ServiceManagement
import SlurmMonitorCore
import SwiftUI

/// Settings popover configuring refresh interval, stay-awake power assertion, and launch-at-login.
struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var launchAtLoginMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.headline)

            Stepper(value: $env.settings.refreshIntervalMinutes, in: 1...30) {
                HStack {
                    Text("Refresh interval")
                    Spacer()
                    Text("\(env.settings.refreshIntervalMinutes) min")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Stay awake while plugged in", isOn: $env.settings.stayAwakeWhilePluggedIn)
                Text(
                    "Prevents idle sleep on AC power while ≥1 connection is live. Long sleep, closed lid, and Wi-Fi/VPN changes still drop shared connections; only the future robot path survives those."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show in Dock", isOn: $env.settings.showInDock)
                Text("Clicking the Dock icon opens this panel. The menu bar item is always shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { env.settings.launchAtLogin },
                        set: { updateLaunchAtLogin($0) }
                    )
                )
                if let launchAtLoginMessage {
                    Text(launchAtLoginMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            syncLaunchAtLoginIfBundled()
        }
    }

    private func syncLaunchAtLoginIfBundled() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        applyServiceStatus(SMAppService.mainApp.status)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
                let status = SMAppService.mainApp.status
                if status == .requiresApproval {
                    applyServiceStatus(status)
                } else {
                    env.settings.launchAtLogin = true
                }
            } else {
                try SMAppService.mainApp.unregister()
                env.settings.launchAtLogin = false
            }
        } catch {
            env.settings.launchAtLogin = !enabled
            launchAtLoginMessage = "Could not update Login Items in this build: \(error.localizedDescription)"
        }
    }

    private func applyServiceStatus(_ status: SMAppService.Status) {
        switch status {
        case .enabled:
            if !env.settings.launchAtLogin {
                env.settings.launchAtLogin = true
            }
            launchAtLoginMessage = nil
        case .requiresApproval:
            if !env.settings.launchAtLogin {
                env.settings.launchAtLogin = true
            }
            launchAtLoginMessage = "Waiting for approval in System Settings → Login Items"
        case .notRegistered, .notFound:
            if env.settings.launchAtLogin {
                env.settings.launchAtLogin = false
            }
            launchAtLoginMessage = nil
        @unknown default:
            break
        }
    }
}
