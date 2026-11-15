import SwiftUI
import UIKit

struct PhotosSelectionPreferenceKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct CompactPhotosNavigationKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var usesCompactPhotosNavigation: Bool {
        get { self[CompactPhotosNavigationKey.self] }
        set { self[CompactPhotosNavigationKey.self] = newValue }
    }
}

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
        configuration.source.wrappedValue == "local" ? String(localized: "On Device") : String(localized: "Library")
    }

    var body: some View {
        Menu {
            Picker("Photo Source", selection: configuration.source) {
                Label("Cloud Photos", systemImage: "icloud").tag("cloud")
                    .accessibilityIdentifier("photos-source-cloud")
                Label("On Device", systemImage: "iphone").tag("local")
                    .accessibilityIdentifier("photos-source-local")
            }
            if let backup = session.backup, let status = backup.libraryStatus {
                Section("Backup Status") {
                    Text(status.completionText(backup.summary))
                }
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
            .foregroundStyle(.primary)
            .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .tint(.primary)
        .accessibilityLabel(title)
        .accessibilityIdentifier("photos-source-menu")
        .task(id: session.client?.offlineAccountKey) {
            configuration.controls.loadVisualPreferences(account: session.client?.offlineAccountKey)
        }
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
                    Toggle("Show All Backup Statuses", isOn: $controls.showsAllBackupStatuses)
                        .accessibilityIdentifier("photos-show-all-backup-statuses")
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
        .tint(.primary)
    }
}

struct PhotoPeriodControls: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var controls: PhotosGridControls
    let onSearch: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
                        controls.reveal(bucketID: nil)
                        controls.browsingPast = false
                    }
                } label: {
                    Image(systemName: "photo.on.rectangle.fill").frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Show Library and Collections Navigation")
                Picker("Browse Photos", selection: $controls.mode) {
                    ForEach(PhotoBrowseMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .frame(height: 36)
                .glassEffect(.regular, in: .capsule)
                .accessibilityIdentifier("photos-period-picker")
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass").frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Search")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .tint(.primary)
    }
}

/// One persistent glass container owns both compact navigation states, so
/// changing the timeline position morphs existing controls in place.
struct PhotosNavigationBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var controls: PhotosGridControls
    let showsPeriods: Bool
    @Binding var selection: MainTabView.TabKey
    let onSearch: () -> Void
    @Namespace private var glassNamespace
    @Namespace private var selectionNamespace

    private var motion: Animation? { reduceMotion ? nil : .smooth(duration: 0.35) }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if showsPeriods {
                    Button {
                        withAnimation(motion) {
                            controls.reveal(bucketID: nil)
                            controls.browsingPast = false
                        }
                    } label: {
                        Image(systemName: "photo.on.rectangle.fill")
                            .frame(width: 36, height: 36)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("navigation", in: glassNamespace)
                    .accessibilityLabel("Show Library and Collections Navigation")
                    .accessibilityIdentifier("photos-show-navigation")

                    NativePhotoPeriodPicker(selection: Binding(get: { controls.mode }, set: { mode in
                        withAnimation(motion) {
                            controls.selectedYear = nil
                            controls.mode = mode
                        }
                    }))
                    .frame(maxWidth: 260)
                    .frame(height: 36)
                    .padding(.horizontal, 4)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("periods", in: glassNamespace)
                } else {
                    HStack(spacing: 0) {
                        tab(.photos, title: "Library", symbol: selection == .photos ? "photo.on.rectangle.fill" : "photo.on.rectangle")
                        tab(.albums, title: "Collections", symbol: selection == .albums ? "rectangle.stack.fill" : "rectangle.stack")
                    }
                    .padding(4)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("navigation", in: glassNamespace)
                    Spacer(minLength: 12)
                }
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: showsPeriods ? 17 : 21, weight: .medium))
                        .frame(width: showsPeriods ? 36 : 62, height: showsPeriods ? 36 : 62)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("search", in: glassNamespace)
                .accessibilityLabel("Search")
                .accessibilityIdentifier("photos-search")
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62, alignment: .bottom)
        }
        .padding(.horizontal, 20)
        .foregroundStyle(Color.primary)
        .tint(.primary)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .animation(motion, value: showsPeriods)
    }

    private func tab(_ key: MainTabView.TabKey, title: LocalizedStringKey, symbol: String) -> some View {
        Button {
            withAnimation(motion) { selection = key }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium))
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .frame(width: 90, height: 54)
            .foregroundStyle(selection == key ? Color.blue : Color.primary)
            .background {
                if selection == key {
                    Capsule().fill(.quaternary)
                        .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selection == key ? .isSelected : [])
        .accessibilityIdentifier(key == .photos ? "shell-photos" : "shell-albums")
    }
}

/// The system segmented control fills the same bounds as the adjacent glass
/// buttons. SwiftUI's segmented Picker keeps a smaller intrinsic control inside
/// a taller frame, which leaves the selected region visibly shorter.
private struct NativePhotoPeriodPicker: UIViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: PhotoBrowseMode

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: PhotoBrowseMode.allCases.map(\.title))
        control.accessibilityIdentifier = "photos-period-picker"
        control.accessibilityLabel = String(localized: "Browse Photos")
        control.backgroundColor = .clear
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let index = PhotoBrowseMode.allCases.firstIndex(of: selection) ?? 2
        guard control.selectedSegmentIndex != index else { return }
        if reduceMotion || control.selectedSegmentIndex == UISegmentedControl.noSegment {
            control.selectedSegmentIndex = index
        } else {
            UIView.animate(withDuration: 0.25) {
                control.selectedSegmentIndex = index
                control.layoutIfNeeded()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: proposal.height ?? 36)
    }

    final class Coordinator: NSObject {
        var selection: Binding<PhotoBrowseMode>
        init(selection: Binding<PhotoBrowseMode>) { self.selection = selection }
        @objc func changed(_ control: UISegmentedControl) {
            guard PhotoBrowseMode.allCases.indices.contains(control.selectedSegmentIndex) else { return }
            selection.wrappedValue = PhotoBrowseMode.allCases[control.selectedSegmentIndex]
        }
    }
}
