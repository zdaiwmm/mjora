import SwiftUI
import UIKit

struct MainTabView: View {
    @Environment(SessionStore.self) private var session
    /// in-app navigation targets land here, so the shell owns both the inbox
    /// sheet and the tab switch an album deep link needs.
    @Bindable private var router = NotificationRouter.shared
    @Bindable private var timelineRouter = TimelineNavigationRouter.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PhotosLibrarySource.preferenceKey) private var source = "all"
    @State private var cloudControls = PhotosGridControls()
    @State private var deviceControls = PhotosGridControls()
    @State private var collectionCovers = CollectionsCoverStore()
    @State private var hidesCompactNavigation = false
    @State private var keyboardVisible = false
    @State private var browseSelection: TabKey = .photos
    @State private var searchSessionID: UUID?
    @State private var searchText = ""
    @State private var searchScope: SearchFilter.TextType = .context
    @State private var searchSource: PhotoSearchSource = .cloud
    @State private var searchSubmitRequest = 0
    @State private var compactFocus = CompactPhotoSearchBar.FocusRequest(focused: false)
    @FocusState private var isSearchFocused: Bool

    private var selection: TabKey { searchSessionID == nil ? browseSelection : .search }

    private var tabSelection: Binding<TabKey> {
        Binding(get: { showsLibrarySection ? selection : browseSelection }, set: selectTab)
    }

    private var searchPresentation: Binding<Bool> {
        let presentedSessionID = searchSessionID
        return Binding(get: {
            presentedSessionID != nil && searchSessionID == presentedSessionID
        }, set: { presented in
            guard !presented, let presentedSessionID, searchSessionID == presentedSessionID else { return }
            closeSearch()
        })
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
            && photoControls.showsPeriodNavigation
    }

    var body: some View {
        GeometryReader { geometry in
            content(bottomSafeArea: geometry.safeAreaInsets.bottom)
        }
        .task(id: session.client?.context.id) { await OfflineAlbumDownloads.shared.attach(session.client) }
        .task(id: session.client?.context.id) {
            collectionCovers.reset(client: session.client)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { OfflineAlbumDownloads.shared.pauseAll() }
        }
    }

    private func content(bottomSafeArea: CGFloat) -> some View {
        let showsCompactSearch = !showsLibrarySection && searchSessionID != nil
        return ZStack {
            browseShell(bottomSafeArea: bottomSafeArea)
                .ignoresSafeArea(showsLibrarySection ? [] : .keyboard, edges: .bottom)
                .allowsHitTesting(!showsCompactSearch)
                .accessibilityHidden(showsCompactSearch)

            if showsCompactSearch, let searchSessionID {
                NavigationStack {
                    SearchTab(query: $searchText, searchScope: $searchScope, source: $searchSource,
                              submitRequest: searchSubmitRequest, usesCompactPresentation: true,
                              setSearchFocus: setSearchFocus)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            CompactPhotoSearchBar(query: $searchText, prompt: searchSource.prompt,
                                                  focus: compactFocus, onSubmit: submitSearch,
                                                  onClose: closeSearch)
                        }
                }
                .id(searchSessionID)
                .background { Color(uiColor: .systemBackground).ignoresSafeArea() }
                .tint(.primary)
            }
        }
    }

    private func browseShell(bottomSafeArea: CGFloat) -> some View {
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
                        .environment(\.usesCompactPhotosNavigation, !showsLibrarySection)
                }
                Tab("Collections", systemImage: selection == .albums ? "rectangle.stack.fill" : "rectangle.stack", value: TabKey.albums) {
                    AlbumsTab(account: session.client?.offlineAccountKey, covers: collectionCovers)
                        .id(session.client?.offlineAccountKey)
                        .environment(\.usesCompactPhotosNavigation, !showsLibrarySection)
                        .toolbarVisibility(showsLibrarySection ? .automatic : .hidden, for: .tabBar)
                }
                if showsLibrarySection {
                    Tab("Search", systemImage: "magnifyingglass", value: TabKey.search, role: .search) {
                        NavigationStack {
                            SearchTab(query: $searchText, searchScope: $searchScope, source: $searchSource,
                                      submitRequest: searchSubmitRequest, setSearchFocus: setSearchFocus)
                        }
                        .id(session.client?.offlineAccountKey)
                        .searchable(text: $searchText, isPresented: searchPresentation,
                                    placement: .toolbar, prompt: searchSource.prompt)
                        .searchPresentationToolbarBehavior(.avoidHidingContent)
                        .searchFocused($isSearchFocused)
                        .task(id: searchSessionID) {
                            guard let request = searchSessionID else { return }
                            await Task.yield()
                            guard !Task.isCancelled, searchSessionID == request else { return }
                            setSearchFocus(true)
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .writingToolsBehavior(.disabled)
                        .onSubmit(of: .search, submitSearch)
                    }
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
            .tabViewSearchActivation(.searchTabSelection)
            .tint(.primary)
        }
        .overlay(alignment: .bottom) {
            if !showsLibrarySection, selection != .search, !keyboardVisible,
               !hidesCompactNavigation, !(selection == .photos && photoControls.isSelecting) {
                PhotosNavigationBar(controls: photoControls, showsPeriods: showsDateNavigation,
                    selection: tabSelection, onSearch: activateSearch)
                    // Match the native floating bar's clearance independently
                    // of the device's home-indicator safe area.
                    .padding(.bottom, PhotosNavigationBar.bottomScreenClearance - bottomSafeArea)
                    .transition(.opacity)
            }
        }
        .onPreferenceChange(PhotosSelectionPreferenceKey.self) { hidesCompactNavigation = $0 }
        .task { await Task.detached(priority: .utility) { PhotoPlaceName.prepare() }.value }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .tabBarMinimizeBehavior(.never)
        .onChange(of: showsLibrarySection) { _, shows in
            // a section tab selected at regular width has nowhere to go once
            // the sidebar folds away, so the library list takes over.
            if !shows, browseSelection.isLibrarySection { browseSelection = .albums }
            if searchSessionID != nil { setSearchFocus(true) }
        }
        // leaving the locked folder for another tab locks it, whether or
        // not the folder's own disappearance fires on this tab style.
        .onDisappear { session.cachedLaunchHandle?.cancel() }
        .onChange(of: selection) { _, _ in
            if selection != .photos { session.cachedLaunchHandle?.cancel() }
            session.lockedFolder?.lock()
        }
        .sheet(isPresented: $router.showsInbox) {
            NotificationsScreen()
        }
        .onChange(of: router.pendingAlbumID) { _, id in
            // the albums tab picks the id up itself; switching to it is what
            // makes the tab exist in the first place.
            if id != nil { selectTab(.albums) }
        }
        .onChange(of: timelineRouter.pendingTarget) { _, target in
            if target != nil { selectTab(.photos) }
        }
        .onChange(of: timelineRouter.searchRequest) { _, request in
            if let request {
                activateSearch(source: request.source)
                timelineRouter.searchRequest = nil
            }
        }
    }

    private func selectTab(_ tab: TabKey) {
        if tab == .search {
            activateSearch(source: selection == .search ? searchSource : .cloud)
        } else {
            browseSelection = tab
            closeSearch()
        }
    }

    private func activateSearch() {
        activateSearch(source: .cloud)
    }

    private func activateSearch(source: PhotoSearchSource) {
        let alreadyPresented = searchSessionID != nil
        if !alreadyPresented || searchSource != source { searchText = "" }
        searchSource = source
        if !alreadyPresented { searchSessionID = UUID() }
        if !showsLibrarySection || alreadyPresented { setSearchFocus(true) }
    }

    private func submitSearch() {
        guard selection == .search else { return }
        searchSubmitRequest += 1
        setSearchFocus(false)
    }

    private func closeSearch() {
        guard searchSessionID != nil else { return }
        setSearchFocus(false)
        searchSessionID = nil
    }

    /// dropping focus keeps the field presented, so the typed query and the
    /// results it produced stay on screen with the keyboard gone.
    private func setSearchFocus(_ focused: Bool) {
        guard selection == .search else { return }
        if showsLibrarySection {
            isSearchFocused = focused
        } else {
            compactFocus = .init(focused: focused)
        }
    }
}
