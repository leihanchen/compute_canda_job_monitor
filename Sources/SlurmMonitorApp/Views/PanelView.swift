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
    case login

    var id: String {
        switch self {
        case .addCluster:
            return "addCluster"
        case .login:
            return "login"
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

                if env.model.clusters.isEmpty || env.isCompletingOnboarding {
                    WelcomeView(isSheet: false)
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
        .sheet(item: activeSheetBinding, onDismiss: {
            env.handleSheetDismissed()
        }) { sheet in
            sheetContent(for: sheet)
                .environmentObject(env)
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
                .disabled(env.isRefreshing)
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
                if env.activeLoginState != nil {
                    return .login
                }
                return nil
            },
            set: { newValue in
                if newValue == nil {
                    if env.isAddingCluster {
                        env.isAddingCluster = false
                    } else if env.activeLoginState != nil {
                        env.cancelLogin()
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func sheetContent(for sheet: PanelSheet) -> some View {
        switch sheet {
        case .addCluster:
            WelcomeView(isSheet: true)

        case .login:
            if let state = env.activeLoginState {
                LoginSheet(state: state)
            } else {
                EmptyView()
            }
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
