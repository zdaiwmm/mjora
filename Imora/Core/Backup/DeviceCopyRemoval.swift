import Foundation
import SwiftUI
import Observation

/// Owned by the presenting screen, including UIKit-hosted viewers. The pending
/// caller is resumed exactly once on completion, cancellation, or dismissal.
@MainActor @Observable
final class DeviceCopyRemovalCoordinator {
    enum Phase {
        case preparing
        case ready(CleanupReport)
        case verifying
    }

    var isPresented = false
    private(set) var phase: Phase = .preparing
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var continuation: CheckedContinuation<CleanupOutcome, any Error>?
    @ObservationIgnored private var perform: (@MainActor (CleanupReport) async throws -> CleanupOutcome)?

    func remove(localIDs: Set<String>, backup: BackupManager) async throws -> CleanupOutcome {
        try await remove(prepare: { try await backup.cleanUpCandidates(selectedLocalIDs: localIDs) },
                         perform: { try await backup.performCleanup(report: $0) })
    }

    func remove(prepare: @escaping @MainActor () async throws -> CleanupReport,
                perform: @escaping @MainActor (CleanupReport) async throws -> CleanupOutcome) async throws -> CleanupOutcome {
        // A second request cannot replace the scope the user is reviewing.
        guard continuation == nil else { throw CleanupVerificationError.changed }
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                self.requestID = requestID
                self.continuation = continuation
                self.perform = perform
                phase = .preparing
                isPresented = true
                task = Task {
                    do {
                        let report = try await prepare()
                        try Task.checkCancellation()
                        phase = .ready(report)
                        task = nil
                    } catch { finish(.failure(error)) }
                }
            }
        } onCancel: {
            Task { @MainActor in
                if self.requestID == requestID { self.cancel() }
            }
        }
    }

    func confirm() {
        guard continuation != nil, case .ready(let report) = phase, let perform else { return }
        phase = .verifying
        task = Task {
            do {
                let outcome = try await perform(report)
                // Once PhotoKit succeeded, report the actual deletion even if
                // cancellation raced the already-committed system operation.
                finish(.success(outcome))
            } catch { finish(.failure(error)) }
        }
    }

    func cancel() {
        guard continuation != nil else { return }
        if let task { task.cancel() }
        else { finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<CleanupOutcome, any Error>) {
        let pending = continuation
        continuation = nil
        requestID = nil
        task = nil
        perform = nil
        isPresented = false
        pending?.resume(with: result)
    }
}

private struct DeviceCopyRemovalSheet: View {
    let coordinator: DeviceCopyRemovalCoordinator

    var body: some View {
        NavigationStack {
            Form {
                switch coordinator.phase {
                case .preparing:
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Preparing device copy verification…")
                    }
                case .ready(let report):
                    Section {
                        Text("Verify and remove \(report.eligible.count) selected device copies?")
                            .font(.headline)
                        Text("Every selected original will be downloaded from your server and checked before the device copies are removed. Live Photos require both the photo and video. The server copies are kept.")
                        LabeledContent("Server route", value: report.route.absoluteString)
                        LabeledContent("Estimated original download", value: report.estimatedOriginalBytes.map {
                            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                        } ?? String(localized: "not yet known"))
                        Text("Reading original resources from iCloud may also be needed and can use additional data and time. You can cancel or remove these copies later.")
                            .foregroundStyle(.secondary)
                    }
                    Button("Verify Originals and Remove Device Copies", role: .destructive) {
                        coordinator.confirm()
                    }
                    .accessibilityIdentifier("device-copy-removal-confirm")
                case .verifying:
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Verifying original files before removal...")
                    }
                    Text("Keep this screen open while the selected originals are checked. You can cancel verification before removal.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Remove Device Copies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { coordinator.cancel() }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

private struct DeviceCopyRemovalPresentation: ViewModifier {
    @Bindable var coordinator: DeviceCopyRemovalCoordinator

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $coordinator.isPresented, onDismiss: { if !coordinator.isPresented { coordinator.cancel() } }) {
                DeviceCopyRemovalSheet(coordinator: coordinator)
            }
            .onDisappear { coordinator.cancel() }
    }
}

extension View {
    func deviceCopyRemovalPresentation(_ coordinator: DeviceCopyRemovalCoordinator) -> some View {
        modifier(DeviceCopyRemovalPresentation(coordinator: coordinator))
    }
}
