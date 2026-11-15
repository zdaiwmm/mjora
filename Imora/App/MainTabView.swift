import SwiftUI
import UIKit

struct MainTabView: View {
    @Environment(SessionStore.self) private var session
    /// in-app navigation targets land here, so the shell owns both the inbox
    /// sheet and the tab switch an album deep link needs.
    @Bindable private var router = NotificationRouter.shared
    @Bindable private var timelineRouter = TimelineNavigationRouter.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("imora.photos.source") private var source = "cloud"
    @State private var cloudControls = PhotosGridControls()
    @State private var deviceControls = PhotosGridControls()
    @State private var hidesCompactNavigation = false
    @State private var keyboardVisible = false
    @State private var selection: TabKey = .photos
    @State private var searchText = ""
    @State private var searchScope: SearchFilter.TextType = .context
    @State private var searchSource: PhotoSearchSource = .cloud
    @State private var searchSubmitRequest = 0
    @State private var isSearchPresented = false
    @FocusState private var isSearchFocused: Bool

    private var tabSelection: Binding<TabKey> {
        Binding(
            get: { selection },
            set: { tab in
                if tab == .search, selection != .search {
                    searchSource = selection == .photos ? PhotoSearchSource(librarySource: source) : .cloud
                }
                if tab == .search, selection == .search { focusSearch() }
                if tab != .search {
                    isSearchPresented = false
                    isSearchFocused = false
                }
                selection = tab
            }
        )
    }

    enum TabKey: Hashable {
        case photos, albums, library, search
        /// the library's destinations as sidebar entries of their own.
        case favorites, people, places, archive, locked, trash, spaces

        var isLibrarySection: Bool {
            switch self {
            case .favorites, .people, .places, .archive, .locked, .trash, .spaces: true
            case .photos, .albums, .library, .search: false
            }
        }
    }

    /// the sidebar only exists at regular width, and without it the section's
    /// tabs would land in a "more" tab that duplicates the library.
    private var showsLibrarySection: Bool {
        horizontalSizeClass == .regular
    }

    private var photoControls: PhotosGridControls { source == "local" ? deviceControls : cloudControls }
    private var showsDateNavigation: Bool {
        selection == .photos && (source == "local" || [.all, .favorites].contains(photoControls.mediaFilter))
            && (photoControls.browsingPast || photoControls.mode != .all)
    }

    var body: some View {
        GeometryReader { geometry in
            content(bottomSafeArea: geometry.safeAreaInsets.bottom)
        }
    }

    private func content(bottomSafeArea: CGFloat) -> some View {
        ZStack {
            AssetViewerOpeningChromePrewarmer()
                .ignoresSafeArea()
                .background {
                    VStack(spacing: 0) {
                        Color.black.frame(height: 132)
                        Spacer(minLength: 0)
                        Color.black.frame(height: 112)
                    }
                    .ignoresSafeArea()
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            TabView(selection: tabSelection) {
                Tab("Library", systemImage: selection == .photos ? "photo.on.rectangle.fill" : "photo.on.rectangle", value: TabKey.photos) {
                    TimelineTab(cloudControls: cloudControls, deviceControls: deviceControls)
                        .id(session.client?.offlineAccountKey)
                }
                Tab("Collections", systemImage: selection == .albums ? "rectangle.stack.fill" : "rectangle.stack", value: TabKey.albums) {
                    AlbumsTab(account: session.client?.offlineAccountKey)
                        .id(session.client?.offlineAccountKey)
                        .toolbarVisibility(showsLibrarySection ? .automatic : .hidden, for: .tabBar)
                }
                Tab("Search", systemImage: "magnifyingglass", value: TabKey.search, role: .search) {
                    SearchTab(query: $searchText, searchScope: $searchScope,
                              source: $searchSource,
                              submitRequest: searchSubmitRequest, setSearchFocus: setSearchFocus)
                        .id(session.client?.offlineAccountKey)
                        .searchable(text: $searchText, isPresented: $isSearchPresented,
                                    placement: .toolbar, prompt: searchSource.prompt)
                        .searchFocused($isSearchFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .writingToolsBehavior(.disabled)
                        .onSubmit(of: .search) {
                            guard selection == .search else { return }
                            searchSubmitRequest += 1
                            isSearchFocused = false
                        }
                }
                if showsLibrarySection {
                    TabSection("Library") {
                        Tab("Favorites", systemImage: "heart", value: TabKey.favorites) {
                            LibrarySectionTab(destination: .favorites)
                        }
                        if session.preferences?.peopleEnabled != false {
                            Tab("People", systemImage: "person.2", value: TabKey.people) {
                                LibrarySectionTab(destination: .people)
                            }
                        }
                        Tab("Places", systemImage: "mappin.and.ellipse", value: TabKey.places) {
                            LibrarySectionTab(destination: .places)
                        }
                        Tab("Archive", systemImage: "archivebox", value: TabKey.archive) {
                            LibrarySectionTab(destination: .archive)
                        }
                        Tab("Locked Folder", systemImage: "lock", value: TabKey.locked) {
                            LibrarySectionTab(destination: .locked)
                        }
                        if session.features?.trash != false {
                            Tab("Trash", systemImage: "trash", value: TabKey.trash) {
                                LibrarySectionTab(destination: .trash)
                            }
                        }
                        if session.capabilities.supportsSharedSpaces {
                            Tab("Shared Spaces", systemImage: "person.3", value: TabKey.spaces) {
                                LibrarySectionTab(destination: .spaces)
                            }
                        }
                    }
                    .defaultVisibility(.hidden, for: .tabBar)
                }
            }
            // Preserve native tab/search behavior and the iPad sidebar while
            // the compact browsing controls share one morphing glass surface.
            .tabViewStyle(.sidebarAdaptable)
            .task(id: selection) {
                guard selection == .search else { return }
                // Programmatic selection needs an explicit focus request once
                // the native search field has attached to its search-role tab.
                await Task.yield()
                guard selection == .search, !Task.isCancelled else { return }
                setSearchFocus(true)
            }
            .tabViewSearchActivation(.searchTabSelection)
            .tint(.primary)
            .environment(\.usesCompactPhotosNavigation, !showsLibrarySection && selection != .search)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !showsLibrarySection, selection != .search, !keyboardVisible,
               !hidesCompactNavigation, !(selection == .photos && photoControls.isSelecting) {
                PhotosNavigationBar(controls: photoControls, showsPeriods: showsDateNavigation,
                    selection: tabSelection, onSearch: {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
                            activateSearch()
                        }
                    })
                    // Match the native floating bar's clearance independently
                    // of the device's home-indicator safe area.
                    .padding(.bottom, 21 - bottomSafeArea)
                    .transition(.opacity)
            }
        }
        .onPreferenceChange(PhotosSelectionPreferenceKey.self) { hidesCompactNavigation = $0 }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: showsDateNavigation)
        .tabBarMinimizeBehavior(.never)
        .onChange(of: showsLibrarySection) { _, shows in
            // a section tab selected at regular width has nowhere to go once
            // the sidebar folds away, so the library list takes over.
            if !shows, selection.isLibrarySection { selection = .albums }
        }
        // leaving the locked folder for another tab locks it, whether or
        // not the folder's own disappearance fires on this tab style.
        .onChange(of: selection) { _, _ in
            session.lockedFolder?.lock()
            if selection != .search {
                isSearchPresented = false
                isSearchFocused = false
            }
        }
        .sheet(isPresented: $router.showsInbox) {
            NotificationsScreen()
        }
        .onChange(of: router.pendingAlbumID) { _, id in
            // the albums tab picks the id up itself; switching to it is what
            // makes the tab exist in the first place.
            if id != nil { selection = .albums }
        }
        .onChange(of: timelineRouter.pendingTarget) { _, target in
            if target != nil { selection = .photos }
        }
        .onChange(of: timelineRouter.searchRequested) { _, requested in
            if requested {
                activateSearch()
                timelineRouter.searchRequested = false
            }
        }
    }

    private func focusSearch() {
        setSearchFocus(true)
    }

    private func activateSearch() {
        if selection != .search {
            searchSource = selection == .photos ? PhotoSearchSource(librarySource: source) : .cloud
        }
        selection = .search
    }

    /// dropping focus keeps the field presented, so the typed query and the
    /// results it produced stay on screen with the keyboard gone.
    private func setSearchFocus(_ focused: Bool) {
        guard selection == .search else { return }
        if focused { isSearchPresented = true }
        isSearchFocused = focused
    }
}
