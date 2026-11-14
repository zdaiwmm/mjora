import SwiftUI

struct PhotosToolbarConfiguration {
    var source: Binding<String>
    let controls: PhotosGridControls
    var completePeriodIndex = true
    var supportsDateAdded = true
    var onAccount: () -> Void
    var onBackup: () -> Void
    var onNotifications: () -> Void
    var onSearch: () -> Void
}

struct PhotosSourceMenu: View {
    @Environment(SessionStore.self) private var session
    let configuration: PhotosToolbarConfiguration
    let count: Int
    private var unreadCount: Int { session.notifications?.unreadCount ?? 0 }

    private var title: String {
        configuration.source.wrappedValue == "local" ? String(localized: "On Device") : String(localized: "Photos")
    }

    var body: some View {
        Menu {
            Picker("Photo Source", selection: configuration.source) {
                Label("Cloud Photos", systemImage: "icloud").tag("cloud")
                    .accessibilityIdentifier("photos-source-cloud")
                Label("On Device", systemImage: "iphone").tag("local")
                    .accessibilityIdentifier("photos-source-local")
            }
            Section {
                Button(action: configuration.onAccount) {
                    Label("Account & Settings", systemImage: "person.crop.circle")
                }
                .accessibilityIdentifier("profile-avatar")
                Button(action: configuration.onBackup) { Label("Backup & Sync", systemImage: "icloud.and.arrow.up") }
                    .accessibilityIdentifier("photos-backup")
                Button(action: configuration.onNotifications) {
                    if unreadCount > 0 { Label("Notifications (\(unreadCount))", systemImage: "bell.badge") }
                    else { Label("Notifications", systemImage: "bell") }
                }
                    .accessibilityIdentifier("notifications-open")
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(title).font(.largeTitle.bold()).minimumScaleFactor(0.7).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    if unreadCount > 0 {
                        Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.red)
                    }
                }
                if configuration.completePeriodIndex {
                    Text("\(count) items").font(.subheadline.weight(.semibold)).lineLimit(1)
                } else {
                    Text(configuration.controls.mediaFilter.title).font(.subheadline.weight(.semibold))
                }
            }
            .fixedSize(horizontal: true, vertical: true)
            .dynamicTypeSize(...DynamicTypeSize.large)
            .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(title)
        .accessibilityIdentifier("photos-source-menu")
    }
}

struct PhotosBrowseMenu: View {
    @Bindable var controls: PhotosGridControls
    var supportsDateAdded = true

    var body: some View {
        Menu {
            Picker("Sort", selection: $controls.sortByAdded) {
                Text("Date Added").tag(true)
                    .disabled(!supportsDateAdded)
                Text("Date Captured").tag(false)
            }
            .pickerStyle(.palette)
            Section("Filter") {
                Picker("Filter", selection: $controls.mediaFilter) {
                    Label("All Items", systemImage: "square.grid.3x3").tag(PhotoMediaFilter.all)
                    Label("Favorites", systemImage: "heart").tag(PhotoMediaFilter.favorites)
                }
                .pickerStyle(.inline)
                Menu("Media Types", systemImage: "photo.on.rectangle") {
                    Picker("Media Types", selection: $controls.mediaFilter) {
                        ForEach([PhotoMediaFilter.photos, .videos, .livePhotos]) { type in
                            Label(type.title, systemImage: type.symbol).tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            Menu {
                Button { controls.zoomIn(viewportWidth: controls.viewportWidth) } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .accessibilityIdentifier("photos-zoom-in")
                Button { controls.zoomOut(viewportWidth: controls.viewportWidth) } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .accessibilityIdentifier("photos-zoom-out")
                Section {
                    Toggle("Original Aspect Ratio Grid", isOn: $controls.usesOriginalAspectRatio)
                    Toggle("Date Group Headers", isOn: $controls.groupsByDate)
                }
            } label: {
                Label("View Options", systemImage: "rectangle.grid.3x3")
            }
            .accessibilityIdentifier("photos-display-options")
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .symbolVariant(controls.mediaFilter == .all ? .none : .circle.fill)
        }
        .accessibilityLabel("Sort and Filter")
        .accessibilityIdentifier("photos-sort-filter")
    }
}

struct PhotoPeriodControls: View {
    @Bindable var controls: PhotosGridControls
    let onSearch: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    controls.mode = .all
                    controls.browsingPast = false
                } label: {
                    Image(systemName: "photo.on.rectangle.fill").frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Show Photos and Albums Navigation")
                Picker("Browse Photos", selection: $controls.mode) {
                    ForEach(PhotoBrowseMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .glassEffect(.regular, in: .capsule)
                .accessibilityIdentifier("photos-period-picker")
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass").frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Search")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}
