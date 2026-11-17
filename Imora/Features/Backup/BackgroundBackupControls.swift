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
            Button(action: requestContinuation) {
                Label("Continue Backup in Background", systemImage: "arrow.up.forward.app")
            }
            .disabled(!continuation.canRequestContinuation || (!backup.isRunning && !backup.canStartBackup))
            .accessibilityIdentifier("backup-continue-background")

            if let message = statusMessage {
                HStack(alignment: .top, spacing: 8) {
                    if continuation.status == .accepting { ProgressView().controlSize(.small) }
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(detailColor)
                }
                .accessibilityIdentifier("backup-background-status")
            }

            if continuation.backgroundRefreshStatus == .denied {
                Text("Background App Refresh Is Off")
                    .foregroundStyle(detailColor)
                    .accessibilityIdentifier("backup-background-refresh-off")
                Button("Open Settings", systemImage: "gear") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    Task { await UIApplication.shared.open(url) }
                }
                .accessibilityIdentifier("backup-background-settings")
            }
        }
        .onAppear { continuation.refreshBackgroundRefreshStatus() }
    }

    private var statusMessage: String? {
        if continuation.hasSystemHandoff, backup.isRunning {
            return String(localized: "Uploads Managed by iOS")
        }
        if backup.requiresExplicitResume, !continuation.status.isActive {
            return String(localized: "Backup Paused")
        }
        switch continuation.status {
        case .idle: return nil
        case .accepting:
            return String(localized: "Requesting Background Time…")
        case .accepted:
            return String(localized: "Waiting for iOS")
        case .running:
            return String(localized: "Running in Background")
        case .paused:
            return nil
        case .denied(let reason):
            switch reason {
            case .systemBusy:
                return String(localized: "iOS Is Busy")
            case .systemUnavailable:
                return String(localized: "Background Time Unavailable")
            case .notPermitted:
                return String(localized: "Background Backup Unavailable")
            case .tooManyRequests:
                return String(localized: "Too Many Background Requests")
            case .unknown:
                return String(localized: "Couldn't Request Background Time")
            }
        }
    }
}
