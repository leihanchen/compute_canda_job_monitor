import AppKit
import SlurmMonitorCore

/// Controls whether the app shows a Dock icon, and opens the menu bar panel from the Dock.
///
/// `Info.plist` keeps `LSUIElement = true` so the app starts as a menu bar agent with no
/// Dock flash; the Dock icon is then added at launch when the "Show in Dock" setting is on.
@MainActor
enum DockPresence {
    static func apply(showInDock: Bool) {
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    /// Opens the floating panel by clicking this app's menu bar item.
    static func openMenuBarPanel() {
        for window in NSApp.windows where window.className.contains("StatusBarWindow") {
            if let button = findStatusButton(in: window.contentView) {
                button.performClick(nil)
                return
            }
        }
    }

    private static func findStatusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = findStatusButton(in: subview) { return button }
        }
        return nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            DockPresence.apply(showInDock: AppSettings.load().showInDock)
        }
    }

    /// Clicking the Dock icon opens the menu bar panel (the app has no regular windows).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            DockPresence.openMenuBarPanel()
        }
        return true
    }
}
