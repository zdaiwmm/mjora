import SwiftUI
import UIKit

/// Controls only the whole-library workload. Selected-photo uploads retain
/// their existing foreground lifetime and are never expanded by this view.
struct BackgroundBackupControls: View {
    let backup: BackupManager
    var usesDarkBackground = false
    var requestContinuation: () -> Void

    private var continuation: ContinuedProcessing { .backup }
    private var detailColor: Color { usesDarkBackground ? .white.opacity(0.75) : .secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if backup.isRunning || backup.requiresExplicitResume {
                Button(action: requestContinuation) {
                    Label("Continue Backup in Background", systemImage: "arrow.up.forward.app")
                }
                .disabled(!continuation.canRequestContinuation)
                .accessibilityIdentifier("backup-continue-background")
            }

            if let message = statusMessage {
                HStack(alignment: .top, spacing: 8) {
                    if continuation.status == .accepting { ProgressView().controlSize(.small) }
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(detailColor)
                }
                .accessibilityIdentifier("backup-background-status")
            }

            Text("This control applies to whole-library backup. iOS handles prepared uploads; keep Imora open to prepare remaining files when background time is unavailable. Force-closing Imora stops background transfers.")
                .font(.footnote)
                .foregroundStyle(detailColor)

            if continuation.backgroundRefreshStatus == .denied {
                Text(ProcessInfo.processInfo.isLowPowerModeEnabled
                     ? String(localized: "Low Power Mode turns off Background App Refresh and limits automatic backup recovery.")
                     : String(localized: "Background App Refresh is off. Enable it in Settings > General > Background App Refresh to allow automatic recovery opportunities."))
                    .font(.footnote)
                    .foregroundStyle(detailColor)
                    .accessibilityIdentifier("backup-background-refresh-off")
                Button("Open Settings", systemImage: "gear") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    Task { await UIApplication.shared.open(url) }
                }
                .accessibilityIdentifier("backup-background-settings")
            } else if continuation.backgroundRefreshStatus == .available {
                Text("Background App Refresh is available. iOS chooses when automatic recovery runs.")
                    .font(.footnote)
                    .foregroundStyle(detailColor)
                    .accessibilityIdentifier("backup-background-refresh-available")
            }
        }
        .onAppear { continuation.refreshBackgroundRefreshStatus() }
    }

    private var statusMessage: String? {
        if continuation.hasSystemHandoff, backup.isRunning {
            return String(localized: "Prepared uploads are handled by iOS. Remaining files continue when background time is available.")
        }
        if backup.requiresExplicitResume, !continuation.status.isActive {
            return String(localized: "Whole-library backup paused. Continue Backup in Background or Back Up Now resumes the saved request.")
        }
        switch continuation.status {
        case .idle: return nil
        case .accepting:
            return String(localized: "Requesting background time for whole-library backup...")
        case .accepted:
            return String(localized: "Background request accepted. Waiting to start whole-library backup.")
        case .running:
            return String(localized: "Whole-library backup can continue while iOS grants background time.")
        case .paused:
            return nil
        case .denied(let reason):
            switch reason {
            case .systemBusy:
                return String(localized: "iOS could not grant background time right now. Whole-library backup can continue while Imora is open.")
            case .systemUnavailable:
                return String(localized: "Background time is unavailable. Check Background App Refresh and power settings. Keep Imora open to continue.")
            case .notPermitted:
                return String(localized: "Background backup is unavailable in this app installation. Keep Imora open to continue.")
            case .tooManyRequests:
                return String(localized: "Too many background requests are pending. Keep Imora open and try again later.")
            case .unknown:
                return String(localized: "Could not request background time. Keep Imora open and try again.")
            }
        }
    }
}
