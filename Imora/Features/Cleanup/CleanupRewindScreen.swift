import Foundation
import SwiftUI

/// one date's photos from every year, decided one at a time in the deck. the
/// marks stay on the device until the day is finished, so leaving resumes
/// where it stopped, then one commit applies them and marks the date reviewed.
struct CleanupRewindScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var monthDay: Int
    @State private var years: [CleanupRewindYear]?
    @State private var assets: [CleanupAsset] = []
    @State private var book = CleanupMarkBook()
    @State private var showsReviewed = false
    @State private var summary: Summary?
    @State private var isBusy = false
    @State private var notice: CleanupNotice?
    @State private var confirmer = CleanupConfirmer()
    @State private var viewer = ViewerPresentation()
    @State private var finishedCount = 0
    /// the file the marks go to, set once the day's saved marks are read back.
    @State private var loadedKey: String?
    /// the viewer's cover coming down appears the screen again, which must not reload it.
    @State private var loadedDay: Int?
    @Namespace private var zoomNamespace

    /// shots at most this far apart form a burst, the server's `CLEANUP_BURST_GAP_MS`.
    private static let burstGap: TimeInterval = 2

    struct Summary {
        let kept: Int
        let favorited: Int
        let trashed: Int
        let freed: Int64
        let streak: Int?
        let next: Int?
    }

    init(monthDay: Int) {
        _monthDay = State(initialValue: monthDay)
    }

    private var trashEnabled: Bool { session.features?.trash != false }

    private var storeKey: String {
        CleanupMarksStore.rewindKey(
            account: session.client?.offlineAccountKey ?? "local",
            userID: session.user?.id ?? "me",
            monthDay: monthDay
        )
    }

    private var shown: [CleanupAsset] {
        showsReviewed ? assets : assets.filter { !$0.kept }
    }

    private var undecided: [CleanupAsset] {
        shown.filter { book[$0.id] == nil }
    }

    private var burstIDs: Set<String> {
        let images = assets.filter { $0.type == .image }.sorted { $0.localDate < $1.localDate }
        var ids = Set<String>()
        for (previous, next) in zip(images, images.dropFirst())
        where next.localDate.timeIntervalSince(previous.localDate) <= Self.burstGap {
            ids.insert(previous.id)
            ids.insert(next.id)
        }
        return ids
    }

    var body: some View {
        @Bindable var viewer = viewer
        content
            .navigationTitle(CleanupMonthDay.label(monthDay))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .cleanupConfirmations(confirmer)
            .cleanupNotice($notice)
            .sensoryFeedback(.success, trigger: finishedCount)
            .fullScreenCover(item: $viewer.route) { route in
                AssetViewerScreen(
                    assets: route.assets,
                    indexByAssetID: route.indexByAssetID,
                    initialIndex: route.initialIndex,
                    presentationID: route.id,
                    zoomNamespace: zoomNamespace,
                    onRequestDismissal: { viewer.complete(route.id) },
                    onDismissed: { viewer.complete(route.id) }
                ) { change in
                    apply(change)
                }
            }
            .task(id: monthDay) {
                guard loadedDay != monthDay else { return }
                await load()
            }
            .onChange(of: book) { _, book in
                if let loadedKey { CleanupMarksStore.save(book, key: loadedKey) }
            }
    }

    @ViewBuilder private var content: some View {
        if let summary {
            CleanupRewindDone(
                monthDay: monthDay,
                summary: summary,
                trashEnabled: trashEnabled,
                onNext: { next in monthDay = next },
                onDone: { dismiss() }
            )
        } else if years == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shown.isEmpty {
            ContentUnavailableView {
                Label("Nothing to Review", systemImage: "checkmark.circle")
            } description: {
                Text(assets.isEmpty
                     ? "No photos were taken on this date."
                     : "Every photo of this date was reviewed before.")
            } actions: {
                if !assets.isEmpty {
                    Button("Show Reviewed Photos") { showsReviewed = true }
                }
            }
        } else {
            VStack(spacing: 14) {
                header
                if undecided.isEmpty {
                    finishPanel
                } else {
                    CleanupDeck(
                        assets: undecided,
                        trashEnabled: trashEnabled,
                        canUndo: book.canUndo,
                        onMark: { asset, mark in book.mark([asset.id], mark) },
                        onUndo: { book.undo() },
                        onOpen: open
                    ) { asset in
                        cardInfo(asset)
                    }
                    .disabled(isBusy)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private var header: some View {
        let total = shown.count
        let left = undecided.count
        return VStack(spacing: 6) {
            Text(String(localized: "\(CleanupText.count(total, unit: .photo)) from \(CleanupText.count(years?.count ?? 0, unit: .year))"))
                .font(.subheadline.weight(.medium))
            ProgressView(value: Double(total - left), total: Double(max(total, 1)))
                .tint(.accentColor)
            Text(left == 0 ? "All decided" : "\(left.formatted()) left")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .padding(.top, 8)
    }

    @ViewBuilder
    private func cardInfo(_ asset: CleanupAsset) -> some View {
        let yearsAgo = Calendar.current.component(.year, from: Date()) - asset.year
        VStack(alignment: .leading, spacing: 4) {
            Text(yearsAgo > 0 ? CleanupText.count(yearsAgo, unit: .yearAgo) : String(localized: "This year"))
                .font(.title3.weight(.bold))
            Text([asset.dateText, asset.city.map { PhotoPlaceName.localized($0) }].compactMap { $0 }.joined(separator: ", "))
                .font(.subheadline)
            ForEach(hints(asset), id: \.self) { hint in
                Label(hint, systemImage: "info.circle")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.35), in: .capsule)
            }
        }
    }

    private func hints(_ asset: CleanupAsset) -> [String] {
        var list: [String] = []
        switch asset.reason {
        case .blurry: list.append(String(localized: "Looks blurry"))
        case .dark: list.append(String(localized: "Looks too dark"))
        case .bright: list.append(String(localized: "Looks overexposed"))
        default: break
        }
        if burstIDs.contains(asset.id) { list.append(String(localized: "Taken in a burst")) }
        return list
    }

    private var finishPanel: some View {
        let trash = book.ids(.trash)
        let freed = bytes(trash)
        return VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("All Decided")
                .font(.title2.weight(.bold))
            VStack(spacing: 10) {
                summaryRow(String(localized: "Keep"), systemImage: "checkmark.circle.fill", tint: .green, count: book.ids(.keep).count)
                summaryRow(String(localized: "Favorite"), systemImage: "heart.circle.fill", tint: .pink, count: book.ids(.favorite).count)
                summaryRow(
                    trashEnabled ? String(localized: "Trash") : String(localized: "Delete"),
                    systemImage: "trash.circle.fill",
                    tint: .red,
                    count: trash.count,
                    detail: freed > 0 ? CleanupText.bytes(freed) : nil
                )
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
            Spacer()
            Button {
                Task { await finish() }
            } label: {
                Text(isBusy ? "Applying..." : "Finish Day")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy)
            .accessibilityIdentifier("cleanup-finish-day")
            Button("Undo", systemImage: "arrow.uturn.backward") { book.undo() }
                .disabled(!book.canUndo || isBusy)
        }
    }

    private func summaryRow(_ title: String, systemImage: String, tint: Color, count: Int, detail: String? = nil) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            Spacer()
            if let detail {
                Text(detail).foregroundStyle(.secondary)
            }
            Text(count.formatted())
                .fontWeight(.semibold)
        }
        .monospacedDigit()
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if summary == nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Finish") { Task { await finish() } }
                    .disabled(book.isEmpty || isBusy)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Previous Day", systemImage: "chevron.left") {
                        monthDay = CleanupMonthDay.shift(monthDay, by: -1)
                    }
                    Button("Next Day", systemImage: "chevron.right") {
                        monthDay = CleanupMonthDay.shift(monthDay, by: 1)
                    }
                    Divider()
                    Toggle("Show Reviewed Photos", systemImage: "eye", isOn: $showsReviewed)
                    Button("Keep the Rest", systemImage: "checkmark.circle") {
                        book.mark(undecided.map(\.id), .keep)
                    }
                    .disabled(undecided.isEmpty)
                    Button("Clear Marks", systemImage: "xmark.circle", role: .destructive) {
                        book.clear()
                    }
                    .disabled(book.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
                .disabled(isBusy)
            }
        }
    }

    // MARK: loading

    private func load() async {
        summary = nil
        years = nil
        assets = []
        loadedKey = nil
        guard let client = session.client else { return }
        let day = monthDay
        do {
            let found = try await client.cleanupRewindYears(monthDay: day)
            let byYear = try await withThrowingTaskGroup(of: (Int, [CleanupAsset]).self) { group in
                for year in found {
                    group.addTask { (year.year, try await client.cleanupRewindAssets(monthDay: day, year: year.year)) }
                }
                var result: [Int: [CleanupAsset]] = [:]
                for try await (year, assets) in group { result[year] = assets }
                return result
            }
            guard day == monthDay else { return }
            assets = found.flatMap { byYear[$0.year] ?? [] }
            years = found
            let key = storeKey
            var saved = CleanupMarksStore.load(key) ?? CleanupMarkBook()
            saved.retain(Set(assets.map(\.id)))
            loadedKey = key
            loadedDay = day
            book = saved
            if !saved.isEmpty {
                notice = CleanupNotice(message: String(localized: "Picked up where you left off"))
            }
        } catch is CancellationError {
            return
        } catch {
            guard day == monthDay else { return }
            years = []
            book = CleanupMarkBook()
            ErrorToastCenter.shared.show(String(localized: "Couldn't load this date"), error: error)
        }
    }

    private func bytes(_ ids: [String]) -> Int64 {
        let set = Set(ids)
        return assets.reduce(0) { set.contains($1.id) ? $0 + $1.fileSize : $0 }
    }

    // MARK: finishing

    private func finish() async {
        guard let client = session.client, !isBusy, summary == nil else { return }
        let trash = book.ids(.trash)
        let favorite = book.ids(.favorite)
        let keep = book.ids(.keep)
        let trashEnabled = trashEnabled
        isBusy = true
        defer { isBusy = false }
        do {
            guard try await confirmer.confirmTrash(trash, trashEnabled: trashEnabled, client: client) else { return }
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't check the photos before trashing. Nothing was changed."))
            return
        }
        let freed = bytes(trash)
        let day = monthDay
        do {
            let (trashed, skipped) = try await send(client: client, trash: trash, favorite: favorite, keep: keep, monthDay: day)
            let gone = Set(trashed)
            assets.removeAll { gone.contains($0.id) }
            let calendar = try? await client.cleanupCalendar()
            summary = Summary(
                kept: keep.count,
                favorited: favorite.count,
                trashed: trashed.count,
                freed: freed,
                streak: calendar?.streak,
                next: calendar.flatMap { CleanupMonthDay.nextUnreviewed(in: $0.days, after: day) }
            )
            finishedCount += 1
            if let skippedText = CleanupText.skipped(skipped) {
                notice = CleanupNotice(message: skippedText)
            } else if !trashed.isEmpty {
                var undo: (@MainActor () async -> Void)?
                if trashEnabled { undo = { await restore(trashed, client: client) } }
                notice = CleanupNotice(message: CleanupText.removed(trashed.count, trashEnabled: trashEnabled), undo: undo)
            }
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't finish the day. Your marks are kept"), error: error)
        }
    }

    /// every mark in requests of at most the server's id limit, the date
    /// completed by the last. each request settles its marks, so a retry after
    /// a later failure never sends them twice.
    private func send(
        client: ImoraClient,
        trash: [String],
        favorite: [String],
        keep: [String],
        monthDay: Int
    ) async throws -> ([String], Int) {
        let trashBatches = trash.cleanupBatches
        let favoriteBatches = favorite.cleanupBatches
        let keepBatches = keep.cleanupBatches
        let calls = max(1, trashBatches.count, favoriteBatches.count, keepBatches.count)
        var trashed: [String] = []
        var skipped = 0
        for index in 0..<calls {
            let trashIDs = trashBatches.indices.contains(index) ? trashBatches[index] : []
            let favoriteIDs = favoriteBatches.indices.contains(index) ? favoriteBatches[index] : []
            let keepIDs = keepBatches.indices.contains(index) ? keepBatches[index] : []
            let result = try await client.cleanupCommit(CleanupCommit(
                queue: .rewind,
                trashIds: trashIDs,
                favoriteIds: favoriteIDs,
                keepIds: keepIDs,
                completeMonthDay: index == calls - 1 ? monthDay : nil
            ))
            trashed += result.trashed
            skipped += result.skipped.count
            if monthDay == self.monthDay {
                book.settle(trashIDs + favoriteIDs + keepIDs)
            }
        }
        return (trashed, skipped)
    }

    private func restore(_ ids: [String], client: ImoraClient) async {
        do {
            for batch in ids.cleanupBatches { try await client.restoreAssets(ids: batch) }
            notice = CleanupNotice(message: String(localized: "Restored \(CleanupText.count(ids.count, unit: .photo))"))
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't restore the photos"), error: error)
        }
    }

    // MARK: viewer

    private func open(_ asset: CleanupAsset) {
        let list = shown
        guard let index = list.firstIndex(where: { $0.id == asset.id }) else { return }
        let owner = session.user?.id ?? ""
        viewer.present(assets: list.map { $0.asAsset(ownerID: owner) }, initialIndex: index)
    }

    private func apply(_ change: AssetChange) {
        switch change {
        case .removed(let id), .removalCommitted(let id):
            assets.removeAll { $0.id == id }
            book.retain(Set(assets.map(\.id)))
        case .favoriteCommitted(let id, let value):
            if let index = assets.firstIndex(where: { $0.id == id }) { assets[index].isFavorite = value }
        default:
            break
        }
    }
}

/// the day is finished: what it did, the streak and the next date to review.
private struct CleanupRewindDone: View {
    let monthDay: Int
    let summary: CleanupRewindScreen.Summary
    let trashEnabled: Bool
    let onNext: (Int) -> Void
    let onDone: () -> Void

    private var detail: String {
        var parts: [String] = []
        if summary.kept > 0 {
            parts.append(summary.kept == 1 ? String(localized: "Kept 1 photo.") : String(localized: "Kept \(summary.kept.formatted()) photos."))
        }
        if summary.favorited > 0 {
            parts.append(summary.favorited == 1 ? String(localized: "Favorited 1 photo.") : String(localized: "Favorited \(summary.favorited.formatted()) photos."))
        }
        if summary.trashed > 0 {
            if trashEnabled {
                parts.append(summary.trashed == 1 ? String(localized: "Trashed 1 photo.") : String(localized: "Trashed \(summary.trashed.formatted()) photos."))
            } else {
                parts.append(summary.trashed == 1 ? String(localized: "Deleted 1 photo.") : String(localized: "Deleted \(summary.trashed.formatted()) photos."))
            }
        }
        guard !parts.isEmpty else { return String(localized: "Nothing changed, and the date is reviewed.") }
        if summary.freed > 0 { parts.append(String(localized: "\(CleanupText.bytes(summary.freed)) freed.")) }
        return parts.joined(separator: " ")
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: monthDay)
            Text("\(CleanupMonthDay.label(monthDay)) Reviewed")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let streak = summary.streak, streak > 0 {
                Label(CleanupText.count(streak, unit: .dayStreak), systemImage: "flame.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .monospacedDigit()
            }
            Spacer()
            if let next = summary.next {
                Button {
                    onNext(next)
                } label: {
                    Text("Review \(CleanupMonthDay.label(next))")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Button("Done", action: onDone)
                .controlSize(.large)
        }
        .padding(24)
    }
}
