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
    var onNotifications: () -> Void
    var onSearch: () -> Void
    var pendingFavoriteCount = 0
    var favoriteSyncFailed = false
    var onRetryFavoriteSync: () -> Void = {}
    var onBackupNow: () -> Void = {}
    var onBackupFailures: () -> Void = {}
    var onReady: () -> Void = {}
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
        HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title).font(.largeTitle.bold()).minimumScaleFactor(0.7).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                if configuration.pendingFavoriteCount > 0 {
                    Image(systemName: configuration.favoriteSyncFailed ? "exclamationmark.icloud" : "arrow.triangle.2.circlepath.icloud")
                        .font(.caption)
                        .accessibilityLabel("Favorites waiting to sync")
                }
                if unreadCount > 0 {
                    Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.red)
                }
            }
            .fixedSize(horizontal: true, vertical: true)
            .overlay(alignment: .bottomLeading) {
                if configuration.completePeriodIndex {
                    Text("\(count) items")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: true, vertical: true)
                        .offset(y: 20)
                        .accessibilityIdentifier("photos-item-count")
                } else {
                    Text(configuration.controls.mediaFilter.title).font(.subheadline.weight(.semibold)).offset(y: 20)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.large)
            .foregroundStyle(.primary)
            .contentShape(.rect)
        .accessibilityHidden(true)
        .overlay {
            PhotosNativeSourceMenu(menu: makeMenu(), title: title,
                value: configuration.completePeriodIndex ? String(localized: "\(count) items") : configuration.controls.mediaFilter.title)
        }
        .task(id: session.client?.offlineAccountKey) {
            configuration.controls.loadVisualPreferences(account: session.client?.offlineAccountKey)
        }
    }

    private func makeMenu() -> UIMenu {
        let choices = PhotosLibrarySource.allCases.map { source in
            UIAction(title: source.title, image: UIImage(systemName: source.symbol),
                     identifier: UIAction.Identifier("photos-source-" + source.rawValue),
                     state: configuration.source.wrappedValue == source.rawValue ? .on : .off) { _ in
                configuration.source.wrappedValue = source.rawValue
            }
        }
        let sources = UIMenu(options: [.displayInline, .singleSelection], children: choices)
        sources.preferredElementSize = .medium
        var sections: [UIMenuElement] = [sources]
        if let backup = session.backup {
            let pending = max(0, (backup.libraryStatus?.pending ?? 0) - backup.backupFailures.count)
            let summary = backup.isRunning ? String(localized: "Backing up…")
                : pending > 0 ? String(localized: "\(pending) items waiting to back up")
                : backup.hasBackupFailure ? String(localized: "Backup Needs Attention")
                : backup.libraryStatus == nil ? String(localized: "Checking Backup Status…")
                : String(localized: "All Photos Backed Up")
            var actions: [UIMenuElement] = []
            if !backup.isRunning, backup.libraryStatus?.pending ?? 0 > 0 {
                actions.append(UIAction(title: String(localized: "Back Up Now"), image: UIImage(systemName: "icloud.and.arrow.up"),
                    identifier: .init("photos-back-up-now")) { _ in configuration.onBackupNow() })
            }
            if backup.hasBackupFailure {
                actions.append(UIAction(title: String(localized: "Review Failed Items"), image: UIImage(systemName: "exclamationmark.icloud"),
                    identifier: .init("photos-backup-failures")) { _ in configuration.onBackupFailures() })
            }
            if actions.isEmpty {
                actions.append(UIAction(title: summary, attributes: .disabled) { _ in })
                sections.append(UIMenu(title: String(localized: "Backup Status"), options: .displayInline, children: actions))
            } else {
                sections.append(UIMenu(title: summary, options: .displayInline, children: actions))
            }
        }
        if configuration.pendingFavoriteCount > 0 {
            var actions: [UIMenuElement] = [UIAction(title: String(localized: "\(configuration.pendingFavoriteCount) favorites waiting to sync"),
                attributes: .disabled) { _ in }]
            if configuration.favoriteSyncFailed {
                actions.append(UIAction(title: String(localized: "Retry Favorite Sync")) { _ in configuration.onRetryFavoriteSync() })
            }
            sections.append(UIMenu(title: String(localized: "Favorite Sync"), options: .displayInline, children: actions))
        }
        sections.append(UIMenu(options: .displayInline, children: [
            UIAction(title: String(localized: "Account & Settings"), image: UIImage(systemName: "person.crop.circle")) { _ in configuration.onAccount() },
            UIAction(title: unreadCount > 0 ? String(localized: "Notifications (\(unreadCount))") : String(localized: "Notifications"),
                     image: UIImage(systemName: unreadCount > 0 ? "bell.badge" : "bell")) { _ in configuration.onNotifications() }
        ]))
        return UIMenu(children: sections)
    }
}

private struct PhotosNativeSourceMenu: UIViewRepresentable {
    let menu: UIMenu
    let title: String
    let value: String

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
        button.accessibilityIdentifier = "photos-source-menu"
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.menu = menu
        button.accessibilityLabel = title
        button.accessibilityValue = value
    }

}

struct PhotosBrowseMenu: UIViewRepresentable {
    @Bindable var controls: PhotosGridControls
    var supportsDateAdded = true
    var source = "cloud"

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
        button.tintColor = .label
        button.accessibilityLabel = String(localized: "Sort and Filter")
        button.accessibilityIdentifier = "photos-sort-filter"
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        let symbol = controls.mediaFilter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill"
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22)), for: .normal)
        button.menu = makeMenu()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: 44, height: 44)
    }

    private func makeMenu() -> UIMenu {
        let added = UIAction(title: String(localized: "Date Added"), image: UIImage(systemName: "clock"),
                             attributes: supportsDateAdded ? [] : .disabled,
                             state: controls.sortByAdded ? .on : .off) { _ in controls.sortByAdded = true }
        let captured = UIAction(title: String(localized: "Date Captured"), image: UIImage(systemName: "camera"),
                                state: controls.sortByAdded ? .off : .on) { _ in controls.sortByAdded = false }
        let sort = UIMenu(options: [.displayInline, .singleSelection], children: [added, captured])
        // Medium is UIKit's icon-above-title layout. SwiftUI's palette picker
        // reduces these choices to icon-only cells, including their selection.
        sort.preferredElementSize = .medium

        let filters = [PhotoMediaFilter.all, .favorites, .edited, .notInAlbum, .screenshots].map(filterAction)
        var filterItems: [UIMenuElement] = filters
        if controls.mediaFilter != .all {
            filterItems.append(UIAction(title: String(localized: "Reset Filters")) { _ in controls.mediaFilter = .all })
        }
        filterItems.append(UIMenu(title: String(localized: "Media Types"), image: UIImage(systemName: "photo.on.rectangle"),
                                  options: .singleSelection,
                                  children: PhotoMediaFilter.mediaTypes.filter { $0.isAvailable(onDevice: source == "local") }.map(filterAction)))
        let filter = UIMenu(title: String(localized: "Filter:"), options: .displayInline, children: filterItems)

        let zoomIn = UIAction(title: String(localized: "Zoom In"), image: UIImage(systemName: "plus.magnifyingglass")) { _ in
            controls.zoomIn(viewportWidth: controls.viewportWidth)
        }
        let zoomOut = UIAction(title: String(localized: "Zoom Out"), image: UIImage(systemName: "minus.magnifyingglass")) { _ in
            controls.zoomOut(viewportWidth: controls.viewportWidth)
        }
        let toggles = UIMenu(options: .displayInline, children: [
            toggle(String(localized: "Original Aspect Ratio Grid"), value: controls.usesOriginalAspectRatio) { controls.usesOriginalAspectRatio.toggle() },
            toggle(String(localized: "Date Group Headers"), value: controls.groupsByDate) { controls.groupsByDate.toggle() },
            toggle(String(localized: "Show All Backup Statuses"), value: controls.showsAllBackupStatuses) { controls.showsAllBackupStatuses.toggle() }
        ])
        let options = UIMenu(title: String(localized: "View Options"), children: [zoomIn, zoomOut, toggles])
        return UIMenu(children: [sort, filter, options])
    }

    private func filterAction(_ type: PhotoMediaFilter) -> UIAction {
        UIAction(title: type.title, image: UIImage(systemName: type.symbol),
                 attributes: type.isAvailable(onDevice: source == "local") ? [] : .disabled,
                 state: controls.mediaFilter == type ? .on : .off) { _ in controls.mediaFilter = type }
    }

    private func toggle(_ title: String, value: Bool, action: @escaping () -> Void) -> UIAction {
        UIAction(title: title, state: value ? .on : .off) { _ in action() }
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
                    withAnimation(reduceMotion ? nil : PhotosMotion.layout) {
                        controls.returnToLatest()
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

    private var motion: Animation? { reduceMotion ? nil : PhotosMotion.layout }

    var body: some View {
        GlassEffectContainer(spacing: showsPeriods ? 14 : 12) {
            HStack(spacing: showsPeriods ? 14 : 12) {
                if showsPeriods {
                    Button {
                        withAnimation(motion) {
                            controls.expandNavigation()
                        }
                    } label: {
                        Image(systemName: "photo.on.rectangle.fill")
                            .font(.system(size: 23, weight: .medium))
                            .frame(width: 48, height: 48)
                            .contentShape(.circle)
                    }
                    .foregroundStyle(Color.accentColor)
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("navigation", in: glassNamespace)
                    .accessibilityLabel("Show Library and Collections Navigation")
                    .accessibilityIdentifier("photos-show-navigation")

                    NativePhotoPeriodPicker(selection: Binding(get: { controls.mode }, set: { mode in
                        controls.selectedYear = nil
                        controls.mode = mode
                    }))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("periods", in: glassNamespace)
                } else {
                    HStack(spacing: 0) {
                        tab(.photos, title: "Library", symbol: selection == .photos ? "photo.on.rectangle.fill" : "photo.on.rectangle")
                        tab(.albums, title: "Collections", symbol: selection == .albums ? "rectangle.stack.fill" : "rectangle.stack")
                    }
                    .padding(3)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("navigation", in: glassNamespace)
                    Spacer(minLength: 12)
                }
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: showsPeriods ? 24 : 21, weight: .medium))
                        .frame(width: showsPeriods ? 48 : 62, height: showsPeriods ? 48 : 62)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("search", in: glassNamespace)
                .accessibilityLabel("Search")
                .accessibilityIdentifier("photos-search")
            }
            .frame(maxWidth: .infinity)
            // Native Photos' date controls end 28pt above the screen edge;
            // the expanded Library/Collections navigation ends at 21pt.
            .padding(.bottom, showsPeriods ? 7 : 0)
            .frame(height: 62, alignment: .bottom)
        }
        .padding(.horizontal, showsPeriods ? 28 : 20)
        .foregroundStyle(Color.primary)
        .tint(.primary)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .animation(motion, value: showsPeriods)
    }

    private func tab(_ key: MainTabView.TabKey, title: LocalizedStringKey, symbol: String) -> some View {
        Button {
            withAnimation(motion) {
                if key == .photos, selection == .photos { controls.returnToLatest() }
                else { selection = key }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium))
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .frame(width: 90, height: 56)
            .foregroundStyle(selection == key ? Color.accentColor : Color.primary)
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

    func makeUIView(context: Context) -> PhotoPeriodSegmentedControl {
        let control = PhotoPeriodSegmentedControl(items: PhotoBrowseMode.allCases.map(\.title))
        control.accessibilityIdentifier = "photos-period-picker"
        control.accessibilityLabel = String(localized: "Browse Photos")
        control.backgroundColor = .clear
        let title: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 17, weight: .medium)]
        control.setTitleTextAttributes(title, for: .normal)
        control.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 17, weight: .semibold)], for: .selected)
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: PhotoPeriodSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.reduceMotion = reduceMotion
        let index = PhotoBrowseMode.allCases.firstIndex(of: selection) ?? 2
        control.selectedSegmentIndex = index
        control.setNeedsLayout()
        control.layoutIfNeeded()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PhotoPeriodSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 222, height: proposal.height ?? 48)
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

/// Native segment backgrounds are clipped at the divider. A separate capsule
/// keeps both rounded ends and a 3pt inset while retaining native hit testing
/// and segmented-control accessibility.
private final class PhotoPeriodSegmentedControl: UISegmentedControl {
    var reduceMotion = false
    private let selectionBackground = UIView()

    override init(items: [Any]?) {
        super.init(items: items)
        selectedSegmentTintColor = .clear
        let clear = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 48)).image { _ in }
        setBackgroundImage(clear, for: .normal, barMetrics: .default)
        setBackgroundImage(clear, for: .selected, barMetrics: .default)
        for left in [UIControl.State.normal, .selected] {
            for right in [UIControl.State.normal, .selected] {
                setDividerImage(clear, forLeftSegmentState: left, rightSegmentState: right, barMetrics: .default)
            }
        }
        selectionBackground.backgroundColor = .tertiarySystemFill
        selectionBackground.isUserInteractionEnabled = false
        selectionBackground.isAccessibilityElement = false
        insertSubview(selectionBackground, at: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        sendSubviewToBack(selectionBackground)
        guard numberOfSegments > 0, selectedSegmentIndex != Self.noSegment else {
            selectionBackground.isHidden = true
            return
        }
        selectionBackground.isHidden = false
        let width = bounds.width / CGFloat(numberOfSegments)
        let target = CGRect(x: CGFloat(selectedSegmentIndex) * width, y: 0,
                            width: width, height: bounds.height).insetBy(dx: 3, dy: 3)
        selectionBackground.layer.cornerRadius = target.height / 2
        if !reduceMotion, selectionBackground.frame.size == target.size,
           selectionBackground.frame.origin != target.origin {
            UIView.animate(withDuration: PhotosMotion.layoutDuration, delay: 0,
                           usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.selectionBackground.frame = target
            }
        } else { selectionBackground.frame = target }
    }
}
