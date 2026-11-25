import AppKit
import SlurmMonitorCore
import SwiftUI

@main
struct SlurmMonitorApp: App {
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(env)
        } label: {
            MenuBarLabelView(dashboard: env.model.dashboard)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabelView: View {
    let dashboard: Dashboard

    // Non-template image keeps the stale indicator orange in both light and dark menu bars.
    private static let staleDotImage: NSImage = {
        let size = NSSize(width: 6, height: 6)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()

    var body: some View {
        HStack(spacing: 5) {
            Text(dashboard.menuBarText)
                .monospacedDigit()
            if dashboard.hasStale {
                Image(nsImage: Self.staleDotImage)
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let base = "Slurm Monitor: \(dashboard.runningCount) running, \(dashboard.pendingCount) pending"
        return dashboard.hasStale ? "\(base), stale data" : base
    }
}
