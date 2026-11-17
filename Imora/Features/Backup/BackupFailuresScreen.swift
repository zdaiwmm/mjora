import SwiftUI

struct BackupFailuresScreen: View {
    @Environment(SessionStore.self) private var session
    @State private var confirmConditions = false
    @State private var isRefreshing = false

    var body: some View {
        List {
            if let backup = session.backup {
                if backup.backupFailures.isEmpty {
                    if case .error(let message) = backup.phase {
                        Section {
                            Text(message).foregroundStyle(.secondary)
                            Button("Back Up Now") {
                                if backup.manualBackupNeedsApproval { confirmConditions = true }
                                else { backup.start() }
                            }
                            NavigationLink("Backup Settings") { BackupScreen() }
                        }
                    } else {
                        ContentUnavailableView("No Failed Backups", systemImage: "checkmark.icloud")
                    }
                } else {
                    Section {
                        ForEach(backup.backupFailures) { failure in
                            HStack(alignment: .top, spacing: 12) {
                                LocalPhotoImage(localIdentifier: failure.localIdentifier, targetPixelSize: 128, allowsNetwork: false)
                                    .frame(width: 56, height: 64)
                                    .clipShape(.rect(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(failure.kind.title).font(.subheadline.weight(.semibold))
                                    if let capturedAt = failure.capturedAt {
                                        Text(capturedAt, format: .dateTime.year().month().day().hour().minute())
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(failure.kind.explanation).font(.footnote).foregroundStyle(.secondary)
                                    if failure.kind == .connection || failure.kind == .other {
                                        BackupFailureRetryButton(localIDs: [failure.localIdentifier], title: "Retry This Item")
                                            .disabled(isRefreshing)
                                    }
                                    NavigationLink("How to Fix") { BackupFailureRecoveryScreen(failure: failure) }
                                        .font(.subheadline)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    } header: {
                        Text("\(backup.backupFailures.count) items failed to back up")
                    }
                    Section {
                        BackupFailureRetryButton(localIDs: backup.backupFailures.map(\.localIdentifier), title: "Retry Failed Items")
                            .disabled(isRefreshing)
                    }
                }
            }
        }
        .navigationTitle("Failed Backups")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("backup-failures-list")
        .task { await session.backup?.refreshLibraryStatus() }
        .refreshable {
            guard let backup = session.backup else { return }
            if backup.isRunning { await backup.refreshLibraryStatus(); return }
            if backup.manualBackupNeedsApproval { confirmConditions = true; return }
            await retryFailedItems()
        }
        .confirmationDialog("Back up now?", isPresented: $confirmConditions, titleVisibility: .visible) {
            if session.backup?.backupFailures.isEmpty == false {
                Button("Retry Failed Items") { Task { await retryFailedItems() } }
            } else {
                Button("Back Up Now") { session.backup?.start() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let backup = session.backup { Text(backup.manualBackupApprovalMessage) }
        }
    }

    private func retryFailedItems() async {
        guard let backup = session.backup, !isRefreshing else { return }
        let identifiers = backup.backupFailures.map(\.localIdentifier)
        guard !identifiers.isEmpty else {
            if case .error = backup.phase { backup.start() }
            await backup.refreshLibraryStatus()
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let outcome = try await backup.backUp(localIdentifiers: identifiers, overridingCurrentHolds: true)
            if outcome.failed > 0, let reason = outcome.firstFailure { ErrorToastCenter.shared.show(reason) }
        } catch { ErrorToastCenter.shared.show(String(localized: "Couldn't back up"), error: error) }
        await backup.refreshLibraryStatus()
    }
}

private struct BackupFailureRecoveryScreen: View {
    @Environment(SessionStore.self) private var session
    let failure: RepeatedBackupFailure
    @State private var showAccount = false

    var body: some View {
        List {
            Section {
                Text(failure.kind.recoveryMessage)
                    .accessibilityIdentifier("backup-failure-recovery")
            }
            Section("Failure Details") {
                if let diagnostic = failure.diagnostic {
                    Text(diagnostic.stage.title).font(.subheadline.weight(.semibold))
                    Text(diagnostic.detail).monospacedDigit()
                } else {
                    Text("Exact error details were not saved for this attempt.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                BackupFailureRetryButton(localIDs: [failure.localIdentifier], title: "Check Again and Retry")
                NavigationLink("Backup Settings") { BackupScreen() }
                if failure.kind == .authorization || failure.kind == .cloudStorage {
                    Button("Account & Settings") { showAccount = true }
                }
                if PhotoAccess.shared.isBlocked, let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Manage Photo Access", destination: url)
                }
            }
        }
        .navigationTitle(failure.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAccount) { SettingsView() }
    }
}

private struct BackupFailureRetryButton: View {
    @Environment(SessionStore.self) private var session
    let localIDs: [String]
    let title: LocalizedStringKey
    @State private var isRetrying = false
    @State private var confirmConditions = false

    var body: some View {
        Button {
            if session.backup?.manualBackupNeedsApproval == true { confirmConditions = true }
            else { retry() }
        } label: {
            if isRetrying { Label("Retrying…", systemImage: "icloud.and.arrow.up") }
            else { Label(title, systemImage: "arrow.clockwise") }
        }
        .buttonStyle(.borderless)
        .disabled(isRetrying || session.backup?.isRunning == true || localIDs.isEmpty)
        .accessibilityIdentifier("backup-retry-failed")
        .confirmationDialog("Back up now?", isPresented: $confirmConditions, titleVisibility: .visible) {
            Button("Retry Failed Items") { retry() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let backup = session.backup { Text(backup.manualBackupApprovalMessage) }
        }
    }

    private func retry() {
        guard let backup = session.backup, !isRetrying else { return }
        isRetrying = true
        Task {
            defer { isRetrying = false }
            do {
                let outcome = try await backup.backUp(localIdentifiers: localIDs, overridingCurrentHolds: true)
                if outcome.failed > 0, let reason = outcome.firstFailure {
                    ErrorToastCenter.shared.show(reason)
                }
            } catch { ErrorToastCenter.shared.show(String(localized: "Couldn't back up"), error: error) }
            await backup.refreshLibraryStatus()
        }
    }
}
