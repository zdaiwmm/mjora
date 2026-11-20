import Photos
import SwiftUI

struct PhotoSearchSourcePicker: View {
    @Binding var source: PhotoSearchSource

    var body: some View {
        Menu {
            Picker("Search Source", selection: $source) {
                ForEach(PhotoSearchSource.allCases) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
        } label: {
            Label(source.title, systemImage: source.symbol)
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Search Source")
        .accessibilityValue(source.title)
        .accessibilityIdentifier("search-source")
    }
}

/// Local search never mounts the server discovery/filter subtree.
struct LocalPhotoSearchView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @Binding var source: PhotoSearchSource
    @Binding var query: String
    @State private var model = LocalPhotoSearchModel()

    private struct Request: Hashable {
        let query: String
        let revision: Int
        let context: LocalPhotoSearchModel.Context
    }

    private var context: LocalPhotoSearchModel.Context {
        .init(sessionID: session.client?.context.id,
              permissionEpoch: DeviceMediaFactsStore.shared.generation,
              authorization: PhotoAccess.shared.status.rawValue,
              isActive: scenePhase == .active && session.client?.context.isActive == true)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PhotoSearchSourcePicker(source: $source)
                Spacer(minLength: 8)
                Text("File Names & Dates").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            if PhotoAccess.shared.canAsk || PhotoAccess.shared.status == .denied || PhotoAccess.shared.status == .restricted {
                ContentUnavailableView {
                    Label("Search On Device", systemImage: "iphone")
                } description: {
                    Text("Allow photo access to search photos on this device.")
                } actions: {
                    if PhotoAccess.shared.canAsk {
                        Button("Allow Photo Access") {
                            Task { _ = await PhotoLibraryService.requestFullAccess(); await reload() }
                        }
                    } else if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Manage Photo Access", destination: url)
                    }
                }
            } else if model.context != context || model.phase != .ready {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TimelineScreen(title: "", filter: model.timeline.filter,
                    emptyMessage: String(localized: "No matching photos on this device."),
                    showsLargeTitle: false, suppliedModel: model.timeline, mergesLocalPhotos: true,
                    header: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(model.results.count) results").font(.subheadline).foregroundStyle(.secondary)
                            if PhotoAccess.shared.status == .limited {
                                Text("Only photos you've allowed are searched.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal).padding(.bottom, 6)
                    })
                    .accessibilityIdentifier("local-search-results")
            }
        }
        .task(id: context) {
            DeviceMediaFactsStore.shared.startObserving()
            await reload()
        }
        .task(id: Request(query: query, revision: model.metadataRevision, context: context)) {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            await model.search(query, context: context)
        }
        .onChange(of: session.realtime?.localGeneration) { _, _ in Task { await reload() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { PhotoAccess.shared.refresh() }
            else { model.invalidate() }
        }
        .onDisappear { model.invalidate() }
    }

    private func reload() async {
        let backedUp = Set(session.backup?.remoteIdentifierByLocalId.keys.map { $0 } ?? [])
        let requested = context
        await model.reload(context: requested, backedUpLocalIDs: backedUp)
        guard !Task.isCancelled, context == requested else { return }
        await model.search(query, context: requested)
    }
}
