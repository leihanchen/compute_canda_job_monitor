import SlurmMonitorCore
import SwiftUI

/// Strictly read-only Jobs tab grouping active and pending jobs by cluster with expandable details.
struct JobsTab: View {
    @EnvironmentObject private var env: AppEnvironment

    let now: Date

    @State private var expandedJobKeys: Set<String> = []

    var body: some View {
        let clusterGroups = enabledClustersWithJobs()

        VStack(alignment: .leading, spacing: 10) {
            if clusterGroups.isEmpty {
                emptyStateCard
            } else {
                ForEach(clusterGroups, id: \.cluster.config.id) { group in
                    clusterGroupCard(view: group.cluster, jobs: group.jobs)
                }
            }
        }
    }

    private var emptyStateCard: some View {
        let nonLiveCount = env.staleOrErrorEnabledClusterIDs.count
        return Card {
            VStack(alignment: .leading, spacing: 4) {
                Text("No running or pending jobs")
                    .font(.callout.weight(.medium))
                if nonLiveCount > 0 {
                    Text("\(nonLiveCount) cluster(s) are not live yet — check Clusters to log in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Active and queued Slurm jobs will appear here after refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func clusterGroupCard(view: ClusterView, jobs: [ActiveJob]) -> some View {
        let trailing: String = {
            if view.status == .stale, let fetchedAt = view.snapshot?.fetchedAt {
                return "\(jobs.count) · cached \(Dashboard.ageText(now.timeIntervalSince(fetchedAt)))"
            }
            return "\(jobs.count) job\(jobs.count == 1 ? "" : "s")"
        }()

        return Card(nil, trailing: nil) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    StatusDot(status: env.effectiveStatus(for: view), enabled: view.config.enabled)
                    Text(view.config.name)
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(trailing)
                        .font(.caption2)
                        .foregroundStyle(view.status == .stale ? .orange : .secondary)
                }

                Divider()

                ForEach(Array(jobs.enumerated()), id: \.offset) { index, job in
                    if index > 0 {
                        Divider()
                            .opacity(0.6)
                    }
                    jobRow(cluster: view.config, job: job)
                }
            }
        }
    }

    private func jobRow(cluster: ClusterConfig, job: ActiveJob) -> some View {
        let key = "\(cluster.id.uuidString)-\(job.id)"
        let isExpanded = expandedJobKeys.contains(key)

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded {
                        expandedJobKeys.remove(key)
                    } else {
                        expandedJobKeys.insert(key)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        StatePill(state: job.state)
                        Text(job.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(job.id)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }

                    HStack(spacing: 8) {
                        if job.state == .pending {
                            pendingMeta(for: job)
                        } else {
                            TimeBar(elapsed: job.elapsed, limit: job.timeLimit)
                        }

                        Spacer(minLength: 4)

                        if let resources = SlurmDisplayFormatter.resources(for: job) {
                            Text(resources)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedDetails(for: job)
            }
        }
    }

    private func pendingMeta(for job: ActiveJob) -> some View {
        let reason = job.reasonOrNodes.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(spacing: 6) {
            Text(reason.isEmpty ? "Pending" : reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(SlurmDisplayFormatter.estimatedStartText(job.estimatedStart, now: now))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
    }

    private func expandedDetails(for job: ActiveJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            detailRow("Partition", job.partition.isEmpty ? "—" : job.partition)
            detailRow("Account", job.account.isEmpty ? "—" : job.account)
            detailRow("Nodes", nodesText(for: job))
            detailRow("Submitted", SlurmDisplayFormatter.timestamp(job.submitTime))
            detailRow("Work dir", job.workDir ?? "—", selectable: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func detailRow(_ label: String, _ value: String, selectable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            if selectable {
                Text(value)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private func nodesText(for job: ActiveJob) -> String {
        let countText = job.nodes.map(String.init)
        let nodeList = job.reasonOrNodes.trimmingCharacters(in: .whitespacesAndNewlines)
        if job.state != .pending, !nodeList.isEmpty {
            if let countText {
                return "\(countText) (\(nodeList))"
            }
            return nodeList
        }
        return countText ?? "—"
    }

    private func enabledClustersWithJobs() -> [(cluster: ClusterView, jobs: [ActiveJob])] {
        env.model.clusters
            .filter(\.config.enabled)
            .compactMap { view in
                guard let active = view.snapshot?.active, !active.isEmpty else {
                    return nil
                }
                return (view, sortedJobs(active))
            }
    }

    private func sortedJobs(_ jobs: [ActiveJob]) -> [ActiveJob] {
        jobs.sorted { lhs, rhs in
            let lhsRank = stateSortRank(lhs.state)
            let rhsRank = stateSortRank(rhs.state)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private func stateSortRank(_ state: JobState) -> Int {
        switch state {
        case .running, .completing:
            return 0
        case .pending:
            return 1
        default:
            return 2
        }
    }
}
