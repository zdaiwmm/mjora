import Foundation

/// The grid's bounded progression. Local callbacks may keep arriving while
/// the server fallback runs; the first adequate image wins. No action can
/// request an original or a video resource.
nonisolated struct ThumbnailLoadState: Sendable {
    enum Phase: Equatable, Sendable { case loading, preview, ready, retry, cancelled }
    enum Action: Equatable, Sendable { case none, thumbnail, preview, finished }

    private(set) var phase: Phase = .loading
    private let hasRemote: Bool
    private let targetPixels: Double
    private var requestedThumbnail: Bool
    private var requestedPreview = false

    init(hasLocal: Bool, hasRemote: Bool, targetPixels: Double) {
        self.hasRemote = hasRemote
        self.targetPixels = targetPixels
        requestedThumbnail = !hasLocal && hasRemote
    }

    private var acceptsResults: Bool { phase != .ready && phase != .cancelled }

    mutating func localPreview() {
        guard acceptsResults else { return }
        phase = .preview
    }

    mutating func localDeadline() -> Action { localUnavailable() }

    mutating func localUnavailable() -> Action {
        guard acceptsResults else { return .none }
        guard hasRemote else { phase = .retry; return .none }
        guard !requestedThumbnail else { return .none }
        requestedThumbnail = true
        return .thumbnail
    }

    mutating func localFinal(pixels: Double, originalPixels: Double) -> Action {
        guard acceptsResults else { return .none }
        // A genuinely small original is already as sharp as it can become.
        if pixels >= min(targetPixels, originalPixels) * 0.95 {
            phase = .ready
            return .finished
        }
        phase = .preview
        return localUnavailable()
    }

    mutating func remoteResult(pixels: Double?, isPreview: Bool) -> Action {
        guard acceptsResults else { return .none }
        if let pixels, pixels >= targetPixels * 0.95 || isPreview {
            phase = .ready
            return .finished
        }
        if pixels != nil { phase = .preview }
        guard !isPreview, !requestedPreview else { phase = .retry; return .none }
        requestedPreview = true
        return .preview
    }

    mutating func cancel() { phase = .cancelled }

    static func prefetchWindow(visible: Range<Int>, count: Int) -> Range<Int> {
        max(0, visible.lowerBound - visible.count)..<min(count, visible.upperBound + visible.count)
    }
}
