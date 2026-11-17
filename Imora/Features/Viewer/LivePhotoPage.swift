import Foundation
import AVFoundation
import SwiftUI

/// The still remains visible at rest. Hold playback and the accessible
/// transport button share the viewer's single playback owner.
struct LivePhotoPage: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
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

    /// photokit could not serve the device copy after all; the page falls back
    /// to the server for the rest of its life.
    @State private var localUnavailable = false
    @State private var pageGeneration = UUID()

    private var localIdentifier: String? {
        localUnavailable || asset.visibility == .locked ? nil : deviceIdentifier
    }

    private struct LoadIdentity: Equatable {
        let assetID: String
        let isActive: Bool
        let forcesMute: Bool
        let source: LivePlaybackSource
        let privatePublication: Int
    }

    private var loadIdentity: LoadIdentity {
        // The publication read refreshes the lease identity after PIN changes.
        let publication = asset.visibility == .locked ? session.lockedFolder?.publicationGeneration ?? 0 : 0
        return .init(assetID: asset.id, isActive: isActive, forcesMute: forcesMute,
            source: .init(localIdentifier: localIdentifier, localRevision: asset.localImageVersion,
                remoteMotionID: asset.livePhotoVideoId, posterRevision: asset.thumbhash,
                runtimeSession: session.client?.context.id,
                privateProducer: asset.visibility == .locked ? session.client?.lockedMediaLease?.identity : nil),
            privatePublication: publication)
    }

    private func holdContext(scale: Double) -> LiveHoldContext? {
        guard let client = session.client else { return nil }
        return .init(assetID: asset.id, pageGeneration: pageGeneration, sessionID: client.context.id,
                     isActive: isActive && !forcesMute, zoomScale: scale)
    }

    var body: some View {
        // the zoom container only reassigns its hosted root when the content
        // id changes, so the id has to name the source: losing the device copy
        // would otherwise keep the failed still on screen forever.
        ZoomableScrollView(
            assetID: asset.id,
            contentID: "\(asset.id)#\(localIdentifier ?? "remote")#ratio-\(aspectRatio.bitPattern)",
            isActivePage: isActive,
            allowsDoubleTapZoom: allowsDoubleTapZoom,
            onMediaTap: onMediaTap,
            onDoubleTapZoomChanged: onDoubleTapZoomChanged,
            onZoomInteractionStarted: onZoomInteractionStarted,
            onZoomPresentationChanged: onZoomPresentationChanged,
            onZoomChanged: onZoomChanged,
            onLiveHold: { event, scale in
                guard let context = holdContext(scale: scale) else { return }
                playback.handleLiveHold(event, context: context)
            }
        ) {
            MediaSurfaceStack(
                assetID: asset.id,
                aspectRatio: aspectRatio,
                mode: .livePhoto,
                posterLocalIdentifier: localIdentifier,
                posterURL: posterURL,
                posterFallbackURL: posterFallbackURL,
                thumbhash: asset.thumbhash,
                playback: playback,
                posterCacheScope: posterCacheScope,
                posterFallbackPixels: posterFallbackPixels,
                posterFallbackScope: posterFallbackScope,
                onPosterReady: onMediaReady,
                onPosterImage: onImage,
                onPosterUnavailable: { localUnavailable = true },
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
        .task(id: loadIdentity) {
            guard isActive else {
                playback.releaseLivePage(assetID: asset.id, pageGeneration: pageGeneration)
                return
            }
            guard let client = session.client else { return }
            let identity = loadIdentity
            let generation = UUID(); pageGeneration = generation
            await playback.claim(
                assetID: asset.id,
                forceMuted: forcesMute,
                seedDuration: nil,
                autoPlays: false,
                rewindsAtEnd: true,
                // Keep the still visible while the paired clip warms.
                defersItem: true,
                liveSource: identity.source
            ) {
                await makeItem()
            }
            guard !Task.isCancelled, session.client === client else { return }
            let lease = asset.visibility == .locked ? client.lockedMediaLease : nil
            let requiresElevation = asset.visibility == .locked
            playback.configureLiveHold(context: .init(assetID: asset.id, pageGeneration: generation,
                sessionID: client.context.id, isActive: !forcesMute, zoomScale: 1),
                isAuthorized: { [weak client] in
                    client?.context.isActive == true && UIApplication.shared.applicationState == .active
                        && (!requiresElevation || lease?.isCurrent == true)
                })
            // Device clips warm immediately. A remote page must first settle;
            // prefetching never uses cellular or constrained connections.
            if let localIdentifier {
                if let item = await LocalImageLoader.shared.motionPlayerItem(
                    localIdentifier: localIdentifier, allowsNetwork: false
                ), !Task.isCancelled {
                    playback.prepareLiveItem(item, assetID: asset.id)
                }
            } else if !asset.isLocal, !forcesMute {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                if let item = await makeItem(isPrewarming: true), !Task.isCancelled {
                    playback.prepareLiveItem(item, assetID: asset.id)
                }
            }
        }
        .onDisappear {
            let generation = pageGeneration
            Task { @MainActor in playback.releaseLivePage(assetID: asset.id, pageGeneration: generation) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playback.cancelLivePlayback() }
        }
        .onChange(of: session.client?.context.id) { _, _ in playback.cancelLivePlayback() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            playback.cancelLivePlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            if notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                playback.cancelLivePlayback()
            }
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

    /// the paired video on device costs nothing to read; the server keeps the
    /// motion half as its own asset, addressed by the still's pairing id.
    private func makeItem(isPrewarming: Bool = false) async -> AVPlayerItem? {
        if let localIdentifier,
           let item = await LocalImageLoader.shared.motionPlayerItem(
               localIdentifier: localIdentifier,
               allowsNetwork: false
           ) {
            return item
        }
        if asset.isLocal {
            guard let localIdentifier, await playback.liveNetworkAllowed(), !Task.isCancelled else { return nil }
            return await LocalImageLoader.shared.motionPlayerItem(localIdentifier: localIdentifier, allowsNetwork: true)
        }
        guard !asset.isLocal,
              let motionID = asset.livePhotoVideoId,
              let client = session.client
        else { return nil }
        do {
            // A cached controlled file remains available offline. For a miss,
            // URLSession enforces the policy even if Wi-Fi changes mid-load.
            let file = try await client.localMediaFile(client.playbackURL(assetID: motionID),
                allowsExpensiveNetworkAccess: !isPrewarming && playback.permitsExpensiveLiveDownload,
                requiresElevation: asset.visibility == .locked)
            guard !Task.isCancelled else { return nil }
            return AVPlayerItem(asset: try file.makeAsset())
        } catch let error as URLError {
            if !isPrewarming, [.dataNotAllowed, .internationalRoamingOff, .notConnectedToInternet].contains(error.code), !Task.isCancelled {
                _ = await playback.liveNetworkAllowed()
            }
            return nil
        } catch { return nil }
    }
}

// MARK: - controls

/// Live effects and playback share a compact menu above the image.
struct LivePhotoControlsBar: View {
    let playback: VideoPlayback

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Picker("Live Photo", selection: Binding(get: { playback.liveMode }, set: playback.setLiveMode)) {
                    ForEach(LivePhotoMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                            .disabled(mode == .bounce && !playback.canBounce)
                    }
                }
                if playback.liveMode != .off {
                    Button(action: playback.togglePlayPause) {
                        Label(playback.isPlaying ? String(localized: "Stop Live Photo") : String(localized: "Play Live Photo"),
                              systemImage: playback.isPlaying ? "stop.fill" : "play.fill")
                    }
                    .accessibilityIdentifier("live-photo-play-pause")
                    Button(action: { playback.isMuted.toggle() }) {
                        Label(playback.isMuted ? String(localized: "Unmute") : String(localized: "Mute"),
                              systemImage: playback.isMuted ? "speaker.slash" : "speaker.wave.2")
                    }
                }
                if playback.liveNetworkNeedsPermission {
                    Button("Allow Download and Play", action: playback.allowLiveDownloadAndPlay)
                        .accessibilityIdentifier("live-photo-allow-download")
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: playback.liveMode.symbol)
                    Text(playback.liveMode.title)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .contentShape(.capsule)
            }
            .menuIndicator(.hidden)
            .accessibilityValue(playback.liveMode.title)
            .accessibilityIdentifier("live-photo-mode")
        }
        .foregroundStyle(.white)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityValue(playback.isEngaged ? "Playing" : "Stopped")
        .accessibilityHint("Touch and hold the photo to play. Release to stop.")
        .accessibilityIdentifier("live-photo-controls")
    }
}
