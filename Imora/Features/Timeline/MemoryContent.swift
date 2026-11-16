import Foundation

extension Memory {
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let ruleTitle { return ruleTitle }
        if isBirthday {
            let name = data.personName ?? ""
            return name.isEmpty ? String(localized: "Birthday") : String(localized: "\(name)'s Birthday")
        }
        guard let year = data.year else { return String(localized: "Memory") }
        let years = Calendar.current.component(.year, from: Date()) - year
        return years <= 1 ? String(localized: "1 year ago") : String(localized: "\(years) years ago")
    }

    /// A deleted or locked item must not become a slideshow frame. Identity is
    /// per asset within a memory, and per memory when matching card transitions.
    var playableAssets: [Asset] {
        var seen = Set<String>()
        return assets.map { $0.asAsset() }.filter {
            !$0.isTrashed && $0.visibility != .locked && seen.insert($0.id).inserted
        }
    }
}

struct MemorySlideshowRoute: Identifiable {
    let id = UUID()
    let memory: Memory
}

nonisolated struct MemoryPlaybackPosition: Equatable {
    let durations: [TimeInterval]
    private(set) var index = 0
    private(set) var elapsed: TimeInterval = 0
    var isPlaying = true
    var isReady = false
    private(set) var isFinished = false

    init(assets: [Asset]) {
        durations = assets.map {
            $0.isVideo ? min(12, max(1, Double($0.duration ?? 5_000) / 1_000)) : 5
        }
    }

    var duration: TimeInterval { durations.indices.contains(index) ? durations[index] : 1 }
    var progress: Double { min(1, max(0, elapsed / duration)) }

    @discardableResult mutating func select(_ index: Int) -> Bool {
        guard durations.indices.contains(index) else { return false }
        self.index = index
        elapsed = 0
        isReady = false
        isFinished = false
        return true
    }

    /// Buffering and pauses do not consume a slide's viewing time. A new
    /// frame gets its full duration even after a slow download or suspension.
    @discardableResult mutating func advance(by seconds: TimeInterval) -> Bool {
        guard isReady, isPlaying, !isFinished, seconds.isFinite, seconds > 0 else { return false }
        elapsed = min(duration, elapsed + seconds)
        guard elapsed >= duration else { return false }
        if select(index + 1) { return true }
        isFinished = true
        isPlaying = false
        return false
    }
}
