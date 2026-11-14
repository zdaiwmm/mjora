import SwiftUI

struct MainTabView: View {
    @Environment(SessionStore.self) private var session
    /// in-app navigation targets land here, so the shell owns both the inbox
    /// sheet and the tab switch an album deep link needs.
    @Bindable private var router = NotificationRouter.shared
    @Bindable private var timelineRouter = TimelineNavigationRouter.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: TabKey = .photos
    @State private var searchText = ""
    @State private var searchScope: SearchFilter.TextType = .context
    @State private var searchSubmitRequest = 0
    @State private var isSearchPresented = false
    @FocusState private var isSearchFocused: Bool

    private var tabSelection: Binding<TabKey> {
        Binding(
            get: { selection },
            set: { tab in
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

    var body: some View {
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
                Tab("Photos", systemImage: "photo.on.rectangle.angled", value: TabKey.photos) {
                    TimelineTab()
                }
                Tab("Albums", systemImage: "rectangle.stack", value: TabKey.albums) {
                    AlbumsTab()
                }
                // the tab bar keeps the library as one entry that lists its
                // destinations; the ipad sidebar spells them out below
                // instead, the way photos lays its own sidebar out.
                Tab("Library", systemImage: "books.vertical", value: TabKey.library) {
                    LibraryTab()
                }
                .defaultVisibility(.hidden, for: .sidebar)
                Tab("Search", systemImage: "magnifyingglass", value: TabKey.search, role: .search) {
                    SearchTab(query: $searchText, searchScope: $searchScope,
                              submitRequest: searchSubmitRequest, setSearchFocus: setSearchFocus)
                        .searchable(text: $searchText, isPresented: $isSearchPresented, prompt: searchScope.prompt)
                        .searchFocused($isSearchFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .writingToolsBehavior(.disabled)
                        .onSubmit(of: .search) {
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
            // a plain tab bar on iphone, a tab bar with a sidebar on ipad.
            .tabViewStyle(.sidebarAdaptable)
            .tabViewSearchActivation(.searchTabSelection)
        }
        .tabBarMinimizeBehavior(selection == .search ? .never : .onScrollDown)
        .onChange(of: showsLibrarySection) { _, shows in
            // a section tab selected at regular width has nowhere to go once
            // the sidebar folds away, so the library list takes over.
            if !shows, selection.isLibrarySection { selection = .library }
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
    }

    private func focusSearch() {
        setSearchFocus(true)
    }

    /// dropping focus keeps the field presented, so the typed query and the
    /// results it produced stay on screen with the keyboard gone.
    private func setSearchFocus(_ focused: Bool) {
        guard selection == .search else { return }
        if focused { isSearchPresented = true }
        isSearchFocused = focused
    }
}
