import CoreGraphics
import Foundation
import SwiftUI

/// Dimensions supported by the same-device Photos AX capture: 20pt sides,
/// month 362×241.3 (3:2), year 362×271.5 (4:3), at a 402pt viewport.
/// The 10pt corner is a screenshot estimate, not an AX measurement.
nonisolated struct PhotoPeriodCardLayout {
    static let horizontalInset: CGFloat = 20
    static let cornerRadius: CGFloat = 10
    static let monthHeadingGap: CGFloat = 10
    let photoSize: CGSize
    let sectionSpacing: CGFloat

    init(viewportWidth: CGFloat, mode: PhotoBrowseMode) {
        let width = viewportWidth.isFinite ? max(0, viewportWidth - Self.horizontalInset * 2) : 0
        let aspect: CGFloat = mode == .years ? 4.0 / 3.0 : 3.0 / 2.0
        photoSize = CGSize(width: width, height: width / aspect)
        // AX: month photo bottom471.3 → next heading503.3; year card
        // bottom479.3 → next card509.3, each independent of scroll offset.
        sectionSpacing = mode == .years ? 30 : 32
    }

    static func oldestFirst(_ periods: [PhotoPeriod]) -> [PhotoPeriod] {
        periods.sorted { $0.date < $1.date }
    }
}

struct PhotoPeriodsView: View {
    @Environment(SessionStore.self) private var session
    let model: TimelineModel
    @Bindable var controls: PhotosGridControls
    let motion: PhotoPeriodMotion
    @ScaledMetric(relativeTo: .title2) private var yearTitleSize = 24.0
    @State private var pendingAnchorAssetID: String?

    private var periods: [PhotoPeriod] {
        let grouped = controls.mode == .years
            ? PhotoPeriod.years(in: model.sections, preferredAssetID: controls.periodAnchor?.asset.id)
            : PhotoPeriod.months(in: model.sections, year: controls.selectedYear, preferredAssetID: controls.periodAnchor?.asset.id)
        return PhotoPeriodCardLayout.oldestFirst(grouped)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = PhotoPeriodCardLayout(viewportWidth: geometry.size.width, mode: controls.mode)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: layout.sectionSpacing) {
                        ForEach(periods) { period in
                            Group {
                                if controls.mode == .months {
                                    PhotoMonthSection(period: period, model: model, controls: controls,
                                                      motion: motion, layout: layout)
                                        .id("month-content-\(ObjectIdentifier(model))-\(period.id)")
                                } else {
                                    periodButton(period, layout: layout)
                                        .task(id: period.id) {
                                            if period.cover == nil { await model.loadBucket(period.representativeBucketID) }
                                        }
                                }
                            }
                            .id(period.id)
                        }
                        if periods.isEmpty {
                            ContentUnavailableView("No photos yet", systemImage: "photo.on.rectangle")
                        }
                    }
                    .id(controls.mode)
                    .padding(.horizontal, PhotoPeriodCardLayout.horizontalInset)
                    .padding(.top, 12)
                    // MainTabView already reserves the floating controls.
                    .padding(.bottom, 10)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .background(Color(.systemBackground))
                .ignoresSafeArea(edges: .top)
                .accessibilityIdentifier("photos-periods")
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting || phase == .decelerating {
                        pendingAnchorAssetID = nil
                        motion.cancel()
                    }
                }
                .onChange(of: controls.mode, initial: true) { _, _ in
                    pendingAnchorAssetID = controls.periodAnchor?.asset.id
                    restoreAnchor(using: proxy)
                }
                .onChange(of: controls.selectedYear) { _, _ in
                    pendingAnchorAssetID = controls.periodAnchor?.asset.id
                    restoreAnchor(using: proxy)
                }
                .onChange(of: anchorDayTarget) { _, target in
                    if target != nil, pendingAnchorAssetID == controls.periodAnchor?.asset.id {
                        restoreAnchor(using: proxy)
                    }
                }
            }
        }
    }

    private static var captureCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private var anchoredPeriod: PhotoPeriod? {
        guard let anchor = controls.periodAnchor else { return nil }
        let calendar = Self.captureCalendar
        let year = calendar.component(.year, from: anchor.asset.localDate)
        let month = calendar.component(.month, from: anchor.asset.localDate)
        // All may use an upload-month bucket with the same ID as an unrelated
        // capture month. Prefer actual photo identity and capture wall clock.
        return periods.first { $0.cover?.id == anchor.asset.id }
            ?? periods.first { $0.year == year && ($0.month == nil || $0.month == month) }
            ?? periods.first { $0.bucketIDs.contains(anchor.bucketID) }
    }

    private var anchorDayTarget: String? {
        guard controls.mode == .months, let anchor = controls.periodAnchor,
              let period = anchoredPeriod else { return nil }
        let content = PhotoMonthContent(period: period, sections: model.sections,
                                       preferredAssetID: anchor.asset.id, preferredBucketID: anchor.bucketID)
        guard let day = content.days.first(where: { $0.assets.contains(where: { $0.id == anchor.asset.id }) }) else { return nil }
        return "photos-period-day-\(day.id)"
    }

    private func restoreAnchor(using proxy: ScrollViewProxy) {
        if let target = anchorDayTarget {
            proxy.scrollTo(target, anchor: .center)
            pendingAnchorAssetID = nil
        } else if let period = anchoredPeriod {
            proxy.scrollTo(period.id, anchor: .center)
            if controls.mode == .years { pendingAnchorAssetID = nil }
        } else if let latest = periods.last {
            proxy.scrollTo(latest.id, anchor: .bottom)
        }
    }

    private func periodButton(_ period: PhotoPeriod, layout: PhotoPeriodCardLayout) -> some View {
        Button {
            if let asset = period.cover {
                let restoredOffset = controls.periodAnchor?.asset.id == asset.id ? controls.periodAnchor?.scrollOffset : nil
                controls.periodAnchor = PhotoPeriodAnchor(asset: asset, bucketID: period.representativeBucketID,
                                                         scrollOffset: restoredOffset)
            } else {
                // A placeholder must not borrow the previous period's photo.
                controls.periodAnchor = nil
            }
            if controls.mode == .years {
                controls.selectedYear = period.year
                controls.mode = .months
            } else {
                controls.reveal(bucketID: period.representativeBucketID, assetID: period.cover?.id)
            }
        } label: {
            periodPhoto(period, layout: layout)
        }
        .buttonStyle(.plain)
        // Preserve the actionable card ID while exposing the image's own
        // bounds separately from a month's external heading.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilitySummary(period))
        .accessibilityIdentifier("photos-period-\(period.id)")
    }

    private func periodPhoto(_ period: PhotoPeriod, layout: PhotoPeriodCardLayout) -> some View {
        Color(.secondarySystemBackground)
            .frame(width: layout.photoSize.width, height: layout.photoSize.height)
            .overlay {
                if let asset = period.cover {
                    PhotoPeriodCoverSurface(asset: asset, mode: controls.mode, session: session, motion: motion)
                }
            }
            .overlay {
                LinearGradient(colors: [.black.opacity(0.28), .clear], startPoint: .top, endPoint: .center)
            }
            .overlay(alignment: .topLeading) {
                if controls.mode == .years {
                    Text(period.date.formatted(.dateTime.year().utc()))
                        .font(.system(size: yearTitleSize, weight: .bold))
                        .padding(20)
                        .accessibilityIdentifier("photos-period-heading-\(period.id)")
                } else if let asset = period.cover {
                    Text(asset.localDate.formatted(.dateTime.day().utc()))
                        .font(.body.weight(.semibold))
                        .padding(12)
                }
            }
            .foregroundStyle(.white)
            .clipShape(.rect(cornerRadius: PhotoPeriodCardLayout.cornerRadius))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary(period))
            .accessibilityIdentifier("photos-period-photo-\(period.id)")
    }

    private func accessibilitySummary(_ period: PhotoPeriod) -> String {
        let title = period.month == nil ? period.date.formatted(.dateTime.year().utc()) : period.title
        let count = String(localized: "\(period.count) items")
        if let cover = period.cover {
            return "\(title), \(count), \(PhotoDatePresentation.dateTime(wallClock: cover.localDate))"
        }
        return "\(title), \(count)"
    }
}

/// Owns a month's request lifecycle and retained covers independently of other
/// months. The model is capture-date indexed; the All grid keeps its own sort.
private struct PhotoMonthSection: View {
    @Environment(SessionStore.self) private var session
    let period: PhotoPeriod
    let model: TimelineModel
    @Bindable var controls: PhotosGridControls
    let motion: PhotoPeriodMotion
    let layout: PhotoPeriodCardLayout
    @State private var retainedCoverIDs: [String: String] = [:]
    @State private var retry = 0
    @State private var loadingID: UUID?
    @State private var hasAttemptedLoad = false

    private nonisolated struct LoadRequest: Hashable {
        let bucketIDs: [String]
        let retry: Int
    }

    private nonisolated struct CoverIdentity: Equatable {
        let dayID: String
        let assetID: String
    }

    private var content: PhotoMonthContent {
        PhotoMonthContent(period: period, sections: model.sections,
                          preferredAssetID: controls.periodAnchor?.asset.id,
                          preferredBucketID: controls.periodAnchor?.bucketID,
                          retainedCoverIDs: retainedCoverIDs)
    }

    var body: some View {
        let snapshot = content
        VStack(alignment: .leading, spacing: PhotoPeriodCardLayout.monthHeadingGap) {
            Text(period.title)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .frame(width: layout.photoSize.width, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel("\(period.title), \(String(localized: "\(period.count) items"))")
                .accessibilityIdentifier("photos-period-heading-\(period.id)")
            monthPhotos(snapshot)
            if !snapshot.isComplete {
                if loadingID != nil || !hasAttemptedLoad {
                    ProgressView(String(localized: "Loading photos"))
                        .frame(maxWidth: .infinity, minHeight: snapshot.days.isEmpty ? layout.photoSize.height : 44)
                        .accessibilityIdentifier("photos-period-loading-\(period.id)")
                } else {
                    VStack(spacing: 8) {
                        Text("Couldn't load photos").foregroundStyle(.secondary)
                        Button("Retry") { retry += 1 }
                            .accessibilityIdentifier("photos-period-retry-\(period.id)")
                    }
                    .frame(maxWidth: .infinity, minHeight: snapshot.days.isEmpty ? layout.photoSize.height : 60)
                }
            } else if snapshot.days.isEmpty {
                Text("No photos yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .task(id: LoadRequest(bucketIDs: period.bucketIDs.sorted(), retry: retry)) { await loadMissingBuckets() }
        .onChange(of: snapshot.days.map { CoverIdentity(dayID: $0.id, assetID: $0.cover.id) }, initial: true) { _, _ in
            // Store identities only, and re-resolve fresh Asset values from the
            // model each time. Favorite/edit/realtime changes remain visible.
            retainedCoverIDs = Dictionary(uniqueKeysWithValues: snapshot.days.map { ($0.id, $0.cover.id) })
        }
    }

    @ViewBuilder
    private func monthPhotos(_ snapshot: PhotoMonthContent) -> some View {
        // Temporary complete-day presentation. Native multi-day composition is
        // intentionally a separate layout call site pending diverse-photo AX
        // evidence; this full-width stack is not claimed as native parity.
        VStack(alignment: .leading, spacing: PhotoPeriodCardLayout.monthHeadingGap) {
            ForEach(Array(snapshot.days.enumerated()), id: \.element.id) { index, day in
                dayButton(day, isFirst: index == 0)
                    .id("photos-period-day-\(day.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photos-period-photo-\(period.id)")
    }

    private func dayButton(_ day: PhotoMonthDay, isFirst: Bool) -> some View {
        Button {
            let offset = controls.periodAnchor?.asset.id == day.cover.id ? controls.periodAnchor?.scrollOffset : nil
            controls.periodAnchor = PhotoPeriodAnchor(asset: day.cover, bucketID: day.coverBucketID, scrollOffset: offset)
            controls.reveal(bucketID: day.coverBucketID, assetID: day.cover.id)
        } label: {
            Color(.secondarySystemBackground)
                .frame(width: layout.photoSize.width, height: layout.photoSize.height)
                .overlay {
                    PhotoPeriodCoverSurface(asset: day.cover, mode: .months, session: session, motion: motion)
                }
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.28), .clear], startPoint: .top, endPoint: .center)
                }
                .overlay(alignment: .topLeading) {
                    Text(day.date.formatted(.dateTime.day().utc()))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                }
                .clipShape(.rect(cornerRadius: PhotoPeriodCardLayout.cornerRadius))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(daySummary(day))
                .accessibilityIdentifier("photos-period-photo-\(day.id)")
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(daySummary(day))
        // Keep the existing month action reachable for callers of the old ID.
        // Every photo frame and scroll target still has its full stable day ID.
        .accessibilityIdentifier(isFirst ? "photos-period-\(period.id)" : "photos-period-day-\(day.id)")
    }

    private func daySummary(_ day: PhotoMonthDay) -> String {
        "\(PhotoDatePresentation.dateTime(wallClock: day.cover.localDate)), \(String(localized: "\(day.assets.count) items"))"
    }

    private func loadMissingBuckets() async {
        let token = UUID()
        loadingID = token
        defer {
            if loadingID == token {
                loadingID = nil
                if !Task.isCancelled { hasAttemptedLoad = true }
            }
        }
        for id in content.missingBucketIDs {
            guard !Task.isCancelled else { return }
            await model.loadBucket(id)
        }
    }
}
