import SwiftUI

struct TimelineTab: View {
    @Environment(SessionStore.self) private var session
    @Bindable private var router = TimelineNavigationRouter.shared
    @AppStorage("imora.photos.source") private var source = "cloud"
    @State private var showSettings = false
    @State private var showBackupSettings = false

    private var filter: TimelineFilter {
        TimelineFilter(
            withPartners: true,
            withSharedSpaces: session.capabilities.mergesSharedSpacesIntoTimeline,
            withStacked: true
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if source == "local" {
                    DeviceLibraryScreen(navigationTarget: $router.pendingTarget)
                } else {
                    CloudPhotosScreen(filter: filter, navigationTarget: $router.pendingTarget) {
                        showBackupSettings = true
                    }
                    .id(filter)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Photo Source", selection: $source) {
                    Text("Cloud").tag("cloud")
                    Text("On Device").tag("local")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("photos-source-picker")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { NotificationRouter.shared.openInbox() } label: { Image(systemName: "bell") }
                        .badge(session.notifications?.unreadCount ?? 0)
                        .accessibilityIdentifier("notifications-open")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { ProfileAvatar(size: 30) }
                        .accessibilityIdentifier("profile-avatar")
                }
            }
            .onChange(of: router.pendingTarget, initial: true) { _, target in
                if let target { source = target.assetID.hasPrefix("local-") ? "local" : "cloud" }
            }
            .navigationDestination(isPresented: $showBackupSettings) {
                BackupScreen()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }
}

private struct CloudPhotosScreen: View {
    let filter: TimelineFilter
    @Binding var navigationTarget: TimelineNavigationTarget?
    let showBackup: () -> Void
    @State private var model: TimelineModel

    init(filter: TimelineFilter, navigationTarget: Binding<TimelineNavigationTarget?>, showBackup: @escaping () -> Void) {
        self.filter = filter
        _navigationTarget = navigationTarget
        self.showBackup = showBackup
        _model = State(initialValue: TimelineModel(filter: filter))
    }

    var body: some View {
        TimelineScreen(title: "", filter: filter, showsLargeTitle: false, suppliedModel: model,
            navigationTarget: $navigationTarget, header: {
                VStack(spacing: 0) {
                    BackupStatusBanner { showBackup() }
                    if !model.sections.isEmpty {
                        Text("\(model.sections.reduce(0) { $0 + $1.count }) cloud items")
                            .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 6)
                            .accessibilityIdentifier("cloud-library-count")
                    }
                    MemoryLane()
                }
            })
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
