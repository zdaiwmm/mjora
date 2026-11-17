import SwiftUI

/// a foreground lane for a large initial backup. keeping this deliberately
/// explicit mirrors the contract of Photos-style active upload modes: the app
/// can prevent idle sleep while this screen is visible, but a manual lock or
/// leaving the app still returns control to iOS.
struct ActiveBackupScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let backup: BackupManager

    @State private var idleTimerOwner = UUID()
    @State private var confirmBackgroundConditions = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        content
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geometry.size.height)
                        if !backup.activeTransfers.items.isEmpty {
                            ActiveBackupTransfersView(transfers: backup.activeTransfers)
                                .frame(maxWidth: 420)
                                .padding(.horizontal, 32)
                                .padding(.bottom, 32)
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .statusBarHidden()
        .onAppear {
            guard backup.isRunning else {
                finishActiveMode()
                return
            }
            if scenePhase == .active { acquireIdleTimer() }
        }
        .onDisappear {
            releaseIdleTimer()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if backup.isRunning {
                    acquireIdleTimer()
                } else {
                    finishActiveMode()
                }
            } else {
                releaseIdleTimer()
            }
        }
        .onChange(of: backup.isRunning) { _, running in
            if !running { finishActiveMode() }
        }
        .confirmationDialog("Back up now?", isPresented: $confirmBackgroundConditions, titleVisibility: .visible) {
            Button("Continue Backup in Background") { requestBackgroundContinuation() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(backup.manualBackupApprovalMessage)
        }
    }

    private var content: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.white.opacity(0.7))

            VStack(spacing: 8) {
                Text("Keep Screen Awake")
                    .font(.title2.weight(.semibold))
                Text(backup.continuedSubtitle)
                    .multilineTextAlignment(.center)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
            }

            if let status = backup.libraryStatus {
                Text(status.countText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("active-backup-library-count")
            }

            ProgressView(value: backup.progressFraction)
                .tint(.accentColor)
                .frame(maxWidth: 280)
                .accessibilityLabel("Backup progress")
                .accessibilityValue(backup.continuedSubtitle)
                .accessibilityIdentifier("active-backup-progress")

            if case .hashing = backup.phase, backup.downloadedOriginalsFromICloud {
                Label(
                    "Downloading some originals from iCloud",
                    systemImage: "icloud.and.arrow.down"
                )
                .font(.callout)
                .foregroundStyle(.white.opacity(0.65))
            }

            if let status = backup.recentBackupStatus {
                Label(status, systemImage: "sparkles")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.65))
                    .accessibilityIdentifier("active-backup-recent-status")
            }

            BackgroundBackupControls(backup: backup, usesDarkBackground: true) {
                if backup.manualBackupNeedsApproval {
                    confirmBackgroundConditions = true
                } else {
                    requestBackgroundContinuation()
                }
            }
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.85))
            .frame(maxWidth: 360)

            Spacer()

            Button("Exit Keep-Awake Mode") {
                finishActiveMode()
            }
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.75))
            .accessibilityIdentifier("active-backup-exit")

        }
        .padding(32)
    }

    private func finishActiveMode() {
        // release the idle timer before dismissal, auto-lock applies again.
        releaseIdleTimer()
        dismiss()
    }

    private func requestBackgroundContinuation() {
        Task {
            let accepted = await ContinuedProcessing.backup.submit(
                title: String(localized: "Backing up"),
                subtitle: String(localized: "Indexing your library...")
            )
            if !accepted, ContinuedProcessing.backup.canFallbackToForeground(for: backup) { backup.start() }
        }
    }

    private func acquireIdleTimer() {
        ScreenAwakeCoordinator.shared.setActive(true, owner: idleTimerOwner)
    }

    private func releaseIdleTimer() {
        ScreenAwakeCoordinator.shared.setActive(false, owner: idleTimerOwner)
    }
}
