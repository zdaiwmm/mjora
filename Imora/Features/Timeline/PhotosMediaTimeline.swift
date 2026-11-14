import SwiftUI

/// Media filtering uses paged server search; a loaded timeline page cannot
/// establish that the entire library has no further matching videos or Live Photos.
struct PhotosMediaTimeline: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    let media: PhotoMediaFilter
    var configuration: PhotosToolbarConfiguration? = nil
    var title = ""
    @State private var search = SearchModel()
    @State private var timeline = TimelineModel(filter: TimelineFilter(), suppliedAssets: [])

    var body: some View {
        TimelineScreen(title: title, filter: timeline.filter, showsLargeTitle: false,
                       photosConfiguration: configuration, showsEmptyState: false,
                       suppliedModel: timeline, footer: { PhotosMediaFooter(search: search) })
            .task {
                guard let client = session.client else { return }
                search.attach(client, hub: session.realtime)
                var filter = SearchFilter()
                filter.sortOrder = .newest
                filter.mediaType = media == .videos ? .video : .image
                filter.isMotion = media == .livePhotos
                if search.hasActiveSearch, search.filter == filter { await search.refresh() }
                else { search.apply(filter) }
            }
            .refreshable { await search.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await search.refresh() } }
            }
            .onChange(of: search.queryRevision, initial: true) { _, revision in
                let searchModel = search
                timeline.onAssetsChanged = { [weak searchModel] change in
                    searchModel?.applyTimelineChange(change, revision: revision)
                }
            }
            .onChange(of: search.assets) {
                timeline.replaceSuppliedAssets(search.assets, groupsByDate: true)
            }
            .overlay {
                if search.assets.isEmpty {
                    if search.isLoading { ProgressView() }
                    else if search.loadFailed {
                        ContentUnavailableView {
                            Label("Couldn't load photos", systemImage: "wifi.exclamationmark")
                        } actions: { Button("Retry", action: search.retry) }
                    } else { ContentUnavailableView("No photos yet", systemImage: media.symbol) }
                }
            }
    }
}

private struct PhotosMediaFooter: View {
    @Environment(\.timelineFooterIsVisible) private var isVisible
    let search: SearchModel

    var body: some View {
        if !search.assets.isEmpty, search.hasMore || search.loadFailed {
            Group {
                if search.isLoading { ProgressView() }
                else {
                    Button(search.loadFailed ? String(localized: "Couldn't load more. Retry") : String(localized: "Load More Results"), action: search.loadMore)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical)
            .onChange(of: isVisible, initial: true) { _, visible in
                if visible, !search.loadFailed { search.loadMore() }
            }
        }
    }
}
