import AVFoundation
import Photos
import SwiftUI

/// the app's default ambient audio session is silenced by the ring switch.
/// claiming playback before audible video makes sound play regardless, like
/// the system photos app. the actor keeps the category flag race-free and the
/// blocking session calls off the main thread.
private actor ViewerAudioSession {
    static let shared = ViewerAudioSession()

    private var isPlaybackCategoryConfigured = false

    func activateForPlayback() {
        let audioSession = AVAudioSession.sharedInstance()
        if !isPlaybackCategoryConfigured {
            do {
                try audioSession.setCategory(.playback, mode: .moviePlayback)
                isPlaybackCategoryConfigured = true
            } catch {
                return
            }
        }
        if #available(iOS 27.0, *) {
            audioSession.activate(options: []) { _, _ in }
        } else {
            try? audioSession.setActive(true, options: [])
        }
    }
}

private func activatePlaybackAudioSession() {
    Task { await ViewerAudioSession.shared.activateForPlayback() }
}

/// single playback engine for the viewer. the active video page claims it and
/// the screen's control bar drives it, so paging can never leave two videos
/// audible and the controls live outside the pager where scrubbing cannot
/// fight the horizontal swipe.
@MainActor @Observable
final class VideoPlayback {
    private(set) var ownerID: String?
    private(set) var player: AVPlayer?
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var isFailed = false
    private(set) var isScrubbing = false
    /// the clip has been asked to move at least once. a live photo shows its
    /// still until this flips, and again once the clip runs out - the still is
    /// not video frame zero, so deriving this from the position would swap the
    /// picture underneath anyone stepping back to the start.
    private(set) var isEngaged = false
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var revision = 0

    /// user toggle, kept across pages for the viewer's lifetime. clips open
    /// silent and the speaker button is what asks for sound, so tapping a
    /// thumbnail never talks back and the audio session is claimed only once
    /// someone actually wants to hear something.
    var isMuted = true {
        didSet {
            guard oldValue != isMuted else { return }
            applyMute()
            if !isMuted { activatePlaybackAudioSession() }
        }
    }

    /// context previews force silence regardless of the user toggle.
    @ObservationIgnored private var forcesMute = false
    /// live photos return to their still once the clip ends instead of holding
    /// the last frame, which is what makes the page look like a photo again.
    @ObservationIgnored private var rewindsAtEnd = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    /// one frame of the current item, read off its video track. the 30fps
    /// assumption only stands until that load lands.
    @ObservationIgnored private var frameInterval = 1.0 / 30
    @ObservationIgnored private var wasPlayingBeforeScrub = false
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var pendingSeekSeconds: Double?
    /// deferred item factory, held until the first engagement. live photos
    /// claim on every page-on, and building the item eagerly fetched the
    /// motion clip for clips that are almost never played.
    @ObservationIgnored private var pendingItemMaker: (@MainActor () async -> AVPlayerItem?)?
    /// a release keeps the player alive for a moment so a transient page
    /// bounce can reclaim it in place instead of restarting the clip.
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    @ObservationIgnored private var resumesOnReclaim = false
    @ObservationIgnored private let liveHold = LiveHoldController()
    @ObservationIgnored private var liveContext: LiveHoldContext?
    @ObservationIgnored private var liveAuthorization: (() -> Bool)?
    @ObservationIgnored private var liveToken: LiveHoldToken?
    @ObservationIgnored private var liveLoadTask: Task<Void, Never>?
    @ObservationIgnored private var liveSource: LivePlaybackSource?
    private(set) var liveNetworkNeedsPermission = false
    private(set) var liveMode: LivePhotoMode = .live

    var canBounce: Bool {
        guard let item = player?.currentItem, item.status == .readyToPlay else { return false }
        return item.canPlayReverse || item.canPlaySlowReverse
    }

    func setLiveMode(_ mode: LivePhotoMode) {
        guard mode != liveMode, mode != .bounce || canBounce else { return }
        cancelLivePlayback()
        liveMode = mode
        if mode == .loop || mode == .bounce { togglePlayPause() }
    }
    @ObservationIgnored private var liveAllowsExpensiveDownload = false
    @ObservationIgnored private var liveRequiresNetwork = false
    @ObservationIgnored private var livePath: NetworkPathSnapshot?
    @ObservationIgnored private var liveNetworkWatcher: NetworkPathWatcher?
    @ObservationIgnored private var livePathWaiter: (id: UUID, continuation: CheckedContinuation<NetworkPathSnapshot?, Never>)?

    func configureLiveHold(context: LiveHoldContext, isAuthorized: @escaping () -> Bool) {
        guard ownerID == context.assetID else { return }
        if let previous = liveContext,
           previous.assetID != context.assetID || previous.pageGeneration != context.pageGeneration
                || previous.sessionID != context.sessionID || liveAuthorization?() != true {
            executeLive(liveHold.handle(event: .pageChanged, context: previous))
        }
        liveContext = context
        liveAuthorization = isAuthorized
        if liveNetworkWatcher == nil {
            liveNetworkWatcher = NetworkPathWatcher { [weak self] path in
                guard let self else { return }
                self.livePath = path
                self.resolveLivePath(path)
                if self.liveRequiresNetwork, self.liveLoadTask != nil,
                   !LiveNetworkPolicy.allows(path, consent: self.liveAllowsExpensiveDownload) {
                    self.liveNetworkNeedsPermission = path.connected && (path.expensive || path.constrained)
                    self.isFailed = true
                    self.cancelLivePlayback()
                }
            }
        }
    }

    func handleLiveHold(_ event: LiveHoldEvent, context: LiveHoldContext) {
        if liveMode != .live {
            switch event {
            case .accessibilityToggle:
                guard liveMode != .off else { return }
            case .pageChanged, .zoomBegan, .sceneInactive, .cancelled: break
            default: return
            }
        }
        guard let current = liveContext, ownerID == context.assetID,
              current.assetID == context.assetID, current.pageGeneration == context.pageGeneration,
              current.sessionID == context.sessionID else { return }
        liveContext = context
        executeLive(liveHold.handle(event: liveAuthorization?() == true ? event : .sceneInactive, context: context))
    }

    func releaseLivePage(assetID: String, pageGeneration: UUID) {
        guard let context = liveContext, context.assetID == assetID,
              context.pageGeneration == pageGeneration else { return }
        executeLive(liveHold.handle(event: .pageChanged, context: context))
        liveContext = nil; liveAuthorization = nil
        liveAllowsExpensiveDownload = false; liveNetworkNeedsPermission = false
        release(assetID: assetID)
    }

    func cancelLivePlayback() {
        guard let context = liveContext else { return }
        executeLive(liveHold.handle(event: .cancelled, context: context))
    }

    var permitsExpensiveLiveDownload: Bool { liveAllowsExpensiveDownload }

    func allowLiveDownloadAndPlay() {
        guard liveContext != nil, liveAuthorization?() == true else { return }
        liveAllowsExpensiveDownload = true; liveNetworkNeedsPermission = false
        togglePlayPause()
    }

    func liveNetworkAllowed() async -> Bool {
        liveRequiresNetwork = true
        let path: NetworkPathSnapshot?
        if let current = livePath { path = current }
        else {
            let id = UUID()
            path = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    resolveLivePath(nil)
                    if Task.isCancelled { continuation.resume(returning: nil) }
                    else { livePathWaiter = (id, continuation) }
                }
            } onCancel: { [weak self] in
                Task { @MainActor in self?.resolveLivePath(nil, id: id) }
            }
        }
        guard !Task.isCancelled, liveAuthorization?() == true, let path else { return false }
        let allowed = LiveNetworkPolicy.allows(path, consent: liveAllowsExpensiveDownload)
        liveNetworkNeedsPermission = !allowed && path.connected && (path.expensive || path.constrained)
        return allowed
    }

    private func resolveLivePath(_ path: NetworkPathSnapshot?, id: UUID? = nil) {
        guard let waiter = livePathWaiter, id == nil || id == waiter.id else { return }
        livePathWaiter = nil
        waiter.continuation.resume(returning: path)
    }

    private func executeLive(_ commands: [LivePlaybackCommand]) {
        for command in commands {
            switch command {
            case .prepare(let token): prepareLive(token)
            case .start(let token):
                guard liveToken == token, ownerID == token.assetID,
                      liveAuthorization?() == true, let player,
                      player.currentItem?.status == .readyToPlay else { continue }
                if abs(player.currentTime().seconds) < 0.04 {
                    isEngaged = true
                    if !forcesMute, !isMuted { activatePlaybackAudioSession() }
                    player.play()
                    continue
                }
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
                    Task { @MainActor [weak self, weak player] in
                        guard finished, let self, let player, self.player === player,
                              self.liveToken == token, self.ownerID == token.assetID,
                              self.liveAuthorization?() == true else { return }
                        self.isEngaged = true
                        if !self.forcesMute, !self.isMuted { activatePlaybackAudioSession() }
                        player.play()
                    }
                }
            case .pause(let token):
                guard liveToken == token, ownerID == token.assetID else { continue }
                player?.pause(); isPlaying = false
            case .showPoster(let token):
                guard liveToken == token, ownerID == token.assetID else { continue }
                isEngaged = false
            case .cancelLoad(let token):
                guard liveToken == token, ownerID == token.assetID else { continue }
                liveToken = nil
                liveLoadTask?.cancel(); liveLoadTask = nil
                resolveLivePath(nil)
                liveRequiresNetwork = false
                isBuffering = false
            }
        }
    }

    private func prepareLive(_ token: LiveHoldToken) {
        guard ownerID == token.assetID, liveAuthorization?() == true else { return }
        liveLoadTask?.cancel()
        liveToken = token; isFailed = false; liveRequiresNetwork = false
        if player?.currentItem?.status == .failed { detachPlayer() }
        isBuffering = player?.currentItem?.status != .readyToPlay
        if player != nil { liveReadyIfCurrent(); return }
        guard let maker = pendingItemMaker else { isFailed = true; return }
        let capturedGeneration = generation
        isBuffering = true
        liveLoadTask = Task { [weak self] in
            let item = await maker()
            guard let self, !Task.isCancelled, self.generation == capturedGeneration,
                  self.liveToken == token, self.ownerID == token.assetID,
                  self.liveAuthorization?() == true else { return }
            self.liveLoadTask = nil
            guard let item else {
                self.isFailed = true
                self.cancelLivePlayback()
                return
            }
            self.install(item, generation: capturedGeneration)
            self.liveReadyIfCurrent()
        }
    }

    private func liveReadyIfCurrent() {
        guard let context = liveContext, let token = liveToken,
              player?.currentItem?.status == .readyToPlay else { return }
        guard liveAuthorization?() == true else { cancelLivePlayback(); return }
        isBuffering = false
        executeLive(liveHold.handle(event: .loadReady(token), context: context))
    }

    /// `autoPlays` is false for live photos: their page opens on the still and
    /// only moves once the viewer asks it to. `defersItem` goes further and
    /// waits for the first engagement before even creating the player item,
    /// so paging across live photos costs no clip fetches at all.
    func claim(
        assetID: String,
        forceMuted: Bool,
        seedDuration: Double?,
        autoPlays: Bool = true,
        rewindsAtEnd: Bool = false,
        defersItem: Bool = false,
        liveSource: LivePlaybackSource? = nil,
        makeItem: @escaping @MainActor () async -> AVPlayerItem?
    ) async {
        if ownerID == assetID, self.liveSource == liveSource {
            // the same page re-claims when its mute flag flips, e.g. a context
            // preview committing to the full viewer, or right after a resize
            // bounced it out of the lazy viewport and released transiently.
            releaseTask?.cancel()
            releaseTask = nil
            forcesMute = forceMuted
            applyMute()
            let resumes = resumesOnReclaim
            resumesOnReclaim = false
            if resumes, !isPlaying {
                if !forceMuted, !isMuted { activatePlaybackAudioSession() }
                player?.play()
            } else if !forceMuted, !isMuted, isPlaying {
                activatePlaybackAudioSession()
            }
            return
        }
        generation &+= 1
        let gen = generation
        teardown()
        ownerID = assetID
        self.liveSource = liveSource
        forcesMute = forceMuted
        self.rewindsAtEnd = rewindsAtEnd
        if let seedDuration { duration = seedDuration }
        if defersItem, !autoPlays {
            pendingItemMaker = makeItem
            return
        }
        isBuffering = true
        let item = await makeItem()
        guard gen == generation, !Task.isCancelled else { return }
        isBuffering = false
        guard let item else {
            isFailed = true
            ownerID = nil
            return
        }
        install(item, generation: gen)
        guard autoPlays else { return }
        if !forceMuted, !isMuted { activatePlaybackAudioSession() }
        player?.play()
    }

    private func install(_ item: AVPlayerItem, generation gen: Int) {
        let player = AVPlayer(playerItem: item)
        self.player = player
        applyMute()
        attachObservers(to: player, item: item)
        // frame stepping is the only consumer, so the track load trails the
        // first frame instead of delaying it. only an avurlasset can leave the
        // main actor, so anything else keeps the 30fps default.
        if let asset = item.asset as? AVURLAsset {
            Task { [weak self] in
                guard let interval = await Self.frameInterval(of: asset) else { return }
                guard let self, self.generation == gen else { return }
                self.frameInterval = interval
            }
        }
    }

    /// Warm a prepared Live Photo. A press that already started
    /// loading, or a page that left the viewport, always keeps its ownership.
    func prepareLiveItem(_ item: AVPlayerItem, assetID: String) {
        guard ownerID == assetID, pendingItemMaker != nil, releaseTask == nil, liveLoadTask == nil else { return }
        pendingItemMaker = nil
        install(item, generation: generation)
    }

    /// builds the deferred item on first engagement. the still stays on
    /// screen and the bar shows buffering until the clip is ready.
    private func engagePendingItem(thenPlays: Bool) {
        guard let maker = pendingItemMaker else { return }
        pendingItemMaker = nil
        isBuffering = true
        let gen = generation
        Task { [weak self] in
            let item = await maker()
            guard let self, self.generation == gen else { return }
            self.isBuffering = false
            guard let item else {
                self.isFailed = true
                return
            }
            self.install(item, generation: gen)
            guard thenPlays else { return }
            self.isEngaged = true
            if !self.forcesMute, !self.isMuted { activatePlaybackAudioSession() }
            self.player?.play()
        }
    }

    /// a rotation resize can bounce the active page out of the lazy
    /// container's viewport for a frame, and tearing down there is what used
    /// to restart a playing video. pause right away so a real departure never
    /// leaks audio, then keep the player briefly so the same page reclaiming
    /// resumes where it was.
    func release(assetID: String) {
        guard ownerID == assetID else { return }
        cancelLivePlayback()
        liveContext = nil; liveAuthorization = nil
        resumesOnReclaim = resumesOnReclaim || isPlaying
        player?.pause()
        releaseTask?.cancel()
        let gen = generation
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled,
                  generation == gen, ownerID == assetID
            else { return }
            releaseTask = nil
            generation &+= 1
            teardown()
            ownerID = nil
        }
    }

    /// drops the clip and bumps `revision`, which the page claims again on,
    /// with a new item. a trim replaces what the server plays.
    func reload(assetID: String) {
        guard ownerID == assetID else { return }
        generation &+= 1
        teardown()
        ownerID = nil
        revision &+= 1
    }

    func togglePlayPause() {
        if let context = liveContext {
            handleLiveHold(.accessibilityToggle, context: context)
            return
        }
        guard !isFailed else { return }
        guard let player else {
            engagePendingItem(thenPlays: true)
            return
        }
        if isPlaying {
            player.pause()
        } else {
            isEngaged = true
            if duration > 0, currentTime >= duration - 0.1 {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                currentTime = 0
            }
            if !forcesMute, !isMuted { activatePlaybackAudioSession() }
            player.play()
        }
    }

    /// pauses and moves exactly one picture, so a live photo can be walked
    /// frame by frame. deliberately not `AVPlayerItem.step(byCount:)`: that
    /// snaps to the next sync sample, which on a real clip skips several
    /// frames at a time. a zero-tolerance seek decodes to the exact time.
    func stepFrame(by count: Int) {
        guard !isFailed else { return }
        // a deferred clip has no frames to step yet; load it parked so the
        // controls come alive without playing.
        guard player != nil else {
            engagePendingItem(thenPlays: false)
            return
        }
        guard let player, duration > 0 else { return }
        isEngaged = true
        player.pause()
        let target = min(max(currentTime + Double(count) * frameInterval, 0), duration)
        currentTime = target
        pendingSeekSeconds = target
        pumpSeek()
    }

    func beginScrubbing() {
        guard !isScrubbing else { return }
        isScrubbing = true
        isEngaged = true
        wasPlayingBeforeScrub = isPlaying
        player?.pause()
    }

    func scrub(to seconds: Double) {
        guard duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        pendingSeekSeconds = clamped
        pumpSeek()
    }

    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        guard wasPlayingBeforeScrub, let player else { return }
        if !forcesMute, !isMuted { activatePlaybackAudioSession() }
        player.play()
    }

    /// seeks are serialized and intermediate targets dropped so a fast drag
    /// lands on the last position instead of replaying every sample.
    private func pumpSeek() {
        guard !isSeeking, let player, let target = pendingSeekSeconds else { return }
        pendingSeekSeconds = nil
        isSeeking = true
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSeeking = false
                self.pumpSeek()
            }
        }
    }

    private func applyMute() {
        player?.isMuted = forcesMute || isMuted
    }

    @concurrent
    private nonisolated static func frameInterval(of asset: AVURLAsset) async -> Double? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let rate = try? await track.load(.nominalFrameRate),
              rate > 0
        else { return nil }
        return 1 / Double(rate)
    }

    private func attachObservers(to player: AVPlayer, item: AVPlayerItem) {
        let capturedGeneration = generation
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self, weak player] time in
            MainActor.assumeIsolated {
                guard let self, let player, self.player === player,
                      self.generation == capturedGeneration, !self.isScrubbing, !self.isSeeking, self.pendingSeekSeconds == nil
                else { return }
                if let asset = player.currentItem?.asset, !ControlledMediaFile.isAuthorized(asset) {
                    self.reload(assetID: self.ownerID ?? "")
                    return
                }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self.currentTime = seconds
                if self.liveMode == .bounce, self.isEngaged, player.rate < 0, seconds <= 0.04 {
                    player.play()
                }
            }
        }

        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == capturedGeneration, self.player === player else { return }
                let status = player.timeControlStatus
                self.isPlaying = status != .paused
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let seconds = item.duration.seconds
            Task { @MainActor [weak self] in
                guard let self, self.generation == capturedGeneration, self.player?.currentItem === item else { return }
                if status == .failed {
                    self.isFailed = true
                    self.isBuffering = false
                    self.cancelLivePlayback()
                }
                if status == .readyToPlay, seconds.isFinite, seconds > 0 {
                    self.duration = seconds
                    self.liveReadyIfCurrent()
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak player] _ in
            MainActor.assumeIsolated {
                guard let self, let player, self.player === player, self.generation == capturedGeneration else { return }
                guard self.rewindsAtEnd else {
                    self.currentTime = self.duration
                    return
                }
                if self.isEngaged, self.liveAuthorization?() == true,
                   self.liveMode == .loop || self.liveMode == .bounce {
                    if self.liveMode == .bounce, self.canBounce {
                        player.rate = item.canPlayReverse ? -1 : -0.5
                    } else {
                        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
                            Task { @MainActor in
                                guard finished, let self, let player, self.player === player,
                                      self.isEngaged, self.liveAuthorization?() == true else { return }
                                player.play()
                            }
                        }
                    }
                    return
                }
                self.player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                self.currentTime = 0
                self.isEngaged = false
                if let context = self.liveContext {
                    self.executeLive(self.liveHold.handle(event: .playbackEnded, context: context))
                }
            }
        }
    }

    private func teardown() {
        cancelLivePlayback()
        liveLoadTask?.cancel(); liveLoadTask = nil
        liveContext = nil; liveAuthorization = nil; liveToken = nil
        liveSource = nil
        liveMode = .live
        liveNetworkWatcher?.stop(); liveNetworkWatcher = nil; livePath = nil
        resolveLivePath(nil)
        liveAllowsExpensiveDownload = false; liveRequiresNetwork = false; liveNetworkNeedsPermission = false
        releaseTask?.cancel()
        releaseTask = nil
        resumesOnReclaim = false
        pendingItemMaker = nil
        detachPlayer()
        pendingSeekSeconds = nil
        isSeeking = false
        rewindsAtEnd = false
        frameInterval = 1.0 / 30
        isPlaying = false
        isBuffering = false
        isFailed = false
        isScrubbing = false
        isEngaged = false
        duration = 0
        currentTime = 0
    }

    private func detachPlayer() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        itemStatusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

// MARK: - page

/// video page built from a bare player layer inside the shared zoom container,
/// so videos pinch and double-tap exactly like photos. the poster paints the
/// page while the item loads and stays under the letterboxed video.
struct VideoPlayerPage: View {
    @Environment(SessionStore.self) private var session
    let asset: Asset
    let aspectRatio: Double
    let deviceIdentifier: String?
    let isActive: Bool
    let forcesMute: Bool
    let playback: VideoPlayback
    let onMediaReady: () -> Void
    let onImage: (UIImage) -> Void
    let ownsLaunchMedia: Bool
    let launchMediaBridge: AssetViewerLaunchMediaBridge
    let openingMediaSurface: CommittedGridSurface?
    let posterCacheScope: String
    let posterFallbackPixels: CGFloat?
    let posterFallbackScope: String?
    let onBoundImage: (BoundRemoteImage) -> Void
    let onBoundLocalImage: (BoundLocalImage) -> Void
    let allowsDoubleTapZoom: Bool
    let onMediaTap: () -> Void
    let onDoubleTapZoomChanged: (Bool) -> Void
    let onZoomInteractionStarted: () -> Void
    let onZoomPresentationChanged: (Bool) -> Void
    let onZoomChanged: (Bool) -> Void

    @State private var localUnavailable = false

    private var posterLocalIdentifier: String? {
        localUnavailable || asset.visibility == .locked ? nil : deviceIdentifier
    }

    var body: some View {
        ZoomableScrollView(
            assetID: asset.id,
            contentID: "\(asset.id)#\(posterLocalIdentifier ?? "remote")#ratio-\(aspectRatio.bitPattern)",
            isActivePage: isActive,
            allowsDoubleTapZoom: allowsDoubleTapZoom,
            onMediaTap: onMediaTap,
            onDoubleTapZoomChanged: onDoubleTapZoomChanged,
            onZoomInteractionStarted: onZoomInteractionStarted,
            onZoomPresentationChanged: onZoomPresentationChanged,
            onZoomChanged: onZoomChanged
        ) {
            MediaSurfaceStack(
                assetID: asset.id,
                aspectRatio: aspectRatio,
                mode: .video,
                posterLocalIdentifier: posterLocalIdentifier,
                posterURL: posterURL,
                posterFallbackURL: posterFallbackURL,
                thumbhash: asset.thumbhash,
                playback: playback,
                posterCacheScope: posterCacheScope,
                posterFallbackPixels: posterFallbackPixels,
                posterFallbackScope: posterFallbackScope,
                onPosterReady: onMediaReady,
                onPosterImage: onImage,
                onPosterUnavailable: {
                    localUnavailable = true
                },
                onPosterBoundImage: onBoundImage,
                onPosterBoundLocalImage: onBoundLocalImage
            )
            .modifier(
                AssetViewerLaunchMediaModifier(
                    asset: asset,
                    openingSurface: openingMediaSurface,
                    ownsLaunchMedia: ownsLaunchMedia,
                    bridge: launchMediaBridge
                )
            )
        }
        .task(id: "\(asset.id):\(isActive):\(forcesMute):\(playback.revision)") {
            guard isActive else {
                playback.release(assetID: asset.id)
                return
            }
            await playback.claim(
                assetID: asset.id,
                forceMuted: forcesMute,
                seedDuration: asset.duration.map { Double($0) / 1000 }
            ) {
                await makeItem()
            }
        }
        .onDisappear { playback.release(assetID: asset.id) }
        .onChange(of: session.lockedFolder?.publicationGeneration) { _, _ in
            if asset.visibility == .locked, session.client?.lockedMediaLease == nil { playback.reload(assetID: asset.id) }
        }
    }

    private var posterURL: URL? {
        guard let client = session.client, !asset.isLocal else { return nil }
        return client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: asset.thumbhash)
    }

    private var posterFallbackURL: URL? {
        guard let client = session.client, !asset.isLocal else { return nil }
        return client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash)
    }

    /// the paired device copy is free; when it cannot be served the page falls
    /// back to the server stream instead of spinning forever. device-only
    /// assets may pull from icloud since they have nowhere else to go.
    private func makeItem() async -> AVPlayerItem? {
        if asset.visibility != .locked, let deviceIdentifier,
           let item = await LocalImageLoader.shared.playerItem(
               localIdentifier: deviceIdentifier,
               allowsNetwork: asset.isLocal
           ) {
            return item
        }
        guard !asset.isLocal, let client = session.client else { return nil }
        guard let localURL = try? await client.localMediaFile(client.playbackURL(assetID: asset.id), requiresElevation: asset.visibility == .locked),
              !Task.isCancelled, let urlAsset = try? localURL.makeAsset() else { return nil }
        return AVPlayerItem(asset: urlAsset)
    }
}

/// what the still underneath means for a given page. a video's poster is only
/// a placeholder, while a live photo's still is the asset itself and stays
/// visible whenever the clip is parked at its start.
enum MediaSurfaceMode {
    case video
    case livePhoto
}

/// hosted inside the zoom container, so it reads the playback observable
/// itself - the container only reassigns its root when the content id
/// changes, and the video surface has to appear without that.
struct MediaSurfaceStack: View {
    let assetID: String
    let aspectRatio: Double
    let mode: MediaSurfaceMode
    let posterLocalIdentifier: String?
    let posterURL: URL?
    let posterFallbackURL: URL?
    let thumbhash: String?
    let playback: VideoPlayback
    var posterCacheScope = ""
    var posterFallbackPixels: CGFloat?
    var posterFallbackScope: String?
    var onPosterReady: (() -> Void)?
    var onPosterImage: ((UIImage) -> Void)?
    /// only a live photo needs this: its still is the asset, so losing the
    /// device copy would leave an empty page rather than a stale poster.
    var onPosterUnavailable: (() -> Void)?
    var onPosterBoundImage: ((BoundRemoteImage) -> Void)?
    var onPosterBoundLocalImage: ((BoundLocalImage) -> Void)?

    /// a live photo shows its own still until the clip actually moves, so the
    /// page renders full-resolution pixels rather than a video frame at rest.
    private var showsVideo: Bool {
        guard playback.ownerID == assetID, playback.player != nil else { return false }
        switch mode {
        case .video:
            return true
        case .livePhoto:
            return playback.isEngaged
        }
    }

    var body: some View {
        AssetViewerFittedMedia(aspectRatio: aspectRatio) {
            ZStack {
                if let posterLocalIdentifier {
                    LocalPhotoImage(
                        localIdentifier: posterLocalIdentifier,
                        targetPixelSize: pagePixelSize,
                        cacheScope: posterCacheScope,
                        fallbackTargetPixelSize: posterFallbackPixels,
                        fallbackRequestContentMode: .aspectFit,
                        fallbackCoversTarget: true,
                        fallbackCacheScope: posterFallbackScope,
                        requiresBoundFallback: true,
                        requestContentMode: .aspectFit,
                        contentMode: .fit,
                        expectedAspectRatio: aspectRatio,
                        onUnavailable: { onPosterUnavailable?() },
                        onImage: { onPosterImage?($0) },
                        onReady: { onPosterReady?() },
                        onBoundImage: onPosterBoundLocalImage
                    )
                } else if let posterURL {
                    RemoteImage(
                        url: posterURL,
                        targetPixelSize: pagePixelSize,
                        thumbhash: thumbhash,
                        fallbackURL: posterFallbackURL,
                        fallbackTargetPixelSize: posterFallbackPixels ?? 640,
                        contentMode: .fit,
                        onImage: { onPosterImage?($0) },
                        onReady: { onPosterReady?() },
                        onBoundImage: onPosterBoundImage
                    )
                }
                if playback.ownerID == assetID, let player = playback.player {
                    VideoPlayerSurface(
                        player: player,
                        onReady: { onPosterReady?() }
                    )
                    .opacity(showsVideo ? 1 : 0)
                    .allowsHitTesting(showsVideo)
                    .transaction { $0.animation = nil }
                }
            }
        }
        .clipped()
    }
}

/// bare video layer with no transport chrome. hidden until the first frame is
/// ready, then fades over the poster rather than popping in mid-render.
struct VideoPlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let onReady: () -> Void

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }

        private var readyObservation: NSKeyValueObservation?
        private var hasReportedReady = false
        private var hasScheduledReadyReport = false
        private var isFadingIn = false
        private var onReady: () -> Void = {}

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil,
                  !isFadingIn,
                  let playerLayer = layer as? AVPlayerLayer,
                  playerLayer.isReadyForDisplay
            else { return }
            scheduleReadyReport(for: playerLayer)
        }

        func configure(player: AVPlayer, onReady: @escaping () -> Void) {
            guard let playerLayer = layer as? AVPlayerLayer else { return }
            self.onReady = onReady
            if playerLayer.player !== player {
                readyObservation = nil
                hasReportedReady = false
                hasScheduledReadyReport = false
                isFadingIn = false
                playerLayer.player = player
            }
            guard !playerLayer.isReadyForDisplay else {
                guard !isFadingIn else { return }
                alpha = 1
                scheduleReadyReport(for: playerLayer)
                return
            }
            guard readyObservation == nil else { return }
            alpha = 0
            readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, change in
                guard change.newValue == true else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.alpha == 0 else { return }
                    self.readyObservation = nil
                    self.isFadingIn = true
                    UIView.animate(withDuration: 0.18) {
                        self.alpha = 1
                    } completion: { [weak self] finished in
                        guard let self else { return }
                        self.isFadingIn = false
                        guard finished,
                              self.window != nil,
                              let playerLayer = self.layer as? AVPlayerLayer,
                              playerLayer.isReadyForDisplay
                        else { return }
                        self.reportReady()
                    }
                }
            }
        }

        private func scheduleReadyReport(for playerLayer: AVPlayerLayer) {
            guard !hasReportedReady,
                  !hasScheduledReadyReport,
                  let expectedPlayer = playerLayer.player
            else { return }
            hasScheduledReadyReport = true
            Task { @MainActor [weak self, weak expectedPlayer] in
                await Task.yield()
                guard let self else { return }
                self.hasScheduledReadyReport = false
                guard self.window != nil,
                      let expectedPlayer,
                      let currentLayer = self.layer as? AVPlayerLayer,
                      currentLayer.player === expectedPlayer,
                      currentLayer.isReadyForDisplay,
                      !self.isFadingIn
                else { return }
                self.reportReady()
            }
        }

        private func reportReady() {
            guard !hasReportedReady else { return }
            hasReportedReady = true
            onReady()
        }

        func detach() {
            readyObservation = nil
            onReady = {}
            (layer as? AVPlayerLayer)?.player = nil
        }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .clear
        let layer = view.layer as? AVPlayerLayer
        layer?.videoGravity = .resizeAspect
        view.configure(player: player, onReady: onReady)
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        uiView.configure(player: player, onReady: onReady)
    }

    // the player outlives this layer. freed while still one of its video
    // targets, mediatoolbox can walk the dead layer's superlayers on its
    // own queue and crash, so the layer leaves the player first.
    static func dismantleUIView(_ uiView: LayerView, coordinator: ()) {
        uiView.detach()
    }
}

// MARK: - controls

/// photos style transport strip shown with the viewer chrome.
struct VideoControlsBar: View {
    let playback: VideoPlayback

    /// photos' scrubber palette, measured on a 393pt phone: a 336pt glass
    /// capsule, 47pt tall, with no time beside its track.
    var body: some View {
        HStack(spacing: 9) {
            Button(action: playback.togglePlayPause) {
                Group {
                    if playback.isFailed {
                        Image(systemName: "exclamationmark.circle")
                    } else if playback.isBuffering {
                        ProgressView()
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                .font(.system(size: 19, weight: .bold))
                .frame(width: 30, height: 30)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(playback.isFailed)
            .accessibilityIdentifier("video-play-pause")

            VideoScrubber(playback: playback)
                .accessibilityValue(
                    videoTimeLabel(playback.currentTime) + " / " + videoTimeLabel(playback.duration)
                )

            Button {
                playback.isMuted.toggle()
            } label: {
                Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("video-mute")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8.5)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 28)
        .frame(maxWidth: 560)
        .accessibilityIdentifier("video-controls")
    }
}

/// drag anywhere on the track to seek; the bar thickens while scrubbing like
/// the system players.
struct VideoScrubber: View {
    let playback: VideoPlayback
    var identifier = "video-scrubber"

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = playback.duration > 0
                ? min(max(playback.currentTime / playback.duration, 0), 1)
                : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.4))
                Capsule().fill(Color.primary)
                    .frame(width: width * fraction)
            }
            .frame(height: playback.isScrubbing ? 12 : 8)
            .frame(width: width, height: geometry.size.height)
            .animation(.smooth(duration: 0.18), value: playback.isScrubbing)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0 else { return }
                        playback.beginScrubbing()
                        playback.scrub(to: Double(value.location.x / width) * playback.duration)
                    }
                    .onEnded { _ in
                        playback.endScrubbing()
                    }
            )
        }
        .frame(height: 30)
        .accessibilityIdentifier(identifier)
    }
}

func videoTimeLabel(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
