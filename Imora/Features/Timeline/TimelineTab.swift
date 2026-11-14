import SwiftUI

struct TimelineTab: View {
    @Environment(SessionStore.self) private var session
    @Bindable private var router = TimelineNavigationRouter.shared
    @AppStorage("imora.photos.source") private var source = "cloud"
    @State private var cloudControls = PhotosGridControls()
    @State private var deviceControls = PhotosGridControls()
    @State private var showSettings = false
    @State private var showBackupSettings = false

    private var controls: PhotosGridControls { source == "local" ? deviceControls : cloudControls }
    private var filter: TimelineFilter {
        TimelineFilter(withPartners: true,
                       withSharedSpaces: session.capabilities.mergesSharedSpacesIntoTimeline,
                       withStacked: true,
                       isFavorite: cloudControls.mediaFilter == .favorites ? true : nil,
                       order: "asc", orderBy: cloudControls.sortByAdded ? "createdAt" : nil)
    }
    private var configuration: PhotosToolbarConfiguration {
        PhotosToolbarConfiguration(source: $source, controls: controls,
            completePeriodIndex: source == "local" || [.all, .favorites].contains(controls.mediaFilter),
            supportsDateAdded: source != "local" && [.all, .favorites].contains(controls.mediaFilter),
            onAccount: { showSettings = true }, onBackup: { showBackupSettings = true },
            onNotifications: { NotificationRouter.shared.openInbox() },
            onSearch: { router.searchRequested = true })
    }

    var body: some View {
        NavigationStack {
            Group {
                if source == "local" {
                    DeviceLibraryScreen(navigationTarget: $router.pendingTarget,
                                        photosConfiguration: configuration)
                } else if [.all, .favorites].contains(cloudControls.mediaFilter) {
                    CloudPhotosScreen(filter: filter, navigationTarget: $router.pendingTarget,
                                      configuration: configuration)
                        .id(filter)
                } else {
                    PhotosMediaTimeline(media: cloudControls.mediaFilter, configuration: configuration)
                        .id(cloudControls.mediaFilter)
                }
            }
            .onChange(of: controls.mediaFilter) { _, _ in
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
            .navigationDestination(isPresented: $showBackupSettings) { BackupScreen() }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}

private struct CloudPhotosScreen: View {
    let filter: TimelineFilter
    @Binding var navigationTarget: TimelineNavigationTarget?
    let configuration: PhotosToolbarConfiguration
    @State private var model: TimelineModel

    init(filter: TimelineFilter, navigationTarget: Binding<TimelineNavigationTarget?>,
         configuration: PhotosToolbarConfiguration) {
        self.filter = filter
        _navigationTarget = navigationTarget
        self.configuration = configuration
        _model = State(initialValue: TimelineModel(filter: filter))
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
