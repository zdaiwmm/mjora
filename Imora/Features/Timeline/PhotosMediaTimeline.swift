import SwiftUI

/// Server predicates stay paged. Edited consumes every metadata page before
/// projecting matches, so a page without edits cannot become a false empty result.
struct PhotosMediaTimeline: View {
    @Environment(SessionStore.self) private var session
    let media: PhotoMediaFilter
    var configuration: PhotosToolbarConfiguration? = nil
    var title = ""

    var body: some View {
        Group {
            if media == .edited { PhotosEditedTimeline(configuration: configuration, title: title) }
            else { PhotosServerMediaTimeline(media: media, configuration: configuration, title: title) }
        }
        .id(session.client.map(ObjectIdentifier.init))
    }
}

private struct PhotosServerMediaTimeline: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    let media: PhotoMediaFilter
    var configuration: PhotosToolbarConfiguration? = nil
    var title = ""
    @State private var search = SearchModel()
    @State private var timeline = TimelineModel(filter: TimelineFilter(), suppliedAssets: [])

    private var visibleAssets: [Asset] { search.assets }

    var body: some View {
        TimelineScreen(title: title, filter: timeline.filter, showsLargeTitle: false,
                       photosConfiguration: configuration, showsEmptyState: false,
                       suppliedModel: timeline, footer: {
            PhotosMediaFooter(search: search, count: visibleAssets.count, hidesCount: false)
        })
            .task(id: session.client?.offlineAccountKey) {
                guard media != .screenshots, let client = session.client else { return }
                search.attach(client, hub: session.realtime)
                let filter = media.cloudSearchFilter
                if search.hasActiveSearch, search.filter == filter { await search.refresh() }
                else { search.apply(filter, allowEmpty: true) }
            }
            .refreshable { if media != .screenshots { await search.refresh() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, media != .screenshots { Task { await search.refresh() } }
            }
            .onChange(of: search.queryRevision, initial: true) { _, revision in
                let searchModel = search
                timeline.onAssetsChanged = { [weak searchModel] change in
                    searchModel?.applyTimelineChange(change, revision: revision)
                }
                updateProjection()
            }
            .onChange(of: search.assets) { updateProjection() }
            .onChange(of: search.isLoading) { _, loading in
                updateProjection()
            }
            .overlay {
                if media == .screenshots {
                    ContentUnavailableView("Available On Device", systemImage: media.symbol,
                        description: Text("This server does not provide screenshot classification. Switch the Library source to On Device."))
                        .background(Color(.systemBackground))
                } else if search.loadFailed, search.assets.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't load photos", systemImage: "wifi.exclamationmark")
                    } actions: { Button("Retry", action: search.retry) }
                        .background(Color(.systemBackground))
                } else if search.isLoading && search.assets.isEmpty {
                    ProgressView(String(localized: "Loading photos"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.systemBackground))
                } else if visibleAssets.isEmpty {
                    ContentUnavailableView("No matching photos", systemImage: media.symbol)
                }
            }
    }

    private func updateProjection() {
        let assets = visibleAssets
        timeline.replaceSuppliedAssets(assets, groupsByDate: true)
    }
}

private struct PhotosEditedTimeline: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    let configuration: PhotosToolbarConfiguration?
    let title: String
    @State private var library = PhotosEditedLibraryModel()
    @State private var timeline = TimelineModel(filter: TimelineFilter(), suppliedAssets: [])

    var body: some View {
        TimelineScreen(title: title, filter: timeline.filter, showsLargeTitle: false,
                       photosConfiguration: configuration, showsEmptyState: false, suppliedModel: timeline, footer: {
            if !library.isLoading, library.error == nil {
                Text("\(library.assets.count) items").font(.footnote).foregroundStyle(.secondary).padding()
                    .accessibilityIdentifier("photos-filter-count")
            }
        })
        .task(id: session.client?.offlineAccountKey) {
            guard let client = session.client else { return }
            library.attach(client, hub: session.realtime)
            let libraryModel = library
            timeline.onAssetsChanged = { [weak libraryModel] change in libraryModel?.apply(change) }
            await library.refresh()
        }
        .onChange(of: library.assets, initial: true) { _, assets in
            timeline.replaceSuppliedAssets(assets, groupsByDate: true)
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await library.refresh() } } }
        .refreshable { await library.refresh() }
        .overlay {
            if let error = library.error {
                ContentUnavailableView {
                    Label("Couldn't check edited photos", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: { Button("Retry") { Task { await library.refresh() } } }
                    .background(Color(.systemBackground))
            } else if library.isLoading {
                ProgressView("Checking library for edits").frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
            } else if library.assets.isEmpty {
                ContentUnavailableView("No edited photos", systemImage: "slider.horizontal.3")
            }
        }
    }
}

private struct PhotosMediaFooter: View {
    @Environment(\.timelineFooterIsVisible) private var isVisible
    let search: SearchModel
    let count: Int
    let hidesCount: Bool

    var body: some View {
        VStack(spacing: 10) {
            if !hidesCount {
                Text(search.hasMore ? String(localized: "\(count) items loaded") : String(localized: "\(count) items"))
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("photos-filter-count")
            }
            if !search.assets.isEmpty, search.hasMore || search.loadFailed {
                Group {
                    if search.isLoading { ProgressView() }
                    else {
                        Button(search.loadFailed ? String(localized: "Couldn't load more. Retry") : String(localized: "Load More Results"), action: search.loadMore)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
        .onChange(of: isVisible, initial: true) { _, visible in
            if visible, !search.loadFailed { search.loadMore() }
        }
    }
}
