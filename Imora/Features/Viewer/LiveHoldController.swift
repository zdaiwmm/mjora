import Foundation

nonisolated enum LiveNetworkPolicy {
    static func allows(_ path: NetworkPathSnapshot, consent: Bool) -> Bool {
        path.connected && (consent || (!path.expensive && !path.constrained))
    }
}

nonisolated struct LivePlaybackSource: Equatable, Sendable {
    let localIdentifier: String?
    let localRevision: String?
    let remoteMotionID: String?
    let posterRevision: String?
    let runtimeSession: UUID?
    let privateProducer: String?
}

nonisolated struct LiveHoldContext: Equatable, Sendable {
    let assetID: String
    let pageGeneration: UUID
    let sessionID: UUID
    let isActive: Bool
    let zoomScale: Double

    var canEngage: Bool { isActive && zoomScale.isFinite && abs(zoomScale - 1) <= 0.01 }
}

nonisolated struct LiveHoldToken: Equatable, Sendable {
    let id: UUID
    let assetID: String
    let pageGeneration: UUID
    let sessionID: UUID

    func matches(_ context: LiveHoldContext) -> Bool {
        assetID == context.assetID && pageGeneration == context.pageGeneration && sessionID == context.sessionID
    }
}

nonisolated enum LiveHoldEvent: Equatable, Sendable {
    case began, recognized, ended, cancelled, secondFinger, pageChanged, zoomBegan, sceneInactive
    case moved(distancePt: Double)
    case loadReady(LiveHoldToken)
    case playbackEnded, accessibilityToggle
}

nonisolated enum LivePlaybackCommand: Equatable, Sendable {
    case prepare(LiveHoldToken), start(LiveHoldToken), pause(LiveHoldToken)
    case showPoster(LiveHoldToken), cancelLoad(LiveHoldToken)
}

/// Gesture and accessibility playback share one owner. A ready callback can
/// only start the exact still-held token that requested it.
@MainActor
final class LiveHoldController {
    static let minimumDuration = 0.15
    static let maximumMovement = 10.0

    enum Phase: Equatable { case rest, arming, loadingHeld, playingHeld, loadingPersistent, playingPersistent }
    private(set) var phase: Phase = .rest
    private(set) var token: LiveHoldToken?

    func handle(event: LiveHoldEvent, context: LiveHoldContext) -> [LivePlaybackCommand] {
        if case .loadReady(let ready) = event, ready != token { return [] }
        if let token, !token.matches(context) { return cancel() }
        switch event {
        case .began:
            let previous = cancel()
            guard context.canEngage else { return previous }
            token = makeToken(context); phase = .arming
            return previous
        case .recognized:
            guard context.canEngage else { return cancel() }
            guard phase == .arming, let token else { return [] }
            phase = .loadingHeld
            return [.prepare(token)]
        case .loadReady(let ready):
            guard context.canEngage else { return cancel() }
            switch phase {
            case .loadingHeld: phase = .playingHeld
            case .loadingPersistent: phase = .playingPersistent
            default: return []
            }
            return [.start(ready)]
        case .accessibilityToggle:
            if phase == .loadingPersistent || phase == .playingPersistent { return cancel() }
            let previous = cancel()
            guard context.canEngage else { return previous }
            let current = makeToken(context)
            token = current; phase = .loadingPersistent
            return previous + [.prepare(current)]
        case .moved(let distance):
            return distance > Self.maximumMovement ? cancel() : []
        case .ended, .cancelled, .secondFinger, .pageChanged, .zoomBegan, .sceneInactive, .playbackEnded:
            return cancel()
        }
    }

    private func makeToken(_ context: LiveHoldContext) -> LiveHoldToken {
        .init(id: UUID(), assetID: context.assetID, pageGeneration: context.pageGeneration, sessionID: context.sessionID)
    }

    private func cancel() -> [LivePlaybackCommand] {
        guard let token else { return [] }
        self.token = nil; phase = .rest
        return [.pause(token), .showPoster(token), .cancelLoad(token)]
    }
}

nonisolated enum LivePhotoMode: String, CaseIterable, Identifiable {
    case live, loop, bounce, off
    var id: Self { self }
    var title: String {
        switch self {
        case .live: String(localized: "Live")
        case .loop: String(localized: "Loop")
        case .bounce: String(localized: "Bounce")
        case .off: String(localized: "Live Off")
        }
    }
    var symbol: String {
        switch self {
        case .live: "livephoto"
        case .loop: "repeat"
        case .bounce: "arrow.left.arrow.right"
        case .off: "livephoto.slash"
        }
    }
}
