import Foundation
import Observation
import UIKit

nonisolated struct ProfileImageMutationToken {
    fileprivate let id: UUID
    fileprivate let previousData: Data?
    fileprivate let previousCacheKey: String?
}

/// holds the login state for the whole app.
@Observable
final class SessionStore {
    enum State: Equatable {
        case restoring
        case loggedOut
        case loggedIn
    }

    private(set) var state: State = .restoring
    private(set) var client: ImoraClient?
    private(set) var user: CurrentUser?
    private(set) var features: ServerFeatures?
    /// gates ui for api shapes older servers reject, e.g. search v2 filters.
    /// the immich api level, which on gallery is not the version it reports.
    private(set) var serverVersion: ServerVersion?
    /// immich, noodle's gallery or imora, detected apart from the version
    /// since gallery and imora report their own releases.
    private(set) var serverIdentity: ServerIdentity?
    var serverProduct: ServerProduct? { serverIdentity?.product }
    var capabilities: ServerCapabilities {
        ServerCapabilities(identity: serverIdentity, version: serverVersion, passkeyEnabled: features?.passkey)
    }
    /// tags need the user's preference and a server that serves them.
    var showsTags: Bool {
        capabilities.supportsTags && preferences?.tagsEnabled != false
    }
    @ObservationIgnored private let launchProtection = LaunchProtectionGate()
    @ObservationIgnored private(set) var cachedLaunchHandle: CachedLaunchHandle?
    private(set) var backup: BackupManager?
    private(set) var favorites: PhotoFavoriteCoordinator?
    private(set) var realtime: RealtimeHub?
    private(set) var lockedFolder: LockedFolderSession?
    private(set) var notifications: NotificationInbox?
    private(set) var preferences: UserPreferences?
    private(set) var loginNotice: String?
    /// Keeps a newly selected avatar visible while the server accepts and
    /// re-caches the same bytes. A rejected upload restores the prior value.
    var optimisticProfileImageData: Data? {
        didSet {
            optimisticProfileImage = optimisticProfileImageData.flatMap { UIImage(data: $0) }
        }
    }
    /// decoded once when the bytes land. avatars used to rebuild a uiimage
    /// from the raw picked photo on every body pass while an upload ran.
    private(set) var optimisticProfileImage: UIImage?
    var profileImageCacheKey: String?
    private(set) var isProfileImageMutationInFlight = false
    @ObservationIgnored private var profileImageMutationID: UUID?
    @ObservationIgnored private var preferenceProjectionRevisions: [String: Int] = [:]
    @ObservationIgnored private var pendingPreferenceMutationCounts: [String: Int] = [:]
    @ObservationIgnored private var refreshUserRevision = 0
    @ObservationIgnored private var favoriteIdentityTask: Task<Void, Never>?

    private static let serverKey = "imora.serverURL"
    private static let tokenKey = "accessToken"
    private static let loginSessionKey = "loginSessionKey"
    private static let loginNoticeDefaultsKey = "imora.loginNotice"
    private static let profileImageCacheKeyDefaultsKey = "imora.profileImageCacheKey"

    var serverURL: URL? {
        UserDefaults.standard.url(forKey: Self.serverKey)
    }

    /// a stored session is adopted before the first frame, so there is no
    /// launch spinner: the tabs come up on cached account details and the
    /// server confirms them in the background. an expired token only shows
    /// once the refresh comes back 401.
    init() {
        #if DEBUG || PHASE4_PERFORMANCE
        LaunchPipelineTrace.mark("session-store-init")
        #endif
        loginNotice = UserDefaults.standard.string(forKey: Self.loginNoticeDefaultsKey)
        profileImageCacheKey = UserDefaults.standard.string(
            forKey: Self.profileImageCacheKeyDefaultsKey
        )
        restoreSessionIfAvailable()
    }

    /// retries a keychain read that was blocked while protected data was unavailable.
    func restoreSessionIfAvailable() {
        guard state == .restoring else { return }
        guard let apiURL = serverURL else {
            state = .loggedOut
            return
        }
        let token: String
        switch KeychainStore.get(Self.tokenKey) {
        case .value(let storedToken):
            token = storedToken
        case .missing:
            state = .loggedOut
            return
        case .unavailable:
            return
        }
        guard ImoraClient.supportsTransport(to: apiURL) else {
            KeychainStore.delete(Self.tokenKey)
            SessionCache.clear()
            ShareTransfer.defaults?.removeObject(forKey: ShareTransfer.serverURLKey)
            ShareTransfer.defaults?.removeObject(forKey: ShareTransfer.deviceIdKey)
            let notice = String(localized: "Your saved server address is invalid. Sign in again with an HTTP or HTTPS address.")
            loginNotice = notice
            UserDefaults.standard.set(notice, forKey: Self.loginNoticeDefaultsKey)
            state = .loggedOut
            return
        }
        // re-setting moves tokens from before keychain sharing into the app
        // group access group, and the mirror keeps the extension current.
        KeychainStore.set(token, for: Self.tokenKey)
        // Migrate an existing credential once; cold launches reuse this key.
        // Account history remains keyed by server and user, outside this session.
        if case .missing = KeychainStore.get(Self.loginSessionKey) {
            KeychainStore.set(UUID().uuidString, for: Self.loginSessionKey)
        }
        mirrorForShareExtension(apiURL: apiURL)
        let cached = SessionCache.load(host: ServerTrustPolicy(apiURL: apiURL).canonicalRoot)
        features = cached?.features
        // a snapshot from before product detection may hold a gallery release
        // number, which reads as an immich level the server never had.
        serverIdentity = cached?.serverIdentity ?? cached?.serverProduct.map {
            ServerIdentity(product: $0, features: cached?.serverFeatures.map(Set.init))
        }
        serverVersion = serverIdentity == nil ? nil : cached?.serverVersion
        preferences = cached?.preferences
        let restoredClient = ImoraClient(apiURL: apiURL, accessToken: token)
        guard prepareMediaRecoveryNamespace(restoredClient) else {
            restoredClient.invalidate()
            state = UIApplication.shared.isProtectedDataAvailable ? .loggedOut : .restoring
            return
        }
        adopt(client: restoredClient, user: cached?.user)
    }

    func logIn(apiURL: URL, response: LoginResponse) async {
        loginNotice = nil
        UserDefaults.standard.removeObject(forKey: Self.loginNoticeDefaultsKey)
        UserDefaults.standard.set(apiURL, forKey: Self.serverKey)
        KeychainStore.set(response.accessToken, for: Self.tokenKey)
        KeychainStore.set(UUID().uuidString, for: Self.loginSessionKey)
        mirrorForShareExtension(apiURL: apiURL, renew: true)
        SessionCache.noteUserId(response.userId)
        let client = ImoraClient(apiURL: apiURL, accessToken: response.accessToken)
        let user = try? await client.currentUser()
        if let user { client.confirmMediaAccount(user.id) }
        guard prepareMediaRecoveryNamespace(client) else { client.invalidate(); state = .loggedOut; return }
        adopt(client: client, user: user)
    }

    func consumeLoginNotice() -> String? {
        defer { loginNotice = nil }
        UserDefaults.standard.removeObject(forKey: Self.loginNoticeDefaultsKey)
        return loginNotice
    }

    func logOut(reportRemoteFailure: Bool = true) async {
        cachedLaunchHandle?.cancel(); cachedLaunchHandle = nil
        let signingOutClient = client
        ShareTransfer.revoke()
        ShareUploadCoordinator.shared.cancelAll()
        MediaPresentationCoordinator.shared.cancelCheckpoint()
        ImageLoader.shared.configure(client: nil)
        refreshUserRevision &+= 1
        KeychainStore.delete(Self.tokenKey)
        KeychainStore.delete(Self.loginSessionKey)
        LocalServerRouter.shared.deactivate()
        SessionCache.clear()
        RecentSearches.eraseAll()
        realtime?.shutdown()
        realtime = nil
        favorites?.shutdown()
        favorites = nil
        favoriteIdentityTask?.cancel()
        favoriteIdentityTask = nil
        lockedFolder?.shutdown()
        lockedFolder = nil
        backup?.shutdown()
        backup = nil
        notifications?.clear()
        notifications = nil
        ShareTransfer.defaults?.removeObject(forKey: ShareTransfer.serverURLKey)
        ShareTransfer.defaults?.removeObject(forKey: ShareTransfer.deviceIdKey)
        ContinuedProcessing.backup.workload = nil
        client = nil
        user = nil
        features = nil
        serverVersion = nil
        serverIdentity = nil
        preferences = nil
        preferenceProjectionRevisions = [:]
        pendingPreferenceMutationCounts = [:]
        optimisticProfileImageData = nil
        profileImageCacheKey = nil
        isProfileImageMutationInFlight = false
        profileImageMutationID = nil
        state = .loggedOut

        guard let signingOutClient else { return }
        // Revoke the working context immediately; logout uses a separate,
        // narrowly scoped client so old UI tasks cannot resume during await.
        signingOutClient.invalidate()
        let logoutClient = ImoraClient(apiURL: signingOutClient.apiURL, accessToken: signingOutClient.accessToken)
        defer { logoutClient.invalidate() }
        do {
            try await logoutClient.logout()
        } catch where reportRemoteFailure {
            ErrorToastCenter.shared.show(
                String(localized: "Signed out on this device, but couldn't close the server session"),
                error: error
            )
        } catch {
            // An already rejected session is locally complete; no rollback is
            // safe or useful for a best-effort remote logout.
        }
    }

    func refreshUser() async {
        guard let client else { return }
        refreshUserRevision &+= 1
        let revision = refreshUserRevision
        // the user call doubles as the token check the launch no longer waits
        // for: a rejected token ends the session here instead of leaving the
        // app pointed at a server that will refuse everything.
        do {
            let user = try await client.currentUser()
            guard revision == refreshUserRevision, self.client === client else { return }
            self.user = user
            client.confirmMediaAccount(user.id)
            SessionCache.noteUserId(user.id)
            configureFavorites(client: client)
            backup?.userId = user.id
            await backup?.primeLocalState()
        } catch ImoraError.http(401, _) {
            guard revision == refreshUserRevision, self.client === client else { return }
            await logOut(reportRemoteFailure: false)
            return
        } catch {
            // offline or transient: keep the cached account details.
        }
        guard revision == refreshUserRevision, self.client === client else { return }
        let preferenceRevisionsAtRequest = preferenceProjectionRevisions
        let pendingPreferenceFieldsAtRequest = Set(
            pendingPreferenceMutationCounts.lazy.filter { $0.value > 0 }.map(\.key)
        )
        async let featuresTask = try? client.serverFeatures()
        async let preferencesTask = try? client.preferences()
        if let features = await featuresTask,
           revision == refreshUserRevision,
           self.client === client {
            self.features = features
        }
        if let fetched = await preferencesTask {
            guard revision == refreshUserRevision, self.client === client else { return }
            preferences = mergedPreferences(
                fetched,
                preservingChangesSince: preferenceRevisionsAtRequest,
                pendingAtRequest: pendingPreferenceFieldsAtRequest
            )
        }
        cacheSnapshot()
    }

    /// called after the user grants library access mid-session, so the change
    /// observer, badges and auto backup pick it up without a relaunch.
    func adoptPhotoAccess() async {
        await backup?.primeLocalState()
        backup?.startIfIdle()
    }

    /// portrait url for a person, carrying a cache-buster: the socket's key
    /// when this session watched the server re-render them, otherwise the
    /// person's own updatedAt, which is what catches a change made on another
    /// device while imora was closed. every avatar goes through here so a new
    /// featured photo shows up everywhere at once.
    func personThumbnailURL(_ person: Person) -> URL? {
        client?.personThumbnailURL(
            personID: person.id,
            cacheKey: realtime?.personThumbnailKeys[person.id] ?? person.updatedAt
        )
    }

    func beginProfileImageMutation(data: Data) -> ProfileImageMutationToken? {
        guard !isProfileImageMutationInFlight else { return nil }
        let token = ProfileImageMutationToken(
            id: UUID(),
            previousData: optimisticProfileImageData,
            previousCacheKey: profileImageCacheKey
        )
        profileImageMutationID = token.id
        isProfileImageMutationInFlight = true
        optimisticProfileImageData = data
        return token
    }

    func projectPreferences(_ projection: UserPreferences, field: String) {
        preferenceProjectionRevisions[field, default: 0] &+= 1
        preferences = projection
    }

    func setPreferenceMutation(_ field: String, active: Bool) {
        if active {
            pendingPreferenceMutationCounts[field, default: 0] += 1
        } else {
            let remaining = max(0, pendingPreferenceMutationCounts[field, default: 0] - 1)
            if remaining == 0 {
                pendingPreferenceMutationCounts[field] = nil
            } else {
                pendingPreferenceMutationCounts[field] = remaining
            }
        }
    }

    /// Installs a cache-busting URL only for the still-current upload.
    func acceptProfileImageMutation(
        _ token: ProfileImageMutationToken,
        cacheKey: String
    ) -> Bool {
        guard profileImageMutationID == token.id else { return false }
        profileImageCacheKey = cacheKey
        UserDefaults.standard.set(cacheKey, forKey: Self.profileImageCacheKeyDefaultsKey)
        return true
    }

    func finishProfileImageMutation(
        _ token: ProfileImageMutationToken,
        canonicalImageIsCached: Bool
    ) {
        guard profileImageMutationID == token.id else { return }
        if canonicalImageIsCached { optimisticProfileImageData = nil }
        profileImageMutationID = nil
        isProfileImageMutationInFlight = false
    }

    func rollbackProfileImageMutation(_ token: ProfileImageMutationToken) {
        guard profileImageMutationID == token.id else { return }
        optimisticProfileImageData = token.previousData
        profileImageCacheKey = token.previousCacheKey
        profileImageMutationID = nil
        isProfileImageMutationInFlight = false
    }

    private func mergedPreferences(
        _ fetched: UserPreferences,
        preservingChangesSince snapshot: [String: Int],
        pendingAtRequest: Set<String>
    ) -> UserPreferences {
        guard let current = preferences else { return fetched }
        let changed: (String) -> Bool = { key in
            self.preferenceProjectionRevisions[key, default: 0] != snapshot[key, default: 0]
        }
        var fields = pendingAtRequest
        fields.formUnion(["memories", "people", "peopleUpdateStrategy", "email"].filter(changed))
        return fetched.preservingProjectedFields(
            from: current,
            fields: fields
        )
    }

    /// the share extension uploads with this session, and the app group is
    /// all it can read.
    private func mirrorForShareExtension(apiURL: URL, renew: Bool = false) {
        guard case .value(let token) = KeychainStore.get(Self.tokenKey) else { return }
        ShareTransfer.mirror(apiURL: apiURL, token: token, deviceID: DeviceID.current, renew: renew)
    }

    private func cacheSnapshot() {
        guard let host = client?.serverKey else { return }
        SessionCache.save(
            SessionCache.Snapshot(host: host, user: user, features: features, serverVersion: serverVersion,
                                  serverProduct: serverProduct,
                                  serverFeatures: serverIdentity?.features.map { $0.sorted() },
                                  serverIdentity: serverIdentity,
                                  preferences: preferences)
        )
    }

    /// probed first thing at launch and sign-in, version and product side by
    /// side. what the app sends and offers follows them, so 3.0 and 3.1
    /// servers keep the flat search and legacy endpoints while 3.2 gets search
    /// v2 and /config, and gallery gets its spaces. the cached values only
    /// cover the first frames until this answers.
    private func detectServerVersion(_ client: ImoraClient) async {
        async let probedIdentity = client.serverIdentity()
        let version = await client.serverVersion()
        let identity = await probedIdentity
        guard self.client === client else { return }
        var changed = false
        if let version, serverVersion != version {
            serverVersion = version
            changed = true
        }
        if let identity, serverIdentity != identity {
            serverIdentity = identity
            changed = true
        }
        if changed { cacheSnapshot() }
    }

    /// a version change on reconnect means the server was upgraded, rolled
    /// back or swapped between immich and gallery underneath the app; the
    /// features come from other endpoints then. the announced version is the
    /// reported one, so the gating level always comes from a fresh detection.
    /// the identity the session holds is compared too, so imora's feature
    /// list refreshes after an upgrade even when the client saw no change.
    private func adoptServerVersion(_ version: ServerVersion, from client: ImoraClient) {
        guard self.client === client else { return }
        let previous = client.noteServerVersion(version)
        let detected = serverIdentity?.reportedVersion
        let isStale = previous.map { $0 != version } == true || detected.map { $0 != version } == true
        guard isStale else {
            // cached after the first probe, so this costs nothing on reconnects.
            Task { await detectServerVersion(client) }
            return
        }
        client.forgetServerDetection()
        Task {
            await detectServerVersion(client)
            await refreshUser()
        }
    }

    func noteLaunchProtection(available: Bool) {
        launchProtection.resolve(available)
        #if DEBUG || PHASE4_PERFORMANCE
        LaunchPipelineTrace.mark("uikit-protected-data-state", items: available ? 1 : 0)
        #endif
        if !available { cachedLaunchHandle?.cancel() }
    }

    private func adopt(client: ImoraClient, user: CurrentUser?) {
        cachedLaunchHandle?.cancel(); cachedLaunchHandle = nil
        if let previous = self.client, previous !== client {
            previous.invalidate()
            ShareUploadCoordinator.shared.cancelAll()
            backup?.shutdown()
            realtime?.shutdown()
            favorites?.shutdown()
            favorites = nil
            favoriteIdentityTask?.cancel()
            favoriteIdentityTask = nil
        }
        LocalServerRouter.shared.activate(external: client.apiURL)
        if profileImageCacheKey == nil {
            profileImageCacheKey = UserDefaults.standard.string(
                forKey: Self.profileImageCacheKeyDefaultsKey
            )
        }
        self.client = client
        #if DEBUG || PHASE4_PERFORMANCE
        LaunchPipelineTrace.mark("verified-session-ready", items: client.mediaDisplayScope.accountID == nil ? 0 : 1)
        #endif
        client.setMediaRecoveryHandler { [weak self, weak client] outcome, notice in
            guard let self, let client, self.client === client, let notice else { return }
            self.loginNotice = notice
            UserDefaults.standard.set(notice, forKey: Self.loginNoticeDefaultsKey)
            if outcome == .signInRequired {
                // Local recovery only. No remote logout, queue deletion, draft
                // deletion or backup-proof mutation is authorized here.
                self.realtime?.shutdown(); self.realtime = nil
                self.favorites?.shutdown(); self.favorites = nil
                self.backup?.shutdown(); self.backup = nil
                self.lockedFolder?.shutdown(); self.lockedFolder = nil
                self.notifications = nil
                self.cachedLaunchHandle?.cancel(); self.cachedLaunchHandle = nil
                self.client = nil; self.user = nil
                self.state = .loggedOut
            } else { ErrorToastCenter.shared.show(notice) }
        }
        self.user = user
        lockedFolder = LockedFolderSession(client: client)
        ImageLoader.shared.configure(client: client)
        let backup = BackupManager(client: client)
        if case .value(let key) = KeychainStore.get(Self.loginSessionKey) { backup.loginSessionKey = key }
        backup.userId = user?.id
        self.backup = backup
        let source = UserDefaults.standard.string(forKey: "imora.photos.source") ?? "cloud"
        let startupFilter = source == "local" ? "device|all|date" : TimelineCache.key(for:
            PhotosLaunchSelection.cloudFilter(mergesSharedSpaces: capabilities.mergesSharedSpacesIntoTimeline))
        if client.mediaDisplayScope.accountID != nil, ["cloud", "local"].contains(source), let filterKey = startupFilter {
            let packSource = source == "local" ? "device" : "cloud"
            let validator = backup.launchSurfaceValidator()
            let protection = launchProtection
            if UIApplication.shared.isProtectedDataAvailable { protection.resolve(true) }
            let coordinator = MediaPresentationCoordinator.shared
            let handle = CachedLaunchHandle(client: client, source: packSource, filter: filterKey) {
                #if DEBUG || PHASE4_PERFORMANCE
                LaunchPipelineTrace.mark("cached-bootstrap-start")
                #endif
                guard await protection.value(), !Task.isCancelled, await validator.prepare() else { return nil }
                let result = try? await coordinator.restore(client: client, filter: filterKey, layout: nil,
                    protectedDataAvailable: true, validateLocalSurface: { provenance in
                        if provenance.remoteIdentifier == nil { return true }
                        return await validator.validate(provenance)
                    }, localEvidenceIsCurrent: { protection.isAvailable && validator.isCurrent() }, validateRemoteSurface: validator.validateRemote)
                #if DEBUG || PHASE4_PERFORMANCE
                LaunchPipelineTrace.mark("cached-bootstrap-prepared-ready")
                #endif
                return result
            }
            cachedLaunchHandle = handle
            backup.cachedLaunchHandle = handle
        }
        let hub = RealtimeHub(client: client)
        backup.onLocalChange = { [weak hub] in hub?.notifyLocalChange() }
        backup.onRunFailed = { message in
            LocalNotifications.shared.deliverBackupFailure(message)
        }
        ContinuedProcessing.backup.workload = backup
        hub.onBackupReconciliationNeeded = { [weak backup] generation in backup?.requestRemoteReconciliation(generation: generation) }
        hub.onBackupConnectionGap = { [weak backup] in backup?.noteRemoteConnectionGap() }
        hub.onRemoteBackupChange = { [weak backup] ids, change in backup?.noteRemoteChange(ids, change: change) }
        hub.onRemoteEdit = { [weak backup] ids in backup?.noteRemoteEdits(ids) }
        hub.onServerVersion = { [weak self, weak client] version in
            guard let self, let client else { return }
            self.adoptServerVersion(version, from: client)
        }
        realtime = hub
        configureFavorites(client: client)
        let inbox = NotificationInbox(client: client)
        hub.addListener(inbox)
        notifications = inbox
        state = .loggedIn
        #if DEBUG || PHASE4_PERFORMANCE
        LaunchPipelineTrace.mark("session-adopt-complete")
        #endif
        ShareUploadCoordinator.shared.resumePending()
        // the index is on disk and the account is cached, so the pairing maps
        // that let tiles render from the device are ready before the server
        // has answered; refreshUser primes again once the account is confirmed.
        Task { await backup.primeLocalState() }
        Task { await detectServerVersion(client) }
        Task { await refreshUser() }
        Task { await inbox.load() }
        backup.startIfIdle()
        hub.setActive(true)
    }

    private func prepareMediaRecoveryNamespace(_ client: ImoraClient) -> Bool {
        switch KeychainStore.get(KeychainStore.mediaRecoveryFenceKey) {
        case .missing: return true
        case .unavailable: return false
        case .value(let fence):
            do {
                try MediaContentGenerations.shared.rollover()
                _ = KeychainStore.removeIfMatching(fence, for: KeychainStore.mediaRecoveryFenceKey)
                return true
            } catch {
                let notice = String(localized: "Photos are temporarily unavailable. Your edits are preserved. Reopen the app and try again.")
                loginNotice = notice; UserDefaults.standard.set(notice, forKey: Self.loginNoticeDefaultsKey)
                ErrorToastCenter.shared.show(notice)
                return false
            }
        }
    }

    private func configureFavorites(client: ImoraClient) {
        guard self.client === client,
              let account = FavoriteAccountIdentity.key(server: client.serverKey,
                userID: user?.id ?? SessionCache.lastKnownUserId,
                credentialScope: client.offlineAccountKey),
              favorites?.account != account else { return }
        if let provisional = favorites?.account, provisional.hasPrefix("credential:") {
            if favorites?.isIdle == false {
                guard favoriteIdentityTask == nil else { return }
                favoriteIdentityTask = Task { [weak self, weak client, weak previous = favorites] in
                    await previous?.waitUntilIdle()
                    guard !Task.isCancelled, let self, let client, let previous,
                          self.client === client, self.favorites === previous else { return }
                    self.favoriteIdentityTask = nil
                    self.configureFavorites(client: client)
                }
                return
            }
            do { try FavoriteIntentStore.shared.confirmAccount(credentialScope: provisional, account: account) }
            catch { return } // Keep the existing authenticated queue usable.
        }
        favorites?.shutdown()
        let favorites = PhotoFavoriteCoordinator(account: account,
            writeLocal: { id, value in
                try await LocalFavoriteWriter.set(localIdentifier: id, value: value)
            }, writeRemote: { [weak client] id, value in
                guard let client else { throw CancellationError() }
                try await client.setFavorite(ids: [id], value)
            })
        favorites.onChange = { [weak self, weak client] in
            guard let self, let client, self.client === client else { return }
            self.realtime?.notifyLocalChange()
        }
        self.favorites = favorites
        favorites.start()
    }

    func projectingFavorite(_ asset: Asset) -> Asset {
        // PhotoKit is authoritative for the device source. A pending cloud
        // write must never pretend an inaccessible device photo was changed.
        guard !asset.isLocal,
              let value = favorites?.pendingValue(remoteID: asset.id) else { return asset }
        var projected = asset
        projected.isFavorite = value
        return projected
    }

    func setFavorite(_ asset: Asset, value: Bool) async throws -> FavoriteMutationResult {
        guard let favorites else { throw PhotoFavoriteCoordinator.Failure.inactive }
        let paired = backup?.pairedLocalIdentifierByRemoteId[asset.id]
        let localID = asset.localIdentifier ?? paired.flatMap {
            LocalFavoriteWriter.isAccessible($0) ? $0 : nil
        }
        let remoteID = asset.isLocal
            ? asset.localIdentifier.flatMap { backup?.remoteIdentifierByLocalId[$0] }
            : asset.id
        return try await favorites.set(localID: localID, remoteID: remoteID, value: value)
    }
}

nonisolated extension UserPreferences {
    func preservingProjectedFields(
        from projected: UserPreferences,
        fields: Set<String>
    ) -> UserPreferences {
        UserPreferences(
            memories: fields.contains("memories") ? projected.memories : memories,
            people: mergingPeople(from: projected, fields: fields),
            folders: folders,
            ratings: ratings,
            tags: tags,
            sharedLinks: sharedLinks,
            emailNotifications: fields.contains("email")
                ? projected.emailNotifications
                : emailNotifications
        )
    }

    /// the switch and the update strategy share the people section but are
    /// projected on their own.
    private func mergingPeople(from projected: UserPreferences, fields: Set<String>) -> PeoplePreferences? {
        let enabled = fields.contains("people") ? projected.people : people
        let strategy = fields.contains("peopleUpdateStrategy") ? projected.people : people
        guard let base = enabled ?? strategy else { return nil }
        return PeoplePreferences(enabled: base.enabled, updateStrategy: strategy?.updateStrategy)
    }
}
