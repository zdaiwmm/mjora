import SwiftUI

struct PhotoPeriodsView: View {
    @Environment(SessionStore.self) private var session
    let model: TimelineModel
    @Bindable var controls: PhotosGridControls
    let motion: PhotoPeriodMotion

    private var periods: [PhotoPeriod] {
        controls.mode == .years ? PhotoPeriod.years(in: model.sections, preferredAssetID: controls.periodAnchor?.asset.id)
            : PhotoPeriod.months(in: model.sections, year: controls.selectedYear, preferredAssetID: controls.periodAnchor?.asset.id)
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if controls.mode == .months, controls.selectedYear != nil {
                    Button {
                        controls.selectedYear = nil
                        controls.mode = .years
                    } label: { Label("All Years", systemImage: "chevron.left") }
                    .padding(.vertical, 4)
                }
                ForEach(periods) { period in
                    Button {
                            if let asset = period.cover {
                                let restoredOffset = controls.periodAnchor?.asset.id == asset.id ? controls.periodAnchor?.scrollOffset : nil
                                controls.periodAnchor = PhotoPeriodAnchor(asset: asset, bucketID: period.representativeBucketID,
                                                                         scrollOffset: restoredOffset)
                            }
                            if controls.mode == .years {
                                controls.selectedYear = period.year
                                controls.mode = .months
                            } else {
                                controls.reveal(bucketID: period.representativeBucketID, assetID: period.cover?.id)
                            }
                    } label: { periodCard(period) }
                    .buttonStyle(.plain)
                    .id(period.id)
                    .accessibilityIdentifier("photos-period-\(period.id)")
                    .task(id: period.id) {
                        if period.cover == nil { await model.loadBucket(period.representativeBucketID) }
                    }
                }
                if periods.isEmpty {
                    ContentUnavailableView("No photos yet", systemImage: "photo.on.rectangle")
                }
            }
            .id(controls.mode)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 90)
        }
        .background(Color(.systemBackground))
        .accessibilityIdentifier("photos-periods")
        .onScrollPhaseChange { _, phase in
            if phase == .tracking || phase == .interacting || phase == .decelerating { motion.cancel() }
        }
        .onChange(of: controls.mode, initial: true) { _, _ in
            if let id = periods.first(where: { $0.cover?.id == controls.periodAnchor?.asset.id })?.id {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        }
    }

    private func periodCard(_ period: PhotoPeriod) -> some View {
        Color(.secondarySystemBackground)
            .frame(height: controls.mode == .years ? 224 : 184)
            .overlay {
                if let asset = period.cover {
                    PhotoPeriodCoverSurface(asset: asset, mode: controls.mode, session: session, motion: motion)
                }
            }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(period.title).font(.largeTitle.bold())
                    Text("\(period.count) items").font(.subheadline)
                }
                .foregroundStyle(.white)
                .padding(20)
            }
            .clipShape(.rect(cornerRadius: 26))
            .accessibilityElement(children: .combine)
    }
}
