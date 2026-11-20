import Foundation
import SwiftUI

struct BackupScreen: View {
    @Environment(SessionStore.self) private var session

    @State private var confirmBackupConditions = false
    @State private var confirmBackgroundConditions = false
    @State private var reportsNextBackupFailure = false
    @State private var activeBackupPresented = false

    var body: some View {
        List {
            if let backup = session.backup {
                statusSection(backup)
                if backup.hasBackupFailure {
                    Section {
                        NavigationLink { BackupFailuresScreen() } label: {
                            Label("Review Failed Items", systemImage: "exclamationmark.icloud")
                        }
                        .accessibilityIdentifier("backup-review-failures")
                    }
                }
                Section("Backup Settings") {
                    Toggle("Back Up Automatically", isOn: Binding(
                        get: { backup.autoBackup },
                        set: { value in
                            backup.autoBackup = value
                            if value { reportsNextBackupFailure = true }
                        }
                    ))
                    .accessibilityIdentifier("backup-auto-toggle")
                    NavigationLink("Backup Content") {
                        List { selectionSection(backup) }
                            .navigationTitle("Backup Content")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    .accessibilityIdentifier("backup-content")
                    NavigationLink("Backup Conditions") {
                        conditionsScreen(backup)
                    }
                    .accessibilityIdentifier("backup-conditions")
                }
                Section("Manage Backup") {
                    if !backup.isRunning {
                        NavigationLink("Transfer Details") { transfersScreen(backup) }
                            .accessibilityIdentifier("backup-transfers")
                    }
                    NavigationLink { CleanupSettingsScreen() } label: {
                        Label("Clean Up Device", systemImage: "trash.slash")
                    }
                    .accessibilityIdentifier("backup-cleanup")
                    NavigationLink("Advanced & Repair") {
                        List {
                            advancedSection(backup)
                            Section {
                                Button("Recheck Entire Library") { backup.requestFullReconciliation() }
                                    .disabled(backup.isRunning)
                                    .accessibilityIdentifier("backup-recheck-library")
                            }
                        }
                        .navigationTitle("Advanced & Repair")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                    .accessibilityIdentifier("backup-advanced")
                }
                Section {
                    NavigationLink { LocalNetworkScreen() } label: {
                        LabeledContent("Current Connection", value: connectionText)
                    }
                    .accessibilityIdentifier("backup-connection")
                }
            }
        }
        .task { await session.backup?.refreshLibraryStatus() }
        .navigationTitle("Photo Backup")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.accentColor)
        .confirmationDialog("Back up now?", isPresented: $confirmBackgroundConditions, titleVisibility: .visible) {
            if let backup = session.backup {
                Button("Continue Backup in Background") { startBackup(backup) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let backup = session.backup { Text(backup.manualBackupApprovalMessage) }
        }
        .fullScreenCover(isPresented: $activeBackupPresented) {
            if let backup = session.backup {
                ActiveBackupScreen(backup: backup)
            }
        }
        .onChange(of: session.backup?.phase) { _, phase in
            guard reportsNextBackupFailure, let phase else { return }
            switch phase {
            case .error(let message):
                reportsNextBackupFailure = false
                ErrorToastCenter.shared.show(String(localized: "Couldn't complete the backup. \(message)"))
            case .done(let summary):
                reportsNextBackupFailure = false
                if summary.failed > 0 {
                    let detail = session.backup?.lastFailure ?? String(localized: "Some photos or videos were not uploaded.")
                    ErrorToastCenter.shared.show(String(localized: "Some photos or videos couldn't be backed up. \(detail)"))
                }
            case .cancelled:
                // the ask died with the run, or the next automatic one
                // would toast for a failure nobody started.
                reportsNextBackupFailure = false
            default:
                break
            }
        }
    }

    private func conditionsScreen(_ backup: BackupManager) -> some View {
        List {
            Section("Network") {
                Toggle("Use Cellular or Metered Wi-Fi", isOn: Binding(
                    get: { backup.backUpOnCellular }, set: { backup.backUpOnCellular = $0 }
                ))
                .accessibilityIdentifier("backup-cellular-toggle")
            }
            batterySection(backup)
            Section {
                NavigationLink("Background Backup") {
                    List {
                        Section {
                            BackgroundBackupControls(backup: backup) {
                                requestBackgroundBackup(backup)
                            }
                        }
                    }
                    .navigationTitle("Background Backup")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .accessibilityIdentifier("backup-background")
            }
        }
        .navigationTitle("Backup Conditions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func transfersScreen(_ backup: BackupManager) -> some View {
        List {
            Section {
                Text(statusText(backup)).accessibilityIdentifier("backup-status")
                if let status = backup.libraryStatus {
                    Text(status.countText).foregroundStyle(.secondary)
                    historicalBackupRow(status)
                }
                if let fraction = progressFraction(backup.phase) {
                    ProgressView(value: fraction).accessibilityIdentifier("backup-progress")
                }
            }
            if !backup.activeTransfers.items.isEmpty {
                Section { ActiveBackupTransfersView(transfers: backup.activeTransfers) }
            }
            if backup.isRunning {
                Section {
                    Button("Keep Screen Awake", systemImage: "moon") { activeBackupPresented = true }
                        .accessibilityIdentifier("backup-keep-awake")
                    BackgroundBackupControls(backup: backup) { requestBackgroundBackup(backup) }
                    Button("Stop This Backup", role: .destructive) { backup.cancel() }
                        .accessibilityIdentifier("backup-cancel")
                }
            }
        }
        .navigationTitle("Transfer Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func requestBackgroundBackup(_ backup: BackupManager) {
        if backup.manualBackupNeedsApproval { confirmBackgroundConditions = true }
        else { startBackup(backup) }
    }

    private func selectionSection(_ backup: BackupManager) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { !backup.excludeScreenshots },
                set: { backup.excludeScreenshots = !$0 }
            )) {
                Label("Include Screenshots", systemImage: "camera.viewfinder")
            }
            .accessibilityIdentifier("backup-include-screenshots-toggle")

            Toggle(isOn: Binding(
                get: { backup.maxUploadSizeMB != nil },
                set: { backup.maxUploadSizeMB = $0 ? (backup.maxUploadSizeMB ?? 95) : nil }
            )) {
                Label("Limit Upload Size", systemImage: "arrow.up.doc")
            }
            .accessibilityIdentifier("backup-upload-size-limit-toggle")

            if backup.maxUploadSizeMB != nil {
                HStack {
                    TextField("Maximum size", value: Binding(
                        get: { backup.maxUploadSizeMB ?? 95 },
                        set: { backup.maxUploadSizeMB = (1...100_000).contains($0) ? $0 : 95 }
                    ), format: .number)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("backup-upload-size-limit-mb")
                    Text("MB")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Backup Selection and Limits")
        }
    }

    private func batterySection(_ backup: BackupManager) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { backup.pauseOnLowBattery },
                set: { backup.pauseOnLowBattery = $0 }
            )) {
                Label("Pause on Low Battery", systemImage: "battery.25percent")
            }
            .accessibilityIdentifier("backup-low-battery-toggle")
            if backup.pauseOnLowBattery {
                Stepper(value: Binding(
                    get: { backup.batteryThreshold },
                    set: { backup.batteryThreshold = $0 }
                ), in: 1...50) {
                    Text("Pause at \(backup.batteryThreshold)% or Less")
                }
                .accessibilityIdentifier("backup-battery-threshold")
            }
        } header: {
            Text("Battery")
        }
    }

    private func advancedSection(_ backup: BackupManager) -> some View {
        Section {
            Picker("Files Indexed at Once", selection: Binding(
                get: { backup.hashWorkers },
                set: { backup.hashWorkers = $0 }
            )) {
                ForEach(BackupManager.hashWorkerOptions, id: \.self) { workers in
                    Text("\(workers)").tag(workers)
                }
            }
            .accessibilityIdentifier("backup-hash-workers")

            Picker("Backup Order", selection: Binding(
                get: { backup.dateOrder }, set: { backup.dateOrder = $0 }
            )) {
                ForEach(BackupDateOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .accessibilityIdentifier("backup-date-order")

            Picker("Media Priority", selection: Binding(
                get: { backup.mediaPriority }, set: { backup.mediaPriority = $0 }
            )) {
                ForEach(BackupMediaPriority.allCases) { priority in
                    Text(priority.title).tag(priority)
                }
            }
            .accessibilityIdentifier("backup-media-priority")
        } header: {
            Text("Advanced")
        } footer: {
            Text("The library indexing stage prepares up to three items at a time. Background activity, Low Power Mode and temperature may reduce this limit.")
        }
    }

    @ViewBuilder
    private func statusSection(_ backup: BackupManager) -> some View {
        Section {
            Text(statusText(backup))
                .accessibilityIdentifier("backup-status")
            if let status = backup.libraryStatus {
                Text(status.countText)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("backup-library-count")
                if status.deviceLibraryMedia.total > 0 {
                    LabeledContent("On This Device", value: status.deviceLibraryMedia.text)
                        .accessibilityIdentifier("backup-device-library-count")
                }
                historicalBackupRow(status)
                LabeledContent("Pending Backup", value: status.pendingMedia.text)
                if status.unsupported > 0 {
                    LabeledContent("Unsupported Formats", value: status.unsupportedMedia.text)
                }
                if status.cloudDeleted > 0 {
                    LabeledContent("Deleted in Cloud", value: status.cloudDeletedMedia.text)
                        .accessibilityIdentifier("backup-cloud-deleted-count")
                }
                if status.excluded > 0 {
                    LabeledContent("Excluded Screenshots", value: status.excludedMedia.text)
                        .accessibilityIdentifier("backup-excluded-count")
                }
                if backup.isConnectionOffline, let observed = status.lastSuccessfulCloudSync {
                    LabeledContent("Last Successful Sync", value: observed.formatted(date: .abbreviated, time: .shortened))
                        .accessibilityIdentifier("backup-history-as-of")
                }
            }
            if let fraction = progressFraction(backup.phase) {
                ProgressView(value: fraction)
                    .accessibilityIdentifier("backup-progress")
            }
            if PhotoAccess.shared.canAsk {
                Button("Allow Photo Access") { requestAccess() }
                    .accessibilityIdentifier("backup-allow-access")
            } else if PhotoAccess.shared.isBlocked {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: url)
                }
            } else {
                if backup.isRunning {
                    NavigationLink("Transfer Details") { transfersScreen(backup) }
                        .accessibilityIdentifier("backup-transfers")
                } else {
                    Button(backup.requiresExplicitResume ? "Continue Backup" : "Back Up Now") {
                        if backup.manualBackupNeedsApproval { confirmBackupConditions = true }
                        else { startBackup(backup) }
                    }
                    .disabled(!backup.canStartBackup)
                    .accessibilityIdentifier("backup-start")
                    .confirmationDialog("Back up now?", isPresented: $confirmBackupConditions, titleVisibility: .visible) {
                        Button("Back Up Now") { startBackup(backup) }
                            .accessibilityIdentifier("backup-cellular-confirm")
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(backup.manualBackupApprovalMessage)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func historicalBackupRow(_ status: BackupLibraryStatus) -> some View {
        if status.historicalOnlyMedia.total > 0 {
            LabeledContent("Previously Backed Up (Unconfirmed)", value: status.historicalOnlyMedia.text)
                .accessibilityIdentifier("backup-historical-count")
        }
    }

    private var connectionText: String {
        if session.backup?.isConnectionOffline == true { return String(localized: "Offline") }
        return switch LocalServerRouter.shared.status {
        case .local: String(localized: "Local Network")
        case .held: String(localized: "Local Connection Paused")
        case .checking: String(localized: "Checking...")
        case .off, .external: String(localized: "External Address")
        }
    }

    private func requestAccess() {
        Task {
            guard await PhotoLibraryService.requestFullAccess() else { return }
            await session.adoptPhotoAccess()
        }
    }

    /// hands the run to the scheduler when it will take it, so the progress
    /// indicator survives leaving the app; otherwise backs up in app as before.
    private func startBackup(_ backup: BackupManager) {
        reportsNextBackupFailure = true
        Task {
            let accepted = await ContinuedProcessing.backup.submit(
                title: String(localized: "Backing up"),
                subtitle: String(localized: "Indexing your library...")
            )
            if !accepted, ContinuedProcessing.backup.canFallbackToForeground(for: backup) { backup.start() }
        }
    }

    private func statusText(_ backup: BackupManager) -> String {
        if PhotoAccess.shared.isBlocked || PhotoAccess.shared.canAsk {
            return String(localized: "Photo Access Required")
        }
        if backup.isConnectionOffline { return String(localized: "Offline") }
        if backup.requiresExplicitResume {
            return String(localized: "Backup Paused")
        }
        if let message = backup.syncHoldMessage {
            return message
        }
        return switch backup.phase {
        case .idle:
            if let status = backup.libraryStatus {
                status.isUpToDate ? BackupLibraryStatus.upToDateText
                    : status.pending == 0 ? String(localized: "Some photos or videos use an unsupported format.") : String(localized: "Ready to Back Up")
            } else {
                String(localized: "Checking backup status...")
            }
        case .scanning: String(localized: "Scanning library...")
        case .hashing: backup.continuedSubtitle
        case .checking: String(localized: "Matching indexed files with your server...")
        case .uploading: backup.continuedSubtitle
        case .done(let summary): doneText(summary)
        case .error(let message): String(localized: "Error: \(message)")
        case .cancelled: String(localized: "Backup Stopped")
        }
    }

    private func doneText(_ summary: BackupSummary) -> String {
        var text = session.backup?.libraryStatus?.completionText(summary) ?? String(localized: "Backup check complete.")
        if summary.failed > 0, let failure = session.backup?.lastFailure {
            text += " (\(failure))"
        }
        return text
    }

    private func progressFraction(_ phase: BackupPhase) -> Double? {
        switch phase {
        case .hashing(let done, let total), .uploading(let done, let total):
            total > 0 ? Double(done) / Double(total) : nil
        default:
            nil
        }
    }

}
