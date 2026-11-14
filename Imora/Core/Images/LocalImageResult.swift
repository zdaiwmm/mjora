import Foundation

/// PhotoKit may provide a provisional callback before the requested render.
/// only a terminal outcome may make the tile choose another image source.
nonisolated enum LocalImageResult: Equatable {
    case waiting
    case preview
    case final
    case cloudUnavailable
    case cancelled
    case failed
    case missing

    var shouldTryAlternateSource: Bool {
        switch self {
        case .cloudUnavailable, .failed, .missing: true
        default: false
        }
    }

    static func classify(
        hasImage: Bool,
        isDegraded: Bool,
        isCancelled: Bool,
        hasError: Bool,
        isInCloud: Bool,
        allowsNetwork: Bool = true
    ) -> Self {
        if isCancelled { return .cancelled }
        if hasError { return .failed }
        if isInCloud && !hasImage && !allowsNetwork { return .cloudUnavailable }
        if isDegraded { return hasImage ? .preview : .waiting }
        if hasImage { return .final }
        return isInCloud ? .cloudUnavailable : .failed
    }
}
