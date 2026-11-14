import Foundation
import SwiftUI

/// Shared native rows for Backup settings and the foreground keep-awake view.
/// The periodic redraw ages the byte measurements even if an upload is idle.
struct ActiveBackupTransfersView: View {
    let transfers: ActiveBackupTransfers

    var body: some View {
        if transfers.items.contains(where: { $0.stage == .uploading }) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                content(now: ProcessInfo.processInfo.systemUptime)
            }
        } else {
            content(now: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func content(now: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Current Files"))
                .font(.headline)

            if let rate = transfers.bytesPerSecond(at: now) {
                Text(String(localized: "Total upload speed: \(speedText(rate))"))
                    .font(.callout.monospacedDigit())
                    .accessibilityIdentifier("backup-total-upload-speed")
            } else if transfers.items.contains(where: { $0.stage == .uploading }) {
                Text(String(localized: "Measuring upload speed…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(transfers.items) { transfer in
                VStack(alignment: .leading, spacing: 6) {
                    if let filename = transfer.filename {
                        Text(verbatim: filename)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                            .truncationMode(.middle)
                    } else {
                        Text(String(localized: "Reading file details…"))
                            .font(.subheadline)
                    }
                    HStack(spacing: 8) {
                        Text(stageText(transfer.stage))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if let fraction = transfer.fraction {
                            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                                .font(.caption.monospacedDigit())
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    if let fraction = transfer.fraction {
                        ProgressView(value: fraction)
                            .tint(.indigo)
                    }
                    if let rate = transfer.bytesPerSecond(at: now) {
                        Text(String(localized: "Upload speed: \(speedText(rate))"))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("backup-current-file-\(transfer.id)")
            }

            Text(String(localized: "The backed-up count increases after server verification."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("backup-current-files")
    }

    private func stageText(_ stage: BackupTransferStage) -> String {
        switch stage {
        case .preparing: String(localized: "Preparing original…")
        case .downloadingOriginal: String(localized: "Downloading original from iCloud…")
        case .uploading: String(localized: "Uploading file…")
        case .verifying: String(localized: "Verifying backup with server…")
        }
    }

    private func speedText(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 {
            let amount = (bytesPerSecond / 1_000_000).formatted(.number.precision(.fractionLength(0...1)))
            return String(localized: "\(amount) MB/s")
        }
        let amount = (bytesPerSecond / 1_000).formatted(.number.precision(.fractionLength(0...1)))
        return String(localized: "\(amount) KB/s")
    }
}
