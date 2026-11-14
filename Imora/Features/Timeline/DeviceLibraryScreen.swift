import SwiftUI

/// A device-only projection. Supplied assets never request server time buckets.
struct DeviceLibraryScreen: View {
    @Binding var navigationTarget: TimelineNavigationTarget?
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = TimelineModel(filter: TimelineFilter(), suppliedAssets: [])
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        TimelineScreen(title: "", filter: TimelineFilter(), emptyMessage: String(localized: "No accessible photos on this device."),
            showsLargeTitle: false, suppliedModel: model, mergesLocalPhotos: true, navigationTarget: $navigationTarget, header: {
                if PhotoAccess.shared.canAsk {
                    Button("Allow Photo Access") {
                        Task { _ = await PhotoLibraryService.requestFullAccess(); reload() }
                    }
                    .padding()
                }
                if PhotoAccess.shared.isBlocked, let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Manage Photo Access", destination: url).padding()
                        .accessibilityIdentifier("device-manage-photo-access")
                }
                Text("\(model.flatAssets.count) items on this device")
                    .font(.footnote).foregroundStyle(.secondary).padding(.bottom, 6)
                    .accessibilityIdentifier("device-library-count")
            })
            .task { reload() }
            .onChange(of: session.realtime?.localGeneration) { _, _ in reload() }
            .onChange(of: PhotoAccess.shared.status) { _, _ in reload() }
            .onChange(of: scenePhase) { _, value in if value == .active { reload() } }
            .onDisappear { loadTask?.cancel() }
    }

    private func reload() {
        loadTask?.cancel()
        let client = session.client
        loadTask = Task {
            let assets: [Asset]
            if PhotoLibraryService.hasFullAccess, let backup = session.backup {
                assets = await backup.localTimelineAssets().map { $0.device.asAsset(backedUp: $0.backedUp) }
            } else {
                assets = await PhotoLibraryService.browsableAssets().map { $0.asAsset(backedUp: false) }
            }
            guard !Task.isCancelled, session.client === client else { return }
            model.replaceSuppliedAssets(assets, groupsByDate: true)
        }
    }
}
