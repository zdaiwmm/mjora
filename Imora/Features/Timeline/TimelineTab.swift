import SwiftUI

struct TimelineTab: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable private var router = TimelineNavigationRouter.shared
    @AppStorage("imora.photos.source") private var source = "cloud"
    var cloudControls = PhotosGridControls()
    var deviceControls = PhotosGridControls()
    @State private var showSettings = false
    @State private var showBackupSettings = false
    @State private var visitedSources = Set<String>()

    private var controls: PhotosGridControls { source == "local" ? deviceControls : cloudControls }
    private var filter: TimelineFilter {
        PhotosLaunchSelection.cloudFilter(mergesSharedSpaces: session.capabilities.mergesSharedSpacesIntoTimeline,
            favorites: cloudControls.mediaFilter == .favorites, sortByAdded: cloudControls.sortByAdded)
    }
    private func configuration(for value: String) -> PhotosToolbarConfiguration {
        let controls = value == "local" ? deviceControls : cloudControls
        return PhotosToolbarConfiguration(source: $source, controls: controls,
            completePeriodIndex: value == "local" || [.all, .favorites].contains(controls.mediaFilter),
            supportsDateAdded: value != "local" && [.all, .favorites].contains(controls.mediaFilter),
            onAccount: { showSettings = true }, onBackup: { showBackupSettings = true },
            onNotifications: { NotificationRouter.shared.openInbox() },
            onSearch: { router.searchRequested = true },
            pendingFavoriteCount: session.favorites?.pendingCount ?? 0,
            favoriteSyncFailed: session.favorites?.syncFailed ?? false,
            onRetryFavoriteSync: { Task { await session.favorites?.flush() } })
    }

    var body: some View {
        ZStack {
            ForEach(["cloud", "local"], id: \.self) { value in
                if source == value || visitedSources.contains(value) {
                    sourceStack(value)
                        .opacity(source == value ? 1 : 0)
                        .allowsHitTesting(source == value)
                        .accessibilityHidden(source != value)
                        .zIndex(source == value ? 1 : 0)
                        .transformPreference(PhotosSelectionPreferenceKey.self) {
                            if source != value { $0 = false }
                        }
                }
            }
        }
        .background(Color(.systemBackground))
        .onAppear { visitedSources.insert(source) }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: source)
        .onChange(of: source) { oldSource, newSource in
            visitedSources.formUnion([oldSource, newSource])
            if session.cachedLaunchHandle?.source != (newSource == "local" ? "device" : "cloud") {
                session.cachedLaunchHandle?.cancel()
            }
        }
        .onChange(of: controls.mediaFilter) { _, _ in
            controls.periodAnchor = nil
            controls.scrollRequest = nil
            controls.mode = .all
            controls.browsingPast = false
            controls.scrollOffset = nil
            if ![.all, .favorites].contains(controls.mediaFilter) { controls.sortByAdded = false }
        }
        .onChange(of: controls.sortByAdded) { controls.scrollOffset = nil }
        .onChange(of: router.pendingTarget, initial: true) { _, target in
            if let target {
                source = target.assetID.hasPrefix("local-") ? "local" : "cloud"
                controls.mediaFilter = .all
                controls.mode = .all
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private func sourceStack(_ value: String) -> some View {
        NavigationStack {
            Group {
                if value == "local" {
                    DeviceLibraryScreen(session: session, navigationTarget: $router.pendingTarget,
                                        photosConfiguration: configuration(for: value))
                } else if [.all, .favorites].contains(cloudControls.mediaFilter) {
                    CloudPhotosScreen(session: session, filter: filter, navigationTarget: $router.pendingTarget,
                                      configuration: configuration(for: value))
                        .id(filter)
                } else {
                    PhotosMediaTimeline(media: cloudControls.mediaFilter, configuration: configuration(for: value))
                        .id(cloudControls.mediaFilter)
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { showBackupSettings && source == value },
                set: { if source == value { showBackupSettings = $0 } }
            )) { BackupScreen() }
        }
    }
}

private struct CloudPhotosScreen: View {
    let filter: TimelineFilter
    @Binding var navigationTarget: TimelineNavigationTarget?
    let configuration: PhotosToolbarConfiguration
    @State private var modelHolder: TimelineModelHolder
    private var model: TimelineModel { modelHolder.model }

    init(session: SessionStore, filter: TimelineFilter, navigationTarget: Binding<TimelineNavigationTarget?>,
         configuration: PhotosToolbarConfiguration) {
        self.filter = filter
        _navigationTarget = navigationTarget
        self.configuration = configuration
        _modelHolder = State(initialValue: TimelineModelHolder {
            let model = TimelineModel(filter: filter)
            if let client = session.client {
                model.attachCachedLaunch(session.cachedLaunchHandle, client: client, backup: session.backup)
            }
            return model
        })
    }

    var body: some View {
        TimelineScreen(title: "", filter: filter, showsLargeTitle: false,
                       photosConfiguration: configuration, suppliedModel: model,
                       navigationTarget: $navigationTarget)
    }
}

/// small circular avatar for the signed-in user.
struct ProfileAvatar: View {
    @Environment(SessionStore.self) private var session
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let image = session.optimisticProfileImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let user = session.user, let client = session.client,
               user.profileImagePath?.isEmpty == false {
                RemoteImage(url: profileImageURL(client: client, userID: user.id), targetPixelSize: 120)
            } else {
                Circle()
                    .fill(.indigo.gradient)
                    .overlay {
                        Text(initials)
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }

    private var initials: String {
        let name = session.user?.name ?? ""
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters)
    }

    private func profileImageURL(client: ImoraClient, userID: String) -> URL {
        guard let key = session.profileImageCacheKey else {
            return client.profileImageURL(userID: userID)
        }
        return client.profileImageURL(userID: userID)
            .appending(queryItems: [URLQueryItem(name: "c", value: key)])
    }
}
