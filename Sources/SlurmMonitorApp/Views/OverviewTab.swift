import SlurmMonitorCore
import SwiftUI

/// Overview tab showing cross-cluster totals, ending-soon jobs, waiting jobs, recent completions, and cluster status grid.
struct OverviewTab: View {
    @EnvironmentObject private var env: AppEnvironment

    let now: Date
    let onSelectJobsTab: () -> Void

    private static let sectionPreviewLimit = 5

    private let gridColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        let dashboard = Dashboard(clusters: env.model.clusters, now: now)
        let enabledClusters = env.model.clusters.filter(\.config.enabled)

        VStack(alignment: .leading, spacing: 10) {
            totalsCard(dashboard: dashboard)
            endingSoonCard(jobs: dashboard.endingSoon)
            waitingCard(jobs: dashboard.waiting)
            recentlyEndedCard(jobs: dashboard.recentlyEnded)
            clusterGrid(clusters: enabledClusters)
        }
    }

    private func totalsCard(dashboard: Dashboard) -> some View {
        Card {
            HStack(spacing: 12) {
                metricItem(
                    symbol: "▶",
                    symbolColor: .green,
                    value: "\(dashboard.runningCount)",
                    label: "Running"
                )
                Divider()
                    .frame(height: 22)
                metricItem(
                    symbol: "⏸",
                    symbolColor: .orange,
                    value: "\(dashboard.pendingCount)",
                    label: "Pending"
                )
                Divider()
                    .frame(height: 22)
                metricItem(
                    symbol: nil,
                    symbolColor: .blue,
                    value: "\(dashboard.gpusInUse)",
                    label: "GPUs in use"
                )
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func metricItem(
        symbol: String?,
        symbolColor: Color,
        value: String,
        label: String
    ) -> some View {
        HStack(spacing: 4) {
            if let symbol {
                Text(symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(symbolColor)
            }
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func endingSoonCard(jobs: [JobRef<ActiveJob>]) -> some View {
        let visible = Array(jobs.prefix(Self.sectionPreviewLimit))
        let overflowCount = max(0, jobs.count - visible.count)

        return Card("Ending soon") {
            if visible.isEmpty {
                emptyRow("No running jobs")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(visible, id: \.uniqueKey) { ref in
                        HStack(spacing: 8) {
                            clusterTag(ref.cluster.name)
                            Text(ref.job.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            TimeBar(elapsed: ref.job.elapsed, limit: ref.job.timeLimit)
                        }
                    }

                    if overflowCount > 0 {
                        moreInJobsButton(extraCount: overflowCount)
                    }
                }
            }
        }
    }

    private func waitingCard(jobs: [JobRef<ActiveJob>]) -> some View {
        let visible = Array(jobs.prefix(Self.sectionPreviewLimit))
        let overflowCount = max(0, jobs.count - visible.count)

        return Card("Waiting") {
            if visible.isEmpty {
                emptyRow("No pending jobs")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(visible, id: \.uniqueKey) { ref in
                        HStack(spacing: 8) {
                            clusterTag(ref.cluster.name)
                            Text(ref.job.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            Text(pendingReason(ref.job))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(SlurmDisplayFormatter.estimatedStartText(ref.job.estimatedStart, now: now))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }

                    if overflowCount > 0 {
                        moreInJobsButton(extraCount: overflowCount)
                    }
                }
            }
        }
    }

    private func recentlyEndedCard(jobs: [JobRef<EndedJob>]) -> some View {
        Card("Recently ended (last 3)") {
            if jobs.isEmpty {
                emptyRow("No recently ended jobs")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(jobs, id: \.uniqueKey) { ref in
                        let summary = SlurmDisplayFormatter.endedSummary(for: ref.job)
                        HStack(spacing: 8) {
                            clusterTag(ref.cluster.name)
                            Text(ref.job.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            Text("\(summary.symbol) \(summary.label)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(summary.color)
                                .lineLimit(1)
                            Text(SlurmDisplayFormatter.ageText(ref.job.endTime, now: now))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func clusterGrid(clusters: [ClusterView]) -> some View {
        Group {
            if clusters.isEmpty {
                Card {
                    emptyRow("All clusters are disabled — enable one in Clusters.")
                }
            } else {
                LazyVGrid(columns: gridColumns, spacing: 8) {
                    ForEach(clusters, id: \.config.id) { view in
                        clusterTile(view)
                    }
                }
            }
        }
    }

    private func clusterTile(_ view: ClusterView) -> some View {
        let status = env.effectiveStatus(for: view)
        return HStack(spacing: 6) {
            StatusDot(status: status, enabled: view.config.enabled)
            Text(view.config.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(tileDetail(for: view, effectiveStatus: status))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(status == .live ? .primary : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
    }

    private func clusterTag(_ name: String) -> some View {
        Text(name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .lineLimit(1)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func moreInJobsButton(extraCount: Int) -> some View {
        Button {
            onSelectJobsTab()
        } label: {
            Text("+\(extraCount) more in Jobs")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    private func pendingReason(_ job: ActiveJob) -> String {
        let trimmed = job.reasonOrNodes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Pending" : trimmed
    }

    private func tileDetail(for view: ClusterView, effectiveStatus: ClusterStatus) -> String {
        switch effectiveStatus {
        case .live:
            let active = view.snapshot?.active ?? []
            let running = active.filter { $0.state == .running || $0.state == .completing }.count
            let pending = active.filter { $0.state == .pending }.count
            return "\(running)▶ \(pending)⏸"
        case .stale:
            return SlurmDisplayFormatter.ageText(view.snapshot?.fetchedAt, now: now)
        case .loggingIn:
            return "logging in"
        case .error(let error):
            return SlurmDisplayFormatter.errorShortLabel(for: error)
        }
    }
}

private extension JobRef where J: Identifiable, J.ID == String {
    var uniqueKey: String {
        "\(cluster.id.uuidString)-\(job.id)"
    }
}
