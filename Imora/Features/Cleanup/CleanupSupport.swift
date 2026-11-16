import Foundation
import SwiftUI

// MARK: - marks

/// a decision on one rewind photo. nothing reaches the server until the day is finished.
nonisolated enum CleanupMark: String, Codable, Hashable, Sendable {
    case keep, favorite, trash
}

/// the marks of one session with its undo steps. a step is one decision and
/// remembers what each photo was before, so undoing it puts every one back.
nonisolated struct CleanupMarkBook: Codable, Equatable, Sendable {
    struct Change: Codable, Equatable, Sendable {
        let id: String
        let mark: CleanupMark?
    }

    private(set) var marks: [String: CleanupMark] = [:]
    private(set) var history: [[Change]] = []

    var isEmpty: Bool { marks.isEmpty }
    var canUndo: Bool { !history.isEmpty }

    subscript(id: String) -> CleanupMark? { marks[id] }

    func ids(_ mark: CleanupMark) -> [String] {
        marks.filter { $0.value == mark }.map(\.key).sorted()
    }

    mutating func mark(_ ids: [String], _ mark: CleanupMark) {
        let step = ids.map { Change(id: $0, mark: marks[$0]) }
        guard !step.isEmpty else { return }
        history.append(step)
        for id in ids { marks[id] = mark }
    }

    /// steps back one decision and answers the photos it touched.
    @discardableResult
    mutating func undo() -> [String] {
        guard let step = history.popLast() else { return [] }
        for change in step { marks[change.id] = change.mark }
        return step.map(\.id)
    }

    /// drops the marks the server has now. the undo steps may point at them, so they go too.
    mutating func settle(_ ids: some Sequence<String>) {
        for id in ids { marks[id] = nil }
        history.removeAll()
    }

    /// keeps the marks of the photos still there.
    mutating func retain(_ present: Set<String>) {
        marks = marks.filter { present.contains($0.key) }
        history = history
            .map { $0.filter { present.contains($0.id) } }
            .filter { !$0.isEmpty }
    }

    mutating func clear() {
        marks.removeAll()
        history.removeAll()
    }
}

/// the pending marks on disk, written as they are made, so leaving the screen
/// or the app loses nothing. one small file per account and day.
nonisolated enum CleanupMarksStore {
    private static let root: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "imora/cleanup")

    static func rewindKey(account: String, userID: String, monthDay: Int) -> String {
        "rewind-\(account)-\(userID)-\(monthDay)"
    }

    private static func file(_ key: String) -> URL {
        let safe = String(key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
        return root.appending(path: safe + ".json")
    }

    static func load(_ key: String) -> CleanupMarkBook? {
        guard let data = try? Data(contentsOf: file(key)),
              let book = try? JSONDecoder().decode(CleanupMarkBook.self, from: data),
              !book.isEmpty
        else { return nil }
        return book
    }

    /// an empty book removes the file. failures are ignored: saving is a
    /// safety net and must never stop the deciding.
    static func save(_ book: CleanupMarkBook, key: String) {
        let url = file(key)
        guard !book.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(book) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - confirmations

/// a destructive confirmation asked from code: `ask` resolves once the user answered.
@MainActor
@Observable
final class CleanupConfirmer {
    struct Prompt: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirm: String
    }

    fileprivate(set) var prompt: Prompt?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    func ask(title: String, message: String, confirm: String) async -> Bool {
        answer(false)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            prompt = Prompt(title: title, message: message, confirm: confirm)
        }
    }

    func answer(_ confirmed: Bool) {
        prompt = nil
        continuation?.resume(returning: confirmed)
        continuation = nil
    }

    /// asks before photos go: always when the trash is off and the delete is
    /// permanent, and when some are in a shared space or an external library,
    /// like the server's web app. throws when the lookup fails, so nothing is
    /// trashed unchecked.
    func confirmTrash(_ ids: [String], trashEnabled: Bool, client: ImoraClient) async throws -> Bool {
        guard !ids.isEmpty else { return true }
        var inSpaces = 0
        var external = 0
        for batch in ids.cleanupBatches {
            let found = try await client.cleanupInSpaces(assetIDs: batch)
            inSpaces += found.assetIds.count
            external += found.externalAssetIds.count
        }
        var sentences: [String] = []
        if !trashEnabled {
            sentences.append(ids.count == 1
                ? String(localized: "The trash is off on this server, so this photo is deleted permanently. This cannot be undone.")
                : String(localized: "The trash is off on this server, so these \(ids.count) photos are deleted permanently. This cannot be undone."))
            if inSpaces > 0 {
                sentences.append(inSpaces == 1
                    ? String(localized: "1 photo is also in a shared space and will be removed for its members too.")
                    : String(localized: "\(inSpaces.formatted()) photos are also in a shared space and will be removed for its members too."))
            }
        } else if inSpaces > 0 {
            sentences.append(inSpaces == 1
                ? String(localized: "1 photo is also in a shared space. Trashing removes it for its members too.")
                : String(localized: "\(inSpaces.formatted()) photos are also in a shared space. Trashing removes them for its members too."))
        }
        if external > 0 {
            sentences.append(external == 1
                ? String(localized: "1 photo is from an external library. If the server can only read that folder, it comes back at the next library scan and no space is freed.")
                : String(localized: "\(external.formatted()) photos are from an external library. If the server can only read that folder, they come back at the next library scan and no space is freed."))
        }
        if trashEnabled && sentences.isEmpty { return true }
        return await ask(
            title: trashEnabled ? String(localized: "Move to Trash?") : String(localized: "Delete Permanently?"),
            message: sentences.joined(separator: " "),
            confirm: trashEnabled ? String(localized: "Move to Trash") : String(localized: "Delete Permanently")
        )
    }

}

private struct CleanupConfirmations: ViewModifier {
    let confirmer: CleanupConfirmer

    func body(content: Content) -> some View {
        content.alert(
            confirmer.prompt?.title ?? "",
            isPresented: Binding(
                get: { confirmer.prompt != nil },
                set: { shown in
                    // the chosen button answers first, a plain dismissal lands here.
                    if !shown { Task { confirmer.answer(false) } }
                }
            ),
            presenting: confirmer.prompt
        ) { prompt in
            Button(prompt.confirm, role: .destructive) { confirmer.answer(true) }
            Button("Cancel", role: .cancel) { confirmer.answer(false) }
        } message: { prompt in
            Text(prompt.message)
        }
    }
}

// MARK: - notices

/// what an action did, with an undo while it can still be taken back.
struct CleanupNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var undo: (@MainActor () async -> Void)?

    static func == (lhs: CleanupNotice, rhs: CleanupNotice) -> Bool { lhs.id == rhs.id }
}

private struct CleanupNoticeBanner: View {
    @Binding var notice: CleanupNotice?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let current = notice {
                HStack(spacing: 14) {
                    Text(current.message)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    if let undo = current.undo {
                        Button("Undo") {
                            notice = nil
                            Task { await undo() }
                        }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("cleanup-undo")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .id(current.id)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .task {
                    AccessibilityNotification.Announcement(current.message).post()
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, notice?.id == current.id else { return }
                    notice = nil
                }
            }
        }
        .animation(PhotosMotion.layout, value: notice)
    }
}

extension View {
    func cleanupConfirmations(_ confirmer: CleanupConfirmer) -> some View {
        modifier(CleanupConfirmations(confirmer: confirmer))
    }

    func cleanupNotice(_ notice: Binding<CleanupNotice?>) -> some View {
        overlay(alignment: .bottom) { CleanupNoticeBanner(notice: notice) }
    }
}

// MARK: - helpers

extension Array where Element == String {
    /// requests of at most the server's id limit.
    nonisolated var cleanupBatches: [[String]] {
        stride(from: 0, to: count, by: ImoraClient.cleanupMaxIDs).map {
            Array(self[$0..<Swift.min($0 + ImoraClient.cleanupMaxIDs, count)])
        }
    }
}

nonisolated enum CleanupText {
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }

    enum CountUnit {
        case photo, day, year, item, minute, file, series, group, yearAgo, dayStreak
    }

    static func count(_ value: Int, unit: CountUnit) -> String {
        switch unit {
        case .photo:
            value == 1 ? String(localized: "1 photo") : String(localized: "\(value.formatted()) photos")
        case .day:
            value == 1 ? String(localized: "1 day") : String(localized: "\(value.formatted()) days")
        case .year:
            value == 1 ? String(localized: "1 year") : String(localized: "\(value.formatted()) years")
        case .item:
            value == 1 ? String(localized: "1 item") : String(localized: "\(value.formatted()) items")
        case .minute:
            value == 1 ? String(localized: "1 minute") : String(localized: "\(value.formatted()) minutes")
        case .file:
            value == 1 ? String(localized: "1 file") : String(localized: "\(value.formatted()) files")
        case .series:
            String(localized: "\(value.formatted()) series")
        case .group:
            value == 1 ? String(localized: "1 group") : String(localized: "\(value.formatted()) groups")
        case .yearAgo:
            value == 1 ? String(localized: "1 year ago") : String(localized: "\(value.formatted()) years ago")
        case .dayStreak:
            String(localized: "\(value.formatted()) day streak")
        }
    }

    /// what a trash did, worded for the server's trash setting.
    static func removed(_ count: Int, trashEnabled: Bool) -> String {
        if trashEnabled {
            return count == 1 ? String(localized: "Moved 1 photo to the trash") : String(localized: "Moved \(count.formatted()) photos to the trash")
        }
        return count == 1 ? String(localized: "Deleted 1 photo permanently") : String(localized: "Deleted \(count.formatted()) photos permanently")
    }

    static func skipped(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? String(localized: "1 photo had already changed and was skipped.")
            : String(localized: "\(count.formatted()) photos had already changed and were skipped.")
    }
}

/// a cleanup photo's thumbnail, square and filled.
struct CleanupThumbnail: View {
    @Environment(SessionStore.self) private var session
    let asset: CleanupAsset
    var size = "thumbnail"
    var targetPixelSize: CGFloat = 360

    var body: some View {
        Color(.secondarySystemFill)
            .overlay {
                if let client = session.client {
                    RemoteImage(
                        url: client.thumbnailURL(assetID: asset.id, size: size, cacheKey: asset.thumbhash),
                        targetPixelSize: targetPixelSize,
                        thumbhash: asset.thumbhash
                    )
                }
            }
            .clipped()
    }
}
