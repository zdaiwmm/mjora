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
                autoSection(backup)
                statusSection(backup, showsManualActions: false)
                Section("Current Connection") {
                    LabeledContent("Connected Through", value: connectionText)
                    if let message = backup.syncHoldMessage { Text(message).foregroundStyle(.secondary) }
                }
                repeatedFailuresSection(backup)
                if !backup.activeTransfers.items.isEmpty {
                    Section {
                        ActiveBackupTransfersView(transfers: backup.activeTransfers)
                    }
                }
                Section {
                    NavigationLink { CleanupSettingsScreen() } label: {
                        Label("Clean Up Device", systemImage: "trash.slash")
                    }
                    .accessibilityIdentifier("backup-cleanup")
                    NavigationLink("Advanced Options") {
                        List {
                            ManualServerRouteSection()
                            Section {
                                Toggle("Use Cellular or Metered Wi-Fi", isOn: Binding(get: { backup.backUpOnCellular }, set: { backup.backUpOnCellular = $0 }))
                                    .accessibilityIdentifier("backup-cellular-toggle")
                            }
                            selectionSection(backup)
                            batterySection(backup)
                            statusSection(backup)
                            Section("Background Backup") {
                                BackgroundBackupControls(backup: backup) {
                                    if backup.manualBackupNeedsApproval { confirmBackgroundConditions = true }
                                    else { startBackup(backup) }
                                }
                            }
                            advancedSection(backup)
                            Section {
                                Button("Recheck Entire Library") { backup.requestFullReconciliation() }
                                    .disabled(backup.isRunning)
                            }
                        }
                        .navigationTitle("Advanced Options")
                    }
                    .accessibilityIdentifier("backup-advanced")
                }
            }
        }
        .task { await session.backup?.refreshLibraryStatus() }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - automatic backup

    private func autoSection(_ backup: BackupManager) -> some View {
        return Section {
            Toggle(isOn: Binding(
                get: { backup.autoBackup },
                set: { value in
                    backup.autoBackup = value
                    if value { reportsNextBackupFailure = true }
                }
            )) {
                Label("Back Up Automatically", systemImage: "arrow.triangle.2.circlepath.icloud")
            }
            .accessibilityIdentifier("backup-auto-toggle")

        } footer: {
            Text("New photos back up automatically when your connection and battery settings allow. iOS may pause background work; your progress is saved.")
        }
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
        } footer: {
            Text("Include screenshots in automatic backup and Back Up Now. When off, screenshots stay in your gallery and can still be selected for manual backup. The upload size limit is off by default. It applies to each request, including form data, for automatic and manual backup. For a 100 MB proxy limit, 95 MB leaves room for variation. Files over the limit show an exclusion icon and are not uploaded from this device. If a server copy is confirmed, they show the backed-up cloud. Transfers already in progress may finish.")
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
        } footer: {
            Text("Indexing and uploads pause at this battery level, including while charging. Sync This Time allows backup until the battery rises above the threshold. The metered-connection override ends when an unmetered connection is available. Transfers already handed to iOS may finish while backup is paused.")
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
            Text("More indexing workers may be faster but use more memory, battery, and iCloud bandwidth. Ordering controls which photos and videos are indexed and queued first. Your backup exclusions still apply, and new captures keep priority. Changes apply to the next pass.")
        }
    }

    // MARK: - status

    @ViewBuilder
    private func repeatedFailuresSection(_ backup: BackupManager) -> some View {
        if !backup.repeatedFailures.isEmpty {
            Section {
                ForEach(backup.repeatedFailures) { failure in
                    HStack(alignment: .top, spacing: 12) {
                        LocalPhotoImage(
                            localIdentifier: failure.localIdentifier,
                            targetPixelSize: 128,
                            allowsNetwork: false,
                            animatesLoads: false
                        )
                        .frame(width: 56, height: 56)
                        .clipShape(.rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(failureTitle(failure))
                                .font(.subheadline.weight(.semibold))
                            Text("Failed \(failure.count) times · \(failure.lastFailedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(failure.kind.explanation)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Needs Attention")
            } footer: {
                Text("These files remain on your device. Back Up Now retries them. A verified backup clears the warning; editing a file starts a new attempt count.")
            }
            .accessibilityIdentifier("backup-repeated-failures-list")
        }
    }

    private func failureTitle(_ failure: RepeatedBackupFailure) -> String {
        let type = failure.isVideo ? String(localized: "Video") : String(localized: "Photo")
        guard let capturedAt = failure.capturedAt else { return type }
        return "\(type) · \(capturedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    @ViewBuilder
    private func statusSection(_ backup: BackupManager, showsManualActions: Bool = true) -> some View {
        Section("Status") {
            if PhotoAccess.shared.canAsk {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Full photo library access is required for backup.")
                        .font(.callout)
                    Button("Allow Access") {
                        requestAccess()
                    }
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier("backup-allow-access")
                }
                .padding(.vertical, 2)
            } else if PhotoAccess.shared.isBlocked {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Full photo library access is required for backup.")
                        .font(.callout)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Open Settings", destination: url)
                            .font(.callout.weight(.semibold))
                    }
                }
                .padding(.vertical, 2)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(statusText(backup))
                    .font(.callout)
                    .accessibilityIdentifier("backup-status")
                if let message = backup.reconciliationMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("backup-reconciliation-status")
                }
                if let status = backup.libraryStatus {
                    Text(status.countText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("backup-library-count")
                    LabeledContent("Pending Backup", value: status.pendingMedia.text)
                    if status.cloudDeleted > 0 {
                        LabeledContent("Deleted in Cloud", value: status.cloudDeletedMedia.text)
                            .accessibilityIdentifier("backup-cloud-deleted-count")
                        Text("These originals stay on your device and will not upload again automatically.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if status.excluded > 0 {
                        Text(status.excluded == 1 ? String(localized: "1 screenshot excluded") : String(localized: "\(status.excluded) screenshots excluded"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("backup-excluded-count")
                    }
                }
                if case .hashing = backup.phase {
                    Text("Indexing your files to identify what's already on your server. Missing photos and videos upload after indexing and matching; new captures can back up while the older library is indexed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let fraction = progressFraction(backup.phase) {
                    ProgressView(value: fraction)
                        .tint(.indigo)
                        .accessibilityIdentifier("backup-progress")
                }
            }
            .padding(.vertical, 2)

            if case .hashing = backup.phase, backup.downloadedOriginalsFromICloud {
                Label(
                    "Some originals are downloading from iCloud, so indexing may take longer.",
                    systemImage: "icloud.and.arrow.down"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("backup-icloud-download")
            }

            if let status = backup.recentBackupStatus {
                Label(status, systemImage: "sparkles")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("backup-recent-status")
            }

            if backup.isRunning && showsManualActions {
                Button {
                    activeBackupPresented = true
                } label: {
                    Label("Active Mode", systemImage: "moon.stars")
                }
                .accessibilityIdentifier("backup-keep-awake")

                Text("Active Mode keeps your screen awake on a dark screen while Imora indexes and backs up your library. Auto-Lock resumes when the backup finishes or you leave it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Cancel", role: .destructive) {
                    backup.cancel()
                }
                .accessibilityIdentifier("backup-cancel")
            } else if !backup.isRunning && (showsManualActions || backup.requiresExplicitResume || backup.syncHoldMessage != nil) {
                let canStart = backup.canStartBackup
                Button {
                    if backup.manualBackupNeedsApproval {
                        confirmBackupConditions = true
                    } else {
                        startBackup(backup)
                    }
                } label: {
                    Label(showsManualActions ? String(localized: "Back Up Now") : String(localized: "Continue Backup"), systemImage: "icloud.and.arrow.up")
                        .foregroundStyle(canStart ? Color.accentColor : Color.secondary)
                }
                .disabled(!canStart)
                .accessibilityIdentifier("backup-start")
                // ios 26 morphs the dialog out of its source control, so it
                // sits on the row instead of the section, where it would
                // float detached.
                .confirmationDialog(
                    "Back up now?",
                    isPresented: $confirmBackupConditions,
                    titleVisibility: .visible
                ) {
                    Button("Back Up Now") {
                        startBackup(backup)
                    }
                    .accessibilityIdentifier("backup-cellular-confirm")
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(backup.manualBackupApprovalMessage)
                }
            }
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
        if backup.requiresExplicitResume {
            return String(localized: "Whole-library backup paused. Continue Backup in Background or Back Up Now resumes the saved request.")
        }
        // the run itself just goes quiet on a metered connection, so the
        // reason has to be said out loud or nothing explains the silence.
        if let message = backup.syncHoldMessage {
            return String(localized: "Not currently syncing. \(message)")
        }
        return switch backup.phase {
        case .idle:
            if let status = backup.libraryStatus {
                status.isUpToDate ? BackupLibraryStatus.upToDateText
                    : status.pending == 0 ? String(localized: "Some photos or videos use an unsupported format.") : String(localized: "Ready to index and back up.")
            } else {
                String(localized: "Checking backup status...")
            }
        case .scanning: String(localized: "Scanning library...")
        case .hashing: backup.continuedSubtitle
        case .checking: String(localized: "Matching indexed files with your server...")
        case .uploading: backup.continuedSubtitle
        case .done(let summary): doneText(summary)
        case .error(let message): String(localized: "Error: \(message)")
        case .cancelled: String(localized: "Backup cancelled.")
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
