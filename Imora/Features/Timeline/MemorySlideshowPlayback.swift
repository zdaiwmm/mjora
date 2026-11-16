import AVFoundation
import Observation
import UIKit

nonisolated enum MemorySoundtrack {
    static let title = "Vaporware"
    static let artist = "The Cynic Project"
    static var url: URL? { Bundle.main.url(forResource: "Memory-Vaporware", withExtension: "mp3") }
}

/// File decoding and audio-queue startup can block, so they never run in the
/// view's executor. Revisions reject late play/pause commands after a new one.
private actor MemorySoundtrackPlayer {
    private var player: AVAudioPlayer?
    private var revision = 0
    private var stopped = false

    func play(revision: Int, volume: Float) throws -> Bool {
        guard !stopped, !Task.isCancelled, revision >= self.revision else { return false }
        self.revision = revision
        if player == nil {
            guard let url = MemorySoundtrack.url else { throw CocoaError(.fileNoSuchFile) }
            player = try AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1
            player?.volume = 0
        }
        guard !Task.isCancelled else { return false }
        let playing = player?.play() == true
        player?.setVolume(volume, fadeDuration: 0.15)
        return playing
    }

    func pause(revision: Int) {
        guard revision >= self.revision else { return }
        self.revision = revision
        player?.pause()
    }

    func stop() {
        stopped = true
        player?.stop()
        player = nil
    }
}

private actor MemoryAudioSession {
    static let shared = MemoryAudioSession()
    private var owner: UUID?

    func activate(_ id: UUID) async throws {
        owner = id
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback)
        if #available(iOS 27.0, *) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.activate(options: []) { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } else { try session.setActive(true) }
    }

    func release(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        if #available(iOS 27.0, *) {
            AVAudioSession.sharedInstance().deactivate(options: .notifyOthersOnDeactivation) { _, _ in }
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

@MainActor @Observable
final class MemorySlideshowPlayback {
    struct Frame: Identifiable {
        let id: String
        let image: UIImage
        let video: AVPlayer?
    }

    let assets: [Asset]
    private(set) var position: MemoryPlaybackPosition
    private(set) var frame: Frame?
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private(set) var musicUnavailable = false
    private(set) var isMuted = false
    private(set) var isMusicPlaying = false
    @ObservationIgnored private var client: ImoraClient?
    @ObservationIgnored private let audioOwner = UUID()
    @ObservationIgnored private let music = MemorySoundtrackPlayer()
    @ObservationIgnored private var audioRevision = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var audioTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var videoObservation: NSKeyValueObservation?

    init(assets: [Asset]) {
        self.assets = assets
        position = MemoryPlaybackPosition(assets: assets)
    }

    var index: Int { position.index }
    var isPlaying: Bool { position.isPlaying }
    var isFinished: Bool { position.isFinished }
    var progress: Double { position.progress }

    #if DEBUG
    var diagnostic: String {
        "index=\(index);playing=\(isPlaying);ready=\(position.isReady);music=\(isMusicPlaying);muted=\(isMuted);audible=\(isMusicPlaying && !isMuted && !musicUnavailable);elapsed=\(position.elapsed);video=\(frame?.video != nil)"
    }
    #endif

    func start(client: ImoraClient) {
        guard self.client == nil, !assets.isEmpty else { return }
        self.client = client
        loadCurrent()
        ticker = Task { [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                let now = ContinuousClock.now
                let delta = Double(last.duration(to: now).components.attoseconds) / 1e18
                    + Double(last.duration(to: now).components.seconds)
                last = now
                guard let self else { return }
                self.tick(min(delta, 0.25))
            }
        }
    }

    func togglePlayback() {
        if position.isFinished {
            position.isPlaying = true
            select(0)
        } else {
            position.isPlaying.toggle()
            syncAudio()
        }
    }

    func pause() {
        position.isPlaying = false
        syncAudio()
    }

    func toggleMuted() {
        isMuted.toggle()
        syncAudio()
    }

    func select(_ index: Int) {
        guard position.select(index) else { return }
        loadCurrent()
    }

    func retry() { loadCurrent() }

    func videoReady(id: String) {
        guard frame?.id == id, assets[index].id == id, errorMessage == nil else { return }
        position.isReady = true
        isLoading = false
        syncAudio()
    }

    func stop() {
        generation &+= 1
        position.isPlaying = false
        loadTask?.cancel(); loadTask = nil
        prefetchTask?.cancel(); prefetchTask = nil
        ticker?.cancel(); ticker = nil
        audioTask?.cancel(); audioTask = nil
        videoObservation = nil
        frame?.video?.pause()
        isMusicPlaying = false
        client = nil
        Task {
            await music.stop()
            await MemoryAudioSession.shared.release(audioOwner)
        }
    }

    private func tick(_ seconds: TimeInterval) {
        var delta = seconds
        if let video = frame?.video {
            delta = max(0, video.currentTime().seconds - position.elapsed)
            if let item = video.currentItem, item.duration.seconds.isFinite,
               video.currentTime().seconds >= item.duration.seconds - 0.15 {
                delta = position.duration
            } else if video.timeControlStatus != .playing { return }
        }
        if position.advance(by: delta) { loadCurrent() }
        else if position.isFinished { syncAudio() }
    }

    private func loadCurrent() {
        guard let client, assets.indices.contains(index) else { return }
        generation &+= 1
        let ticket = generation, asset = assets[index]
        loadTask?.cancel()
        prefetchTask?.cancel()
        videoObservation = nil
        frame?.video?.pause()
        isLoading = true
        errorMessage = nil
        position.isReady = false
        loadTask = Task { [weak self] in
            do {
                let url = client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: asset.thumbhash)
                let image = try await ImageLoader.shared.image(for: url, targetPixelSize: 2_000)
                var video: AVPlayer?
                if asset.isVideo {
                    let file = try await client.localMediaFile(client.playbackURL(assetID: asset.id),
                                                               requiresElevation: false)
                    let player = AVPlayer(playerItem: AVPlayerItem(asset: try file.makeAsset()))
                    player.isMuted = self?.isMuted ?? true
                    video = player
                }
                guard let self, !Task.isCancelled, self.generation == ticket else { return }
                self.frame = Frame(id: asset.id, image: image, video: video)
                if let video {
                    self.videoObservation = video.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                        guard item.status == .failed else { return }
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == ticket else { return }
                            self.fail()
                        }
                    }
                    // Rendering the first video frame, rather than starting the
                    // download, starts the slide clock. The poster stays below it.
                } else {
                    self.position.isReady = true
                    self.isLoading = false
                }
                self.syncAudio()
                self.prefetchNext(client: client)
            } catch {
                guard let self, !Task.isCancelled, self.generation == ticket else { return }
                self.fail()
            }
        }
    }

    private func fail() {
        isLoading = false
        position.isReady = false
        errorMessage = String(localized: "Couldn't load this memory item.")
        frame?.video?.pause()
        syncAudio()
    }

    private func prefetchNext(client: ImoraClient) {
        let next = Array(assets.dropFirst(index + 1).prefix(2))
        prefetchTask = Task {
            for asset in next {
                guard !Task.isCancelled else { return }
                let url = client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: asset.thumbhash)
                _ = try? await ImageLoader.shared.image(for: url, targetPixelSize: 2_000)
                if asset.isVideo, !Task.isCancelled {
                    _ = try? await client.localMediaFile(client.playbackURL(assetID: asset.id), requiresElevation: false)
                }
            }
        }
    }

    private func syncAudio() {
        audioTask?.cancel()
        audioRevision &+= 1
        let revision = audioRevision
        let playing = position.isPlaying && position.isReady && errorMessage == nil
        if !playing {
            frame?.video?.pause()
            isMusicPlaying = false
            audioTask = Task { await music.pause(revision: revision) }
            return
        }
        frame?.video?.isMuted = isMuted
        audioTask = Task { [weak self] in
            guard let self else { return }
            do { try await MemoryAudioSession.shared.activate(self.audioOwner) }
            catch { self.musicUnavailable = true }
            guard !Task.isCancelled, revision == self.audioRevision,
                  self.position.isPlaying, self.position.isReady else { return }
            self.frame?.video?.play()
            if !self.musicUnavailable {
                do {
                    let volume: Float = self.isMuted ? 0 : self.frame?.video == nil ? 0.45 : 0.15
                    let playing = try await self.music.play(revision: revision, volume: volume)
                    guard !Task.isCancelled, revision == self.audioRevision else { return }
                    self.isMusicPlaying = playing
                    self.musicUnavailable = !playing
                } catch {
                    guard !Task.isCancelled, revision == self.audioRevision else { return }
                    self.musicUnavailable = true
                }
            }
        }
    }
}
