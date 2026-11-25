import AppKit
import SlurmMonitorCore
import SwiftUI

/// Clusters management tab displaying connection state, errors, methods, and edit/remove/login actions.
struct ClustersTab: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.openURL) private var openURL

    let now: Date

    @State private var editingCluster: ClusterConfig?
    @State private var actionError: String?

    private static let ccdbKeysURL = URL(string: "https://ccdb.alliancecan.ca/ssh_authorized_keys")!
    private static let ccdbPortalURL = URL(string: "https://ccdb.alliancecan.ca/")!

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
            .environmentObject(env)
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

                    if view.config.requiresKey, activeError == .needsSSHKey || activeError == .noAccess {
                        HStack(spacing: 8) {
                            Text("Trillium also requires access to be requested in CCDB")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button("Open CCDB") {
                                let url = activeError == .needsSSHKey ? Self.ccdbKeysURL : Self.ccdbPortalURL
                                openURL(url)
                            }
                            .controlSize(.mini)
                        }
                    }
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
        guard view.status != .live else { return nil }
        if let loginError = env.loginErrors[view.config.id] {
            return loginError
        }
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
    @EnvironmentObject private var env: AppEnvironment

    private let original: ClusterConfig
    private let onSave: (ClusterConfig) async throws -> Void

    @State private var name: String
    @State private var host: String
    @State private var username: String
    @State private var sshAlias: String
    @State private var identityFile: String
    @State private var enabled: Bool
    @State private var resolvedControlPath = ""
    @State private var socketFromUserConfig = false
    @State private var didCopySnippet = false
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

            snippetCard

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
        .frame(width: 400)
        .onAppear {
            if resolvedControlPath.isEmpty {
                resolvedControlPath = env.immediateControlPath(for: draftCluster)
            }
        }
        .task(id: snippetResolutionKey) {
            didCopySnippet = false
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let info = await env.resolvedControlPathInfo(for: draftCluster)
            guard !Task.isCancelled else { return }
            resolvedControlPath = info.controlPath
            socketFromUserConfig = info.fromUserConfig
        }
    }

    private var snippetCard: some View {
        let controlPath = resolvedControlPath.isEmpty
            ? env.immediateControlPath(for: draftCluster)
            : resolvedControlPath
        let snippet = env.sshReuseSnippet(for: draftCluster, controlPath: controlPath)

        return Card("Terminal SSH reuse snippet") {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    socketFromUserConfig
                        ? "Matches the ControlPath already configured in ~/.ssh/config."
                        : "Optional ~/.ssh/config block so Terminal shares this connection. The app never writes ~/.ssh/config."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text(snippet)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )

                HStack {
                    Spacer()
                    Button(didCopySnippet ? "Copied" : "Copy snippet") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snippet, forType: .string)
                        didCopySnippet = true
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var snippetResolutionKey: String {
        "\(name)|\(host)|\(username)|\(sshAlias)"
    }

    private var draftCluster: ClusterConfig {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlias = sshAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIdentity = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)

        return ClusterConfig(
            id: original.id,
            name: trimmedName.isEmpty ? original.name : trimmedName,
            host: trimmedHost.isEmpty ? original.host : trimmedHost,
            username: trimmedUser.isEmpty ? original.username : trimmedUser,
            sshAlias: trimmedAlias.isEmpty ? nil : trimmedAlias,
            identityFile: trimmedIdentity.isEmpty ? nil : trimmedIdentity,
            enabled: enabled,
            methods: original.methods,
            requiresKey: original.requiresKey
        )
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveChanges() {
        let updated = draftCluster

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
