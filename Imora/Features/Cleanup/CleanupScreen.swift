import Foundation
import SwiftUI

/// where the cleanup overview leads.
nonisolated enum CleanupRoute: Hashable {
    case rewind(monthDay: Int)
    case queue(CleanupQueue)
    case duplicates
}

struct CleanupRouteScreen: View {
    let route: CleanupRoute

    var body: some View {
        switch route {
        case .rewind(let monthDay):
            CleanupRewindScreen(monthDay: monthDay)
        case .queue(.bursts):
            CleanupBurstsScreen()
        case .queue(let queue):
            CleanupQueueScreen(queue: queue)
        case .duplicates:
            DuplicatesScreen()
        }
    }
}

/// today's rewind, the quick wins with their counts, the trash and the year
/// of reviewed days. gallery's library cleanup, which imora implements too.
struct CleanupScreen: View {
    @Environment(SessionStore.self) private var session
    @State private var calendar: CleanupCalendar?
    @State private var trash: CleanupTotals?
    @State private var counts: [CleanupQueue: CleanupQueueCount] = [:]
    @State private var covers: [CleanupQueue: CleanupAsset] = [:]
    @State private var peek: RewindPeek?
    @State private var confirmEmpty = false
    @State private var isEmptying = false
    @State private var emptiedCount = 0

    private static let queues: [CleanupQueue] = [.spaceHogs, .blurry, .screenshots, .bursts, .duplicates]
    /// how long a photo takes to decide, for the banner's estimate.
    private static let secondsPerPhoto = 4

    private var today: Int { CleanupMonthDay.today() }
    private var trashEnabled: Bool { session.features?.trash != false }

    private var couldFree: Int64? {
        guard counts.count == Self.queues.count else { return nil }
        return counts.values.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        List {
            Section {
                rewindBanner
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
            } footer: {
                if let calendar {
                    Text(String(localized: "\(calendar.daysReviewed) of 366 days reviewed. \(calendar.streak)-day streak."))
                }
            }

            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(Self.queues, id: \.self) { queue in
                        NavigationLink(value: queue == .duplicates ? CleanupRoute.duplicates : .queue(queue)) {
                            CleanupQueueCard(queue: queue, count: counts[queue], cover: covers[queue])
                        }
                        .buttonStyle(PressableCardStyle())
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
            } header: {
                Text("Quick Wins")
            } footer: {
                if let couldFree, couldFree > 0 {
                    Text("Could still free \(CleanupText.bytes(couldFree)).")
                }
            }

            if trashEnabled {
                Section {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Trash")
                                if let trash {
                                    Text(String(localized: "\(CleanupText.count(trash.count, unit: .item)), \(CleanupText.bytes(trash.bytes))"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        } icon: {
                            Image(systemName: "trash")
                        }
                        Spacer()
                        Button("Empty", role: .destructive) { confirmEmpty = true }
                            .buttonStyle(.bordered)
                            .disabled((trash?.count ?? 0) == 0 || isEmptying)
                            .confirmationDialog(
                                "Permanently delete everything in the trash?",
                                isPresented: $confirmEmpty,
                                titleVisibility: .visible
                            ) {
                                Button("Empty Trash", role: .destructive) {
                                    Task { await emptyTrash() }
                                }
                            } message: {
                                Text("This cannot be undone.")
                            }
                    }
                }
            }

            Section {
                if let calendar {
                    CleanupCalendarView(days: calendar.days, today: today)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
            } header: {
                Text("Your Year")
            } footer: {
                Text("Each date gathers its photos from every year. Tap one to review it.")
            }
        }
        .navigationTitle("Clean Up")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: emptiedCount)
        .refreshable { await load() }
        // every return from a queue or a rewind changes these.
        .task { await load() }
    }

    // MARK: rewind banner

    private var rewindBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let peek, !peek.assets.isEmpty {
                RewindPeekMosaic(assets: peek.assets)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Today, \(CleanupMonthDay.label(today))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if let peek {
                    if peek.photos > 0 {
                        Text(String(localized: "\(CleanupText.count(peek.photos, unit: .photo)) from \(CleanupText.count(peek.years, unit: .year))"))
                            .font(.title3.weight(.semibold))
                        if let detail = peekDetail(peek) {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No photos were taken on this date.")
                            .font(.title3.weight(.semibold))
                    }
                } else {
                    Text("Looking back...")
                        .font(.title3.weight(.semibold))
                        .redacted(reason: .placeholder)
                }
            }
            NavigationLink(value: CleanupRoute.rewind(monthDay: today)) {
                Label("Start Today's Rewind", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled((peek?.photos ?? 0) == 0)
            .accessibilityIdentifier("cleanup-start-rewind")
        }
    }

    private func peekDetail(_ peek: RewindPeek) -> String? {
        var parts: [String] = []
        if calendar?.days.first(where: { $0.monthDay == today })?.isReviewed == true {
            parts.append(String(localized: "Reviewed. You can open it again any time."))
        } else {
            let minutes = Int((Double(peek.photos * Self.secondsPerPhoto) / 60).rounded())
            if minutes >= 1 { parts.append(String(localized: "About \(CleanupText.count(minutes, unit: .minute)).")) }
        }
        if let busiest = peek.busiestYear {
            parts.append(peek.city.map { String(localized: "\(busiest) in \($0) has the most.") } ?? String(localized: "\(busiest) has the most."))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: loading

    private func load() async {
        guard let client = session.client else { return }
        let day = today
        var jobs = [
            Task { if let value = try? await client.cleanupCalendar() { calendar = value } },
            Task { if let value = await RewindPeek.load(client: client, monthDay: day) { peek = value } },
        ]
        if trashEnabled {
            jobs.append(Task { if let value = try? await client.cleanupTrash() { trash = value } })
        }
        for queue in Self.queues {
            jobs.append(Task { await loadCount(queue, client: client) })
        }
        for job in jobs { await job.value }
    }

    private func loadCount(_ queue: CleanupQueue, client: ImoraClient) async {
        guard let count = try? await client.cleanupCount(queue) else { return }
        counts[queue] = count
        // bursts are the heaviest to group, so their card keeps its symbol.
        guard count.count > 0, [.spaceHogs, .blurry, .screenshots].contains(queue) else {
            covers[queue] = nil
            return
        }
        if let first = try? await client.cleanupPage(queue, limit: 1).items.first {
            covers[queue] = first
        }
    }

    private func emptyTrash() async {
        guard let client = session.client else { return }
        isEmptying = true
        defer { isEmptying = false }
        do {
            try await client.emptyTrash()
            emptiedCount += 1
            // the server empties it in a job, so asking again right away still counts what is going.
            trash = CleanupTotals(count: 0, bytes: 0)
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't empty the trash"), error: error)
        }
    }
}

// MARK: - rewind peek

/// today's date at a glance: how many photos, from how many years, and a few
/// of the busiest year's.
nonisolated struct RewindPeek: Sendable {
    let photos: Int
    let years: Int
    let busiestYear: Int?
    let city: String?
    let assets: [CleanupAsset]

    @concurrent
    static func load(client: ImoraClient, monthDay: Int) async -> RewindPeek? {
        guard let years = try? await client.cleanupRewindYears(monthDay: monthDay) else { return nil }
        // the year with the most photos, the most recent on a tie.
        let busiest = years.max { lhs, rhs in
            lhs.count == rhs.count ? lhs.year < rhs.year : lhs.count < rhs.count
        }
        var assets: [CleanupAsset] = []
        if let busiest {
            assets = (try? await client.cleanupRewindAssets(monthDay: monthDay, year: busiest.year)) ?? []
        }
        return RewindPeek(
            photos: years.reduce(0) { $0 + $1.count },
            years: years.count,
            busiestYear: busiest?.year,
            city: dominantCity(assets),
            assets: Array(assets.prefix(5))
        )
    }

    static func dominantCity(_ assets: [CleanupAsset]) -> String? {
        var counts: [String: Int] = [:]
        var best: String?
        for city in assets.compactMap(\.city) where !city.isEmpty {
            counts[city, default: 0] += 1
            if best == nil || counts[city, default: 0] > counts[best ?? "", default: 0] { best = city }
        }
        return best
    }
}

private struct RewindPeekMosaic: View {
    let assets: [CleanupAsset]

    var body: some View {
        HStack(spacing: 4) {
            if let first = assets.first {
                CleanupThumbnail(asset: first, size: "preview", targetPixelSize: 900)
                    .clipShape(.rect(cornerRadius: 14))
            }
            let rest = Array(assets.dropFirst())
            if !rest.isEmpty {
                VStack(spacing: 4) {
                    ForEach(rest.prefix(2)) { asset in
                        CleanupThumbnail(asset: asset)
                            .clipShape(.rect(cornerRadius: 10))
                    }
                }
                .frame(width: 84)
                if rest.count > 2 {
                    VStack(spacing: 4) {
                        ForEach(rest.dropFirst(2).prefix(2)) { asset in
                            CleanupThumbnail(asset: asset)
                                .clipShape(.rect(cornerRadius: 10))
                        }
                    }
                    .frame(width: 84)
                }
            }
        }
        .frame(height: 172)
        .accessibilityHidden(true)
    }
}

// MARK: - queue card

private struct CleanupQueueCard: View {
    let queue: CleanupQueue
    let count: CleanupQueueCount?
    let cover: CleanupAsset?

    private var symbol: String {
        switch queue {
        case .spaceHogs: "externaldrive"
        case .blurry: "camera.aperture"
        case .screenshots: "camera.viewfinder"
        case .bursts: "square.stack.3d.down.right"
        default: "square.on.square"
        }
    }

    private var countText: String {
        guard let count else { return "" }
        guard count.count > 0 else { return String(localized: "All clear") }
        switch queue {
        case .spaceHogs: return CleanupText.count(count.count, unit: .file)
        case .bursts: return CleanupText.count(count.count, unit: .series)
        case .duplicates: return CleanupText.count(count.count, unit: .group)
        default:
            return count.isAnalysing
                ? String(localized: "\(count.count.formatted()) so far")
                : CleanupText.count(count.count, unit: .photo)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color(.tertiarySystemFill)
                .frame(height: 76)
                .overlay {
                    if let cover {
                        CleanupThumbnail(asset: cover)
                    } else {
                        Image(systemName: symbol)
                            .font(.title2)
                            .foregroundStyle(.tint)
                    }
                }
                .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(queue.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if count == nil {
                    Text("Counting")
                        .font(.caption)
                        .redacted(reason: .placeholder)
                } else {
                    Text(countText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let count, count.bytes > 0 {
                        Text(CleanupText.bytes(count.bytes))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tint)
                    }
                    if let count, count.isAnalysing, let percent = count.analysedPercent {
                        Text("Analyzing, \(Int(percent))% done")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .monospacedDigit()
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 16))
        .contentShape(.rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cleanup-queue-\(queue.rawValue)")
    }
}

// MARK: - calendar

/// the year as twelve rows of days, shaded by how many photos each date
/// holds across every year, green once reviewed.
struct CleanupCalendarView: View {
    let days: [CleanupCalendarDay]
    let today: Int

    private var byDay: [Int: CleanupCalendarDay] {
        Dictionary(days.map { ($0.monthDay, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// quartiles of the dates with photos, so one very busy date does not wash out the others.
    private var quartiles: (q1: Int, q2: Int, q3: Int, max: Int) {
        let sorted = days.map(\.assetCount).filter { $0 > 0 }.sorted()
        func at(_ p: Double) -> Int {
            sorted.isEmpty ? 0 : sorted[max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)]
        }
        return (at(0.25), at(0.5), at(0.75), sorted.last ?? 0)
    }

    var body: some View {
        let byDay = byDay
        let scale = quartiles
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 3) {
                ForEach(1...12, id: \.self) { month in
                    HStack(spacing: 6) {
                        Text(CleanupMonthDay.monthName(month))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .leading)
                        HStack(spacing: 2) {
                            ForEach(1...31, id: \.self) { day in
                                if day <= CleanupMonthDay.daysIn(month: month) {
                                    cell(byDay[month * 100 + day], monthDay: month * 100 + day, scale: scale)
                                } else {
                                    Color.clear.aspectRatio(1, contentMode: .fit)
                                }
                            }
                        }
                    }
                }
            }
            legend
        }
    }

    private func level(_ count: Int, _ scale: (q1: Int, q2: Int, q3: Int, max: Int)) -> Int {
        if count <= 0 || scale.max <= 0 { return 0 }
        if count >= scale.max { return 4 }
        if count <= scale.q1 { return 1 }
        if count <= scale.q2 { return 2 }
        if count <= scale.q3 { return 3 }
        return 4
    }

    private func color(_ day: CleanupCalendarDay?, _ scale: (q1: Int, q2: Int, q3: Int, max: Int)) -> Color {
        let count = day?.assetCount ?? 0
        let level = level(count, scale)
        if day?.isReviewed == true { return .green.opacity(level <= 1 ? 0.55 : 1) }
        return level == 0 ? Color(.tertiarySystemFill) : Color.accentColor.opacity([0, 0.3, 0.5, 0.75, 1][level])
    }

    @ViewBuilder
    private func cell(_ day: CleanupCalendarDay?, monthDay: Int, scale: (q1: Int, q2: Int, q3: Int, max: Int)) -> some View {
        let count = day?.assetCount ?? 0
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        NavigationLink(value: CleanupRoute.rewind(monthDay: monthDay)) {
            shape
                .fill(color(day, scale))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if monthDay == today { shape.strokeBorder(.primary, lineWidth: 1.5) }
                }
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .accessibilityLabel(
            day?.isReviewed == true
                ? String(localized: "\(CleanupMonthDay.label(monthDay)), \(CleanupText.count(count, unit: .photo)), reviewed")
                : String(localized: "\(CleanupMonthDay.label(monthDay)), \(CleanupText.count(count, unit: .photo))")
        )
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(Color(.tertiarySystemFill), String(localized: "No photos"))
            legendItem(Color.accentColor.opacity(0.5), String(localized: "To review"))
            legendItem(.green, String(localized: "Reviewed"))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func legendItem(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(title)
        }
    }
}
