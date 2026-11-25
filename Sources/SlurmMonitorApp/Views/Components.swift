import SlurmMonitorCore
import SwiftUI

/// Rounded Zest-style card container supporting both Light and Dark appearances.
struct Card<Content: View>: View {
    let title: String?
    let trailing: String?
    @ViewBuilder let content: () -> Content

    init(
        _ title: String? = nil,
        trailing: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let title {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let trailing {
                        Text(trailing)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
    }
}

/// Compact status dot reflecting live (`●`), stale (`◐`), logging-in, or disconnected (`○`) cluster state.
struct StatusDot: View {
    let status: ClusterStatus
    var enabled: Bool = true

    var body: some View {
        Group {
            if !enabled {
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
            } else {
                switch status {
                case .live:
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.green)
                case .stale:
                    Image(systemName: "circle.lefthalf.filled")
                        .foregroundStyle(.orange)
                case .loggingIn:
                    ProgressView()
                        .controlSize(.mini)
                case .error(let error):
                    Image(systemName: "circle")
                        .foregroundStyle(errorColor(for: error))
                }
            }
        }
        .font(.system(size: 9, weight: .semibold))
        .frame(width: 11, height: 11)
        .accessibilityLabel(accessibilityText)
    }

    private func errorColor(for error: ClusterError) -> Color {
        switch error {
        case .needsLogin:
            return .secondary
        case .needsSSHKey, .mfaFailed, .unreachable:
            return .orange
        case .noAccess, .slurmFailed:
            return .red
        }
    }

    private var accessibilityText: String {
        guard enabled else { return "Disabled" }
        switch status {
        case .live:
            return "Live"
        case .stale:
            return "Stale"
        case .loggingIn:
            return "Logging in"
        case .error(let error):
            return SlurmDisplayFormatter.errorShortLabel(for: error)
        }
    }
}

/// Coloured rounded badge representing a `JobState`.
struct StatePill: View {
    let state: JobState

    var body: some View {
        Text(state.shortBadgeLabel)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.15))
            )
    }

    private var tint: Color {
        switch state {
        case .running, .completed:
            return .green
        case .completing:
            return .teal
        case .pending, .timeout:
            return .orange
        case .failed, .outOfMemory:
            return .red
        case .cancelled, .other:
            return .secondary
        }
    }
}

/// Horizontal elapsed-versus-limit bar with compact time labels.
struct TimeBar: View {
    let elapsed: TimeInterval?
    let limit: TimeInterval?

    var body: some View {
        HStack(spacing: 6) {
            if let ratio = progressRatio {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.10))
                        Capsule(style: .continuous)
                            .fill(barColor(for: ratio))
                            .frame(width: max(2, proxy.size.width * ratio))
                    }
                }
                .frame(width: 58, height: 5)
            }

            Text(timeText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var progressRatio: Double? {
        guard let elapsed, let limit, limit > 0 else { return nil }
        return min(1.0, max(0.0, elapsed / limit))
    }

    private var timeText: String {
        switch (elapsed, limit) {
        case let (e?, l?):
            return "\(SlurmDisplayFormatter.compactDuration(e))/\(SlurmDisplayFormatter.compactDuration(l))"
        case let (e?, nil):
            return "\(SlurmDisplayFormatter.compactDuration(e))/—"
        case let (nil, l?):
            return "—/\(SlurmDisplayFormatter.compactDuration(l))"
        case (nil, nil):
            return "—"
        }
    }

    private func barColor(for ratio: Double) -> Color {
        if ratio >= 0.95 { return .red }
        if ratio >= 0.80 { return .orange }
        return .blue
    }
}

/// Shared formatting helpers for Slurm durations, timestamps, resources, and cluster status text.
enum SlurmDisplayFormatter {
    static func compactDuration(_ seconds: TimeInterval) -> String {
        let clamped = seconds.isFinite ? max(0, Int(seconds)) : 0
        if clamped < 60 {
            return "\(clamped)s"
        }
        if clamped < 3_600 {
            return "\(clamped / 60)m"
        }
        if clamped <= 86_400 {
            let hours = clamped / 3_600
            let mins = (clamped % 3_600) / 60
            if hours < 10 && mins > 0 {
                return "\(hours)h\(mins)m"
            }
            return "\(hours)h"
        }
        let days = clamped / 86_400
        let remHours = (clamped % 86_400) / 3_600
        return remHours > 0 ? "\(days)d\(remHours)h" : "\(days)d"
    }

    static func estimatedStartText(_ date: Date?, now: Date) -> String {
        guard let date else { return "~starts —" }
        let delta = date.timeIntervalSince(now)
        if delta <= 0 {
            return "~starts soon"
        }
        if delta < 60 {
            return "~starts <1m"
        }
        return "~starts \(compactDuration(delta))"
    }

    static func ageText(_ date: Date?, now: Date) -> String {
        guard let date else { return "—" }
        return Dashboard.ageText(now.timeIntervalSince(date))
    }

    static func timestamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func resources(for job: ActiveJob) -> String? {
        var parts: [String] = []
        if let gpus = job.gpus, gpus > 0 {
            parts.append("\(gpus)×GPU")
        }
        if let cpus = job.cpus {
            parts.append("\(cpus) CPU")
        }
        if let memory = job.memory, !memory.isEmpty {
            parts.append(memory)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func endedSummary(for job: EndedJob) -> (symbol: String, label: String, color: Color) {
        switch job.state {
        case .completed:
            return ("✓", "Completed", .green)
        case .failed:
            let code = formattedExitCode(job.exitCode)
            return ("✗", code.isEmpty ? "Failed" : "Failed (\(code))", .red)
        case .timeout:
            return ("✗", "Timeout", .orange)
        case .outOfMemory:
            return ("✗", "Out of memory", .red)
        case .cancelled:
            return ("✗", "Cancelled", .secondary)
        case .running, .pending, .completing, .other:
            return ("•", job.state.displayLabel, .secondary)
        }
    }

    static func errorShortLabel(for error: ClusterError) -> String {
        switch error {
        case .needsLogin:
            return "needs login"
        case .needsSSHKey:
            return "needs SSH key"
        case .noAccess:
            return "no access"
        case .unreachable:
            return "unreachable"
        case .mfaFailed:
            return "MFA failed"
        case .slurmFailed:
            return "Slurm failed"
        }
    }

    static func statusSummary(for view: ClusterView, now: Date) -> String {
        guard view.config.enabled else { return "disabled" }
        switch view.status {
        case .live:
            return "live"
        case .stale:
            if let fetchedAt = view.snapshot?.fetchedAt {
                return "stale · \(Dashboard.ageText(now.timeIntervalSince(fetchedAt)))"
            }
            return "stale"
        case .loggingIn:
            return "logging in…"
        case .error(let error):
            return errorShortLabel(for: error)
        }
    }

    private static func formattedExitCode(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, parts[1] == "0" {
            return String(parts[0])
        }
        return trimmed
    }
}

extension JobState {
    var displayLabel: String {
        switch self {
        case .running:
            return "Running"
        case .pending:
            return "Pending"
        case .completing:
            return "Completing"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .timeout:
            return "Timeout"
        case .outOfMemory:
            return "Out of memory"
        case .cancelled:
            return "Cancelled"
        case .other:
            return "Other"
        }
    }

    var shortBadgeLabel: String {
        switch self {
        case .running:
            return "RUN"
        case .pending:
            return "PEND"
        case .completing:
            return "FIN"
        case .completed:
            return "DONE"
        case .failed:
            return "FAIL"
        case .timeout:
            return "TIME"
        case .outOfMemory:
            return "OOM"
        case .cancelled:
            return "CANC"
        case .other:
            return "OTHER"
        }
    }
}
