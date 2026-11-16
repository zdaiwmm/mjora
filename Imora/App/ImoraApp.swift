import SwiftUI
import UserNotifications

@main
struct ImoraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session: SessionStore
    @State private var appUpdates = AppUpdateStore()

    init() {
        #if DEBUG || PHASE4_PERFORMANCE
        if LaunchPresentationTrace.enabled { LaunchPresentationTrace.begin() }
        #endif
        // state is not installed during App.init. bind background processing
        // to the same retained instance that the scene receives, not a fresh
        // temporary instance produced by reading the wrapper too early.
        let session = SessionStore()
        _session = State(initialValue: session)
        AppDelegate.launchSession = session
        // set before any scene exists so a backup report landing mid-launch
        // is still presented.
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        ContinuedProcessing.registerAll()
        BackupProcessing.shared.register()
        BackupProcessing.shared.session = session
        session.backup?.scheduleRecovery()
        // Retire legacy daemon sessions and resume protected, account-bound
        // recovery queues while this process receives execution time.
        #if DEBUG && targetEnvironment(simulator)
        if Phase4OwnedFixture.automaticPreparationName == nil {
            BackgroundUploader.shared.attach()
            ShareUploadCoordinator.shared.attach()
        }
        #else
        BackgroundUploader.shared.attach()
        ShareUploadCoordinator.shared.attach()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(appUpdates)
        }
    }
}

/// exists for one callback: the system relaunches the app when background
/// uploads finish and hands over a completion handler that has to be called
/// once their events are delivered. the identifier routes between the backup
/// session and the sessions the share extension started.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static weak var launchSession: SessionStore?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if DEBUG || PHASE4_PERFORMANCE
        LaunchPipelineTrace.mark("uikit-did-finish-launching")
        #endif
        Self.launchSession?.noteLaunchProtection(available: application.isProtectedDataAvailable)
        return true
    }

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        Self.launchSession?.noteLaunchProtection(available: application.isProtectedDataAvailable)
    }

    func applicationProtectedDataWillBecomeUnavailable(_ application: UIApplication) {
        Self.launchSession?.noteLaunchProtection(available: false)
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier.hasPrefix(ShareTransfer.sessionPrefix) {
            ShareUploadCoordinator.shared.handleEvents(
                identifier: identifier,
                completion: ShareUploadCoordinator.LaunchCompletion(run: completionHandler)
            )
        } else {
            Self.launchSession?.restoreSessionIfAvailable()
            Self.launchSession?.backup?.startIfIdle()
            Self.launchSession?.backup?.scheduleRecovery()
            BackgroundUploader.shared.setBackgroundCompletionHandler(
                BackgroundUploader.LaunchCompletion(run: completionHandler), identifier: identifier
            )
        }
    }
}

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(AppUpdateStore.self) private var appUpdates
    @Environment(\.scenePhase) private var scenePhase

    #if DEBUG && targetEnvironment(simulator)
    private var automaticFixture: String? {
        Phase4OwnedFixture.automaticPreparationName
    }
    #endif

    var body: some View {
        Group {
            switch session.state {
            case .restoring:
                ProgressView("Restoring session...")
            case .loggedOut:
                LoginFlowView()
            case .loggedIn:
                MainTabView()
            }
        }
        .animation(.smooth, value: session.state)
        .task {
            #if DEBUG && targetEnvironment(simulator)
            if let name = automaticFixture {
                if let fixture = try? Phase4OwnedFixture.load(name), let url = URL(string: fixture.apiURL),
                   let login = try? await ImoraClient.login(apiURL: url, email: Phase4OwnedFixture.placeholderEmail,
                                                            password: Phase4OwnedFixture.placeholderPassword) {
                    await session.logIn(apiURL: url, response: login)
                }
                return
            }
            #endif
            session.restoreSessionIfAvailable()
            // never prompts at launch - access is asked from the timeline
            // banner or the backup settings instead. an already granted
            // session still primes here so device photos show even when
            // refreshuser cannot reach the server.
            guard PhotoLibraryService.hasFullAccess else { return }
            await session.backup?.primeLocalState()
            session.backup?.startIfIdle()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // A brief foreground excursion does not start a network check.
            // SwiftUI cancels this task when the app leaves the foreground.
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            await appUpdates.checkForUpdates(automatically: true)
        }
        .alert("App Update Available", isPresented: Binding(
            get: { appUpdates.alertRelease != nil },
            set: { if !$0 { appUpdates.dismissUpdateAlert() } }
        ), presenting: appUpdates.alertRelease) { release in
            Button("Install with Mac") {
                Task {
                    await appUpdates.confirmInstallation(of: release)
                    if let failure = appUpdates.failureMessage { ErrorToastCenter.shared.show(failure) }
                }
            }
            .accessibilityIdentifier("app-update-alert-confirm")
            Button("Later", role: .cancel) { appUpdates.dismissUpdateAlert() }
                .accessibilityIdentifier("app-update-alert-later")
        } message: { release in
            Text(release.installationConfirmationMessage)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                ImageLoadRecovery.shared.becameActive()
                session.restoreSessionIfAvailable()
                ShareUploadCoordinator.shared.resumePending()
                // returning to the foreground picks up photos taken meanwhile
                // and reconnects the realtime channel, which resyncs grids.
                #if DEBUG && targetEnvironment(simulator)
                if automaticFixture == nil { session.backup?.startIfIdle() }
                #else
                session.backup?.startIfIdle()
                #endif
                session.realtime?.setActive(true)
                Task { await session.favorites?.flush() }
                // the socket is down while backgrounded, so the inbox fetch is
                // what surfaces anything raised in the meantime.
                Task { await session.notifications?.load() }
                Task { await LocalNotifications.shared.refreshAuthorization() }
                PrivacyShieldWindow.shared.hide()
                // an inactive-only excursion keeps the folder open, so the
                // server's expiry is re-read on the way back.
                if session.lockedFolder?.isUnlocked == true {
                    Task { await session.lockedFolder?.refreshStatus() }
                }
            case .background:
                session.backup?.scheduleRecovery()
                session.realtime?.setActive(false)
                session.lockedFolder?.lock()
                Task { await session.backup?.flushPendingIndexChanges() }
            case .inactive:
                // the shield stays up through the background lock, so the
                // app switcher snapshot never holds the grid.
                if let locked = session.lockedFolder, locked.isUnlocked, locked.isScreenVisible {
                    PrivacyShieldWindow.shared.show()
                }
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataDidBecomeAvailableNotification
        )) { _ in
            ImageLoadRecovery.shared.protectedDataBecameAvailable()
            session.restoreSessionIfAvailable()
            ImageLoader.shared.configure(client: session.client)
            ShareUploadCoordinator.shared.resumePending()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataWillBecomeUnavailableNotification
        )) { _ in
            MediaPresentationCoordinator.shared.cancelCheckpoint()
            ImageLoader.shared.configure(client: nil)
            LocalImageLoader.shared.noteLibraryChange()
        }
    }
}
