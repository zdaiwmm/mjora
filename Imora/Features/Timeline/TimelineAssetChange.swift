import Foundation

/// narrow mutations keep externally supplied timelines in sync with their source.
nonisolated enum TimelineAssetChange {
    case updated([Asset])
    case removed(Set<String>)
    case restored([Asset])
}
