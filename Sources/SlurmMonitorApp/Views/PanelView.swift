import AppKit
import SlurmMonitorCore
import SwiftUI

private enum PanelTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case jobs = "Jobs"
    case clusters = "Clusters"

    var id: String { rawValue }
}

private enum PanelSheet: Identifiable {
    case addCluster
    case loginQueue([UUID])

    var id: String {
        switch self {
        case .addCluster:
            return "addCluster"
        case .loginQueue(let ids):
            return "login-\(ids.map(\.uuidString).joined(separator: "-"))"
        }
    }
}

/// Floating menu-bar panel hosting Overview, Jobs, and Clusters tabs plus settings and quit controls.
struct PanelView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var selectedTab: PanelTab = .overview
    @State private var showingSettings = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let dashboard = Dashboard(clusters: env.model.clusters, now: now)

            VStack(alignment: .leading, spacing: 10) {
                header(dashboard: dashboard, now: now)

                if env.model.clusters.isEmpty {
                    emptyWelcomePlaceholder
                } else {
                    Picker("Section", selection: $selectedTab) {
                        ForEach(PanelTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    ScrollView {
                        tabContent(now: now)
                            .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 460)
                }

                Divider()
                footer
            }
            .padding(12)
            .frame(width: 380)
        }
        .onAppear {
            Task {
                await env.refreshAll(.panelOpened)
            }
        }
        .sheet(item: activeSheetBinding) { sheet in
            sheetContent(for: sheet)
        }
    }

    private func header(dashboard: Dashboard, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("Slurm Jobs · \(env.displayUsername)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    Circle()
                        .fill(liveCountColor(dashboard: dashboard))
                        .frame(width: 7, height: 7)
                    Text("\(dashboard.liveCount)/\(dashboard.enabledCount) live")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Text(updatedStatusText(now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                Button {
                    Task {
                        await env.refreshAll(.manual)
                    }
                } label: {
                    if env.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.borderless)
                .help("Refresh all clusters now")
                .accessibilityLabel("Refresh all clusters")
            }
        }
    }

    @ViewBuilder
    private func tabContent(now: Date) -> some View {
        switch selectedTab {
        case .overview:
            OverviewTab(now: now) {
                selectedTab = .jobs
            }
        case .jobs:
            JobsTab(now: now)
        case .clusters:
            ClustersTab(now: now)
        }
    }

    private var emptyWelcomePlaceholder: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add your clusters")
                    .font(.title3.weight(.semibold))
                Text("No Slurm clusters configured yet. Add Alliance or custom clusters to monitor running and pending jobs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Add clusters") {
                        env.isAddingCluster = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()

            Button {
                showingSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Settings")
            .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                SettingsView()
                    .environmentObject(env)
            }

            Button {
                env.onStateChange?()
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .help("Quit Slurm Monitor")
            .accessibilityLabel("Quit")
        }
    }

    private var activeSheetBinding: Binding<PanelSheet?> {
        Binding(
            get: {
                if env.isAddingCluster {
                    return .addCluster
                }
                if !env.loginQueue.isEmpty {
                    return .loginQueue(env.loginQueue)
                }
                return nil
            },
            set: { newValue in
                if newValue == nil {
                    env.isAddingCluster = false
                    env.cancelLogin()
                }
            }
        )
    }

    @ViewBuilder
    private func sheetContent(for sheet: PanelSheet) -> some View {
        switch sheet {
        case .addCluster:
            VStack(alignment: .leading, spacing: 12) {
                Text("Add your clusters")
                    .font(.headline)
                Text("Welcome setup and cluster import will be connected here in the onboarding flow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Close") {
                        env.isAddingCluster = false
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(16)
            .frame(width: 320)

        case .loginQueue(let ids):
            let names = ids.compactMap { id in
                env.model.clusters.first(where: { $0.config.id == id })?.config.name
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Cluster login")
                    .font(.headline)
                Text("Interactive MFA login sheet for \(names.joined(separator: ", ")) will be attached here in the login flow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Close") {
                        env.cancelLogin()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(16)
            .frame(width: 320)
        }
    }

    private func liveCountColor(dashboard: Dashboard) -> Color {
        if dashboard.enabledCount == 0 || dashboard.liveCount == 0 {
            return dashboard.hasStale ? .orange : .secondary
        }
        if dashboard.liveCount == dashboard.enabledCount {
            return .green
        }
        return .orange
    }

    private func updatedStatusText(now: Date) -> String {
        guard let latest = env.latestSnapshotDate else {
            return "Updated —"
        }
        return "Updated \(Dashboard.ageText(now.timeIntervalSince(latest)))"
    }
}
