import SwiftUI

struct BackupFailuresScreen: View {
    @Environment(SessionStore.self) private var session
    @State private var confirmConditions = false

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
                                    }
                                    NavigationLink("How to Fix") { BackupFailureRecoveryScreen(failure: failure) }
                                        .font(.subheadline)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    } header: {
                        Text("\(backup.backupFailures.count) items failed to back up")
                    } footer: {
                        Text("Resolve the cause, then retry the affected photos or videos.")
                    }
                    Section {
                        BackupFailureRetryButton(localIDs: backup.backupFailures.map(\.localIdentifier), title: "Retry Failed Items")
                    }
                }
            }
        }
        .navigationTitle("Failed Backups")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("backup-failures-list")
        .task { await session.backup?.refreshLibraryStatus() }
        .confirmationDialog("Back up now?", isPresented: $confirmConditions, titleVisibility: .visible) {
            Button("Back Up Now") { session.backup?.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let backup = session.backup { Text(backup.manualBackupApprovalMessage) }
        }
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
