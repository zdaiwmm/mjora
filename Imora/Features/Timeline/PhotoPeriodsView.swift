import SwiftUI

struct PhotoPeriodsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(SessionStore.self) private var session
    let model: TimelineModel
    @Bindable var controls: PhotosGridControls

    private var periods: [PhotoPeriod] {
        controls.mode == .years ? PhotoPeriod.years(in: model.sections)
            : PhotoPeriod.months(in: model.sections, year: controls.selectedYear)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if controls.mode == .months, controls.selectedYear != nil {
                    Button {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
                            controls.selectedYear = nil
                            controls.mode = .years
                        }
                    } label: { Label("All Years", systemImage: "chevron.left") }
                    .padding(.vertical, 4)
                }
                ForEach(periods) { period in
                    Button {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
                            if controls.mode == .years {
                                controls.selectedYear = period.year
                                controls.mode = .months
                            } else {
                                controls.reveal(bucketID: period.representativeBucketID)
                            }
                        }
                    } label: { periodCard(period) }
                    .buttonStyle(.plain)
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
            .transition(.opacity)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 90)
        }
        .background(Color(.systemBackground))
        .accessibilityIdentifier("photos-periods")
    }

    private func periodCard(_ period: PhotoPeriod) -> some View {
        Color(.secondarySystemBackground)
            .frame(height: 224)
            .overlay {
                if let asset = period.cover {
                    if let localID = asset.localIdentifier {
                        PhotoPeriodDeviceCover(localIdentifier: localID)
                    } else if let client = session.client {
                        RemoteImage(url: client.thumbnailURL(assetID: asset.id, size: "preview"),
                                    targetPixelSize: 900, thumbhash: asset.thumbhash)
                    }
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

private struct PhotoPeriodDeviceCover: View {
    let localIdentifier: String
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height).clipped()
            }
        }
        .task(id: localIdentifier) {
            image = await LocalImageLoader.shared.image(localIdentifier: localIdentifier, targetPixelSize: 900)
        }
    }
}
