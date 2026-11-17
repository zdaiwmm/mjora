import SwiftUI

struct TimelineTab: View {
    @Environment(SessionStore.self) private var session
    @Bindable private var router = TimelineNavigationRouter.shared
    @AppStorage(PhotosLibrarySource.preferenceKey) private var source = "all"
    var cloudControls = PhotosGridControls()
    var deviceControls = PhotosGridControls()
    @State private var showSettings = false
    @State private var showBackupFailures = false
    @State private var confirmBackupConditions = false
    @State private var visitedSources = Set<String>()
    @State private var readySources = Set<String>()
    @State private var displayedSource: String?
    private var visibleSource: String { displayedSource ?? source }

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
            onAccount: { showSettings = true },
            onNotifications: { NotificationRouter.shared.openInbox() },
            onSearch: { router.searchRequested = true },
            pendingFavoriteCount: session.favorites?.pendingCount ?? 0,
            favoriteSyncFailed: session.favorites?.syncFailed ?? false,
            onRetryFavoriteSync: { Task { await session.favorites?.flush() } },
            onBackupNow: {
                guard let backup = session.backup else { return }
                if backup.manualBackupNeedsApproval { confirmBackupConditions = true }
                else { backup.start() }
            },
            onBackupFailures: { showBackupFailures = true },
            onReady: {
                readySources.insert(value)
                if source == value {
                    displayedSource = value
                    #if DEBUG || PHASE4_PERFORMANCE
                    GalleryFrameMetrics.shared.end("source-switch")
                    #endif
                }
            })
    }

    var body: some View {
        ZStack {
            ForEach(["all", "cloud", "local"], id: \.self) { value in
                if source == value || visitedSources.contains(value) {
                    sourceStack(value)
                        .opacity(visibleSource == value ? 1 : 0)
                        .allowsHitTesting(visibleSource == value)
                        .accessibilityHidden(visibleSource != value)
                        .zIndex(visibleSource == value ? 1 : 0)
                        .transformPreference(PhotosSelectionPreferenceKey.self) {
                            if source != value { $0 = false }
                        }
                }
            }
        }
        .background(Color(.systemBackground))
        .onAppear {
            visitedSources.insert(source)
            if displayedSource == nil { displayedSource = source }
        }
        .task(id: session.client?.context.id) { await session.backup?.refreshLibraryStatus() }
        .animation(nil, value: source)
        .onChange(of: source) { oldSource, newSource in
            #if DEBUG || PHASE4_PERFORMANCE
            GalleryFrameMetrics.shared.begin("source-switch")
            #endif
            visitedSources.formUnion([oldSource, newSource])
            if readySources.contains(newSource) {
                displayedSource = newSource
                #if DEBUG || PHASE4_PERFORMANCE
                Task { @MainActor in GalleryFrameMetrics.shared.end("source-switch") }
                #endif
            }
            if session.cachedLaunchHandle?.source != PhotosLibrarySource(rawValue: newSource)?.launchSource {
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
        .onChange(of: cloudControls.mediaFilter) { readySources.subtract(["all", "cloud"]) }
        .onChange(of: cloudControls.sortByAdded) { readySources.subtract(["all", "cloud"]) }
        .onChange(of: controls.sortByAdded) { controls.scrollOffset = nil }
        .onChange(of: router.pendingTarget, initial: true) { _, target in
            if let target {
                source = target.assetID.hasPrefix("local-") ? "local" : "cloud"
                controls.mediaFilter = .all
                controls.mode = .all
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .confirmationDialog("Back up now?", isPresented: $confirmBackupConditions, titleVisibility: .visible) {
            Button("Back Up Now") { session.backup?.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let backup = session.backup { Text(backup.manualBackupApprovalMessage) }
        }
    }

    private func sourceStack(_ value: String) -> some View {
        NavigationStack {
            Group {
                if value == "local" {
                    DeviceLibraryScreen(session: session, navigationTarget: $router.pendingTarget,
                                        photosConfiguration: configuration(for: value))
                } else if [.all, .favorites].contains(cloudControls.mediaFilter) {
                    CloudPhotosScreen(session: session, filter: filter, navigationTarget: $router.pendingTarget,
                                      configuration: configuration(for: value), mergesLocal: value == "all")
                        .id(filter)
                } else {
                    PhotosMediaTimeline(media: cloudControls.mediaFilter, configuration: configuration(for: value), includesDevice: value == "all")
                        .id(cloudControls.mediaFilter)
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { showBackupFailures && source == value },
                set: { if source == value { showBackupFailures = $0 } }
            )) { BackupFailuresScreen() }
        }
    }
}

private struct CloudPhotosScreen: View {
    let filter: TimelineFilter
    @Binding var navigationTarget: TimelineNavigationTarget?
    let configuration: PhotosToolbarConfiguration
    let mergesLocal: Bool
    @State private var modelHolder: TimelineModelHolder
    private var model: TimelineModel { modelHolder.model }

    init(session: SessionStore, filter: TimelineFilter, navigationTarget: Binding<TimelineNavigationTarget?>,
         configuration: PhotosToolbarConfiguration, mergesLocal: Bool) {
        self.mergesLocal = mergesLocal
        self.filter = filter
        _navigationTarget = navigationTarget
        self.configuration = configuration
        _modelHolder = State(initialValue: TimelineModelHolder {
            let model = TimelineModel(filter: filter, mergesLocal: mergesLocal)
            if let client = session.client {
                model.attachCachedLaunch(session.cachedLaunchHandle, client: client, backup: session.backup)
            }
            return model
        })
    }

    var body: some View {
        TimelineScreen(title: "", filter: filter, showsLargeTitle: false,
                       photosConfiguration: configuration, suppliedModel: model, mergesLocalPhotos: mergesLocal,
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
