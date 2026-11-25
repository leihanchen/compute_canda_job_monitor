import SlurmMonitorCore
import SwiftUI

@main
struct SlurmMonitorApp: App {
    var body: some Scene {
        MenuBarExtra("Slurm", systemImage: "server.rack") {
            Text("Loading")
        }
    }
}
