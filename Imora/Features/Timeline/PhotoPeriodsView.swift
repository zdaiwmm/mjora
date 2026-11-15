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
                            VStack(alignment: .leading, spacing: PhotoPeriodCardLayout.monthHeadingGap) {
                                if controls.mode == .months {
                                    Text(period.title)
                                        .font(.title2.bold())
                                        .foregroundStyle(.primary)
                                        .frame(width: layout.photoSize.width, alignment: .leading)
                                        .accessibilityAddTraits(.isHeader)
                                        .accessibilityIdentifier("photos-period-heading-\(period.id)")
                                }
                                periodButton(period, layout: layout)
                            }
                            .id(period.id)
                            .task(id: period.id) {
                                if period.cover == nil { await model.loadBucket(period.representativeBucketID) }
                            }
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
                    if phase == .tracking || phase == .interacting || phase == .decelerating { motion.cancel() }
                }
                .onChange(of: controls.mode, initial: true) { _, _ in restoreAnchor(using: proxy) }
                .onChange(of: controls.selectedYear) { _, _ in restoreAnchor(using: proxy) }
            }
        }
    }

    private func restoreAnchor(using proxy: ScrollViewProxy) {
        if let id = periods.first(where: { $0.cover?.id == controls.periodAnchor?.asset.id })?.id {
            proxy.scrollTo(id, anchor: .center)
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
