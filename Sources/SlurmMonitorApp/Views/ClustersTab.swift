import SlurmMonitorCore
import SwiftUI

/// Clusters management tab displaying connection state, errors, methods, and edit/remove/login actions.
struct ClustersTab: View {
    @EnvironmentObject private var env: AppEnvironment

    let now: Date

    @State private var editingCluster: ClusterConfig?
    @State private var actionError: String?

    var body: some View {
        let staleIDs = env.staleOrErrorEnabledClusterIDs

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    env.isAddingCluster = true
                } label: {
                    Label("Add cluster", systemImage: "plus")
                }
                .controlSize(.small)

                Spacer(minLength: 4)

                Button("Log in to stale clusters") {
                    env.login(staleIDs)
                }
                .controlSize(.small)
                .disabled(staleIDs.isEmpty)
            }

            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ForEach(env.model.clusters, id: \.config.id) { view in
                clusterCard(view)
            }
        }
        .sheet(item: $editingCluster) { cluster in
            EditClusterSheet(cluster: cluster) { updated in
                try await applyEdit(updated)
            }
        }
    }

    private func clusterCard(_ view: ClusterView) -> some View {
        let activeError = resolvedError(for: view)
        let lastSuccessText: String = {
            if let fetchedAt = view.snapshot?.fetchedAt {
                return "Last success \(Dashboard.ageText(now.timeIntervalSince(fetchedAt)))"
            }
            return "Never synced"
        }()

        return Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    StatusDot(status: view.status, enabled: view.config.enabled)
                    Text(view.config.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(view.config.sshTarget)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(SlurmDisplayFormatter.statusSummary(for: view, now: now))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(statusTextColor(for: view))
                }

                if let activeError {
                    Label(activeError.hint, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 6) {
                    if view.config.methods.contains(.sharedSSH) || view.methodInUse == .sharedSSH {
                        methodBadge("via shared connection", disabled: false)
                    }
                    methodBadge("via robot (coming soon)", disabled: true)
                    Spacer(minLength: 4)
                }

                HStack(spacing: 8) {
                    Text(lastSuccessText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)

                    Button("Log in") {
                        env.login([view.config.id])
                    }
                    .controlSize(.small)
                    .disabled(!view.config.enabled || view.status == .loggingIn)

                    Button("Edit") {
                        editingCluster = view.config
                    }
                    .controlSize(.small)

                    Button("Remove", role: .destructive) {
                        removeCluster(id: view.config.id)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func methodBadge(_ title: String, disabled: Bool) -> some View {
        Text(title)
            .font(.caption2)
            .foregroundStyle(disabled ? .tertiary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(disabled ? 0.03 : 0.06))
            )
    }

    private func resolvedError(for view: ClusterView) -> ClusterError? {
        if let recorded = env.model.lastError[view.config.id] {
            return recorded
        }
        if case .error(let error) = view.status {
            return error
        }
        return nil
    }

    private func statusTextColor(for view: ClusterView) -> Color {
        guard view.config.enabled else { return .secondary }
        switch view.status {
        case .live:
            return .green
        case .stale, .loggingIn:
            return .orange
        case .error:
            return .secondary
        }
    }

    private func applyEdit(_ updated: ClusterConfig) async throws {
        var configs = env.model.clusters.map(\.config)
        if let index = configs.firstIndex(where: { $0.id == updated.id }) {
            configs[index] = updated
        }
        try await env.saveClusters(configs, refreshTargetID: updated.enabled ? updated.id : nil)
        actionError = nil
    }

    private func removeCluster(id: UUID) {
        let remaining = env.model.clusters.map(\.config).filter { $0.id != id }
        Task {
            do {
                try await env.saveClusters(remaining)
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

private struct EditClusterSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let original: ClusterConfig
    private let onSave: (ClusterConfig) async throws -> Void

    @State private var name: String
    @State private var host: String
    @State private var username: String
    @State private var sshAlias: String
    @State private var identityFile: String
    @State private var enabled: Bool
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        cluster: ClusterConfig,
        onSave: @escaping (ClusterConfig) async throws -> Void
    ) {
        self.original = cluster
        self.onSave = onSave
        _name = State(initialValue: cluster.name)
        _host = State(initialValue: cluster.host)
        _username = State(initialValue: cluster.username)
        _sshAlias = State(initialValue: cluster.sshAlias ?? "")
        _identityFile = State(initialValue: cluster.identityFile ?? "")
        _enabled = State(initialValue: cluster.enabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit cluster")
                .font(.headline)

            Form {
                TextField("Name", text: $name)
                TextField("Host", text: $host)
                TextField("Username", text: $username)
                TextField("SSH alias (optional)", text: $sshAlias)
                TextField("Identity file (optional)", text: $identityFile)
                Toggle("Enabled", isOn: $enabled)
            }
            .formStyle(.grouped)

            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveChanges()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isSaving)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveChanges() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlias = sshAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIdentity = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)

        let updated = ClusterConfig(
            id: original.id,
            name: trimmedName,
            host: trimmedHost,
            username: trimmedUser,
            sshAlias: trimmedAlias.isEmpty ? nil : trimmedAlias,
            identityFile: trimmedIdentity.isEmpty ? nil : trimmedIdentity,
            enabled: enabled,
            methods: original.methods,
            requiresKey: original.requiresKey
        )

        isSaving = true
        saveError = nil
        Task {
            do {
                try await onSave(updated)
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }
}
