import Foundation
import AVFoundation
import SwiftUI

/// the trim editor's own player. it loops the kept range and nothing else,
/// apart from the frames a handle drag asks for.
@MainActor @Observable
final class TrimPreviewPlayer {
    let player: AVPlayer
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0

    @ObservationIgnored var range: ClosedRange<Double> = 0...0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init(item: AVPlayerItem) {
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.loop() }
        }
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
            return
        }
        if currentTime < range.lowerBound || currentTime >= range.upperBound - 0.05 {
            seek(to: range.lowerBound)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func stop() {
        pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        if isPlaying, seconds >= range.upperBound { loop() }
    }

    private func loop() {
        guard isPlaying else { return }
        seek(to: range.lowerBound)
        player.play()
    }
}

/// photos' video editor, trimming on gallery and imora through
/// /assets/{id}/trim. times are seconds of the original, so the editor
/// plays the untrimmed file.
struct VideoTrimEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session

    let asset: Asset
    let onFinished: (AssetEditOutcome) -> Void

    private enum LoadState {
        case loading
        case failed(String)
        case tooShort
        case ready
    }

    private enum VideoTab: Hashable {
        case video
    }

    /// the server refuses shorter videos.
    private static let minimumDuration = 2.0
    /// the shortest range the handles leave.
    private static let minimumKept = 1.0
    private static let frameCount = 10

    @State private var loadState = LoadState.loading
    @State private var preview: TrimPreviewPlayer?
    @State private var frames: [UIImage?] = []
    /// the original length the server accepts times within.
    @State private var duration = 0.0
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var initialStart = 0.0
    @State private var initialEnd = 0.0
    @State private var hadTrim = false
    @State private var isSaving = false
    @State private var tab = VideoTab.video
    /// the time the scrubber is being dragged to, for the time code.
    @State private var scrubbedTime: Double?
    @State private var undoStack: [ClosedRange<Double>] = []
    @State private var redoStack: [ClosedRange<Double>] = []
    @State private var editOrigin: ClosedRange<Double>?

    private var hasChanges: Bool { start != initialStart || end != initialEnd }

    /// the whole video is kept, which is no trim at all.
    private var keepsWhole: Bool { start <= 0.01 && end >= duration - 0.01 }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            switch loadState {
            case .loading:
                ProgressView()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Video", systemImage: "exclamationmark.circle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            case .tooShort:
                ContentUnavailableView(
                    "Too Short to Trim",
                    systemImage: "timeline.selection",
                    description: Text("Videos shorter than 2 seconds can't be trimmed.")
                )
            case .ready:
                if let preview {
                    editorBody(preview)
                }
            }

            EditorPrimaryBar(
                hasChanges: hasChanges,
                isSaving: isSaving,
                cancelIdentifier: "trim-cancel",
                doneIdentifier: "trim-done",
                onCancel: { finish(.cancelled) },
                onDone: { Task { await save() } }
            )
        }
        .statusBarHidden()
        .interactiveDismissDisabled(hasChanges || isSaving)
        .task { await load() }
        .onDisappear { preview?.stop() }
    }

    // MARK: - layout

    /// the photo editor's rows: the glass row, the video between it and the
    /// 141pt tool container, whose 51pt scrubber sits where the adjustment
    /// cells do with the time code as the badge above, then the tab capsule.
    private func editorBody(_ preview: TrimPreviewPlayer) -> some View {
        ZStack {
            EditorToolShadow()

            VStack(spacing: 0) {
                secondaryBar

                VideoPlayerSurface(player: preview.player, onReady: {})
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .contentShape(.rect)
                    .onTapGesture { preview.togglePlayPause() }

                HStack(spacing: 8) {
                    Button {
                        preview.togglePlayPause()
                    } label: {
                        Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 21))
                            .frame(width: 40, height: TrimScrubber.handleHeight)
                            .contentShape(.rect)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityLabel(preview.isPlaying ? "Pause" : "Play")

                    TrimScrubber(
                        duration: duration,
                        start: $start,
                        end: $end,
                        currentTime: preview.currentTime,
                        frames: frames,
                        minimumKept: Self.minimumKept,
                        onScrub: { seconds in
                            scrubbedTime = seconds
                            preview.pause()
                            preview.seek(to: seconds)
                        },
                        onEditingChanged: { editing in
                            if editing {
                                editOrigin = start...end
                            } else {
                                scrubbedTime = nil
                                recordEdit()
                            }
                        }
                    )
                }
                .padding(.leading, 8)
                .padding(.trailing, 16)
                .padding(.top, 28)
                .frame(height: 141, alignment: .top)
                .overlay(alignment: .top) {
                    EditorToolLabel(text: Self.timeLabel(scrubbedTime ?? preview.currentTime))
                        .monospacedDigit()
                        .offset(y: -24.33)
                        .opacity(scrubbedTime == nil ? 0 : 1)
                        .animation(PhotosMotion.controls, value: scrubbedTime == nil)
                        .allowsHitTesting(false)
                }

                EditorTabBar(
                    items: [.init(tab: VideoTab.video, title: String(localized: "Video"), systemImage: "video.fill")],
                    selection: $tab
                )
            }
            .padding(.bottom, -4)
            .editorPrimaryBarRoom()
        }
        .allowsHitTesting(!isSaving)
        .onChange(of: start) { preview.range = start...end }
        .onChange(of: end) { preview.range = start...end }
    }

    private var secondaryBar: some View {
        HStack {
            EditorGlassGroup {
                EditorGlassGlyph(systemImage: "arrow.uturn.backward", label: String(localized: "Undo"), isEnabled: !undoStack.isEmpty) {
                    undo()
                }
                EditorGlassGlyph(systemImage: "arrow.uturn.forward", label: String(localized: "Redo"), isEnabled: !redoStack.isEmpty) {
                    redo()
                }
            }

            Spacer()

            EditorGlassGroup {
                Menu {
                    Button("Revert to Original", systemImage: "arrow.uturn.backward.circle") {
                        let before = start...end
                        start = 0
                        end = duration
                        preview?.seek(to: 0)
                        record(from: before)
                    }
                    .disabled(!hadTrim && keepsWhole)
                } label: {
                    EditorGlassGlyphLabel(systemImage: "ellipsis")
                }
                .foregroundStyle(.primary)
                .accessibilityLabel("More")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        // a nav bar title, centred on the screen whatever the groups' widths.
        .overlay { EditorBarTitle(text: String(localized: "Video")) }
    }

    // MARK: - undo

    private func recordEdit() {
        guard let origin = editOrigin else { return }
        editOrigin = nil
        record(from: origin)
    }

    private func record(from origin: ClosedRange<Double>) {
        guard origin != start...end else { return }
        undoStack.append(origin)
        redoStack.removeAll()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(start...end)
        apply(previous)
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(start...end)
        apply(next)
    }

    private func apply(_ range: ClosedRange<Double>) {
        start = range.lowerBound
        end = range.upperBound
        preview?.seek(to: start)
    }

    /// minutes, seconds and tenths, like the web editor.
    private static func timeLabel(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }

    // MARK: - loading and saving

    private func load() async {
        guard let client = session.client else { return }
        loadState = .loading
        do {
            async let detailTask = client.assetDetail(id: asset.id)
            async let trimTask = client.videoTrim(id: asset.id)
            let detail = try await detailTask
            // saving decides between a new trim and removing the old one, so
            // an unreadable trim must not pass for none.
            let trim: VideoTrim?
            do {
                trim = try await trimTask
            } catch {
                loadState = .failed(String(localized: "This video's trim could not be loaded."))
                return
            }

            // a trimmed video plays its trimmed file, while times are in the
            // original, so that one is what plays here.
            let url = trim == nil
                ? client.playbackURL(assetID: asset.id)
                : client.originalURL(assetID: asset.id)
            let localURL = try await client.localMediaFile(url, role: .editInput,
                contentRevision: detail.checksum, requiresElevation: asset.visibility == .locked)
            let urlAsset = try localURL.makeAsset()
            let playable = try await urlAsset.load(.duration).seconds
            // the asset's own duration is the trimmed one once a trim applies.
            let serverDuration = trim?.originalDuration ?? detail.duration.map { Double($0) / 1000 }
            var total = playable.isFinite ? playable : 0
            if let serverDuration, serverDuration > 0 {
                total = total > 0 ? min(total, serverDuration) : serverDuration
            }
            guard total >= Self.minimumDuration else {
                loadState = .tooShort
                return
            }

            duration = total
            start = min(max(0, trim?.startTime ?? 0), total - Self.minimumKept)
            end = min(max(start + Self.minimumKept, trim?.endTime ?? total), total)
            initialStart = start
            initialEnd = end
            hadTrim = trim != nil

            preview?.stop()
            let player = TrimPreviewPlayer(item: AVPlayerItem(asset: urlAsset))
            player.range = start...end
            player.seek(to: start)
            preview = player
            frames = Array(repeating: nil, count: Self.frameCount)
            loadState = .ready
            await loadFrames(urlAsset, duration: total)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    /// evenly spaced frames for the filmstrip, shown as they arrive.
    private func loadFrames(_ urlAsset: AVURLAsset, duration: Double) async {
        let generator = AVAssetImageGenerator(asset: urlAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let step = duration / Double(Self.frameCount)
        let tolerance = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = (0..<Self.frameCount).map {
            CMTime(seconds: (Double($0) + 0.5) * step, preferredTimescale: 600)
        }
        for await result in generator.images(for: times) {
            guard let index = times.firstIndex(of: result.requestedTime),
                  let image = try? result.image,
                  frames.indices.contains(index)
            else { continue }
            frames[index] = UIImage(cgImage: image)
        }
    }

    private func save() async {
        guard !isSaving, hasChanges, let client = session.client else { return }
        if keepsWhole, !hadTrim {
            finish(.cancelled)
            return
        }
        isSaving = true
        let assetID = asset.id
        let realtime = session.realtime
        // the trimmed file is encoded again, which takes longer than a photo.
        let ready = Task {
            _ = await realtime?.waitForAssetEvent(
                named: ["AssetEditReadyV2", "AssetEditReadyV1"],
                assetID: assetID,
                timeout: .seconds(30)
            )
        }
        do {
            if keepsWhole {
                try await client.removeVideoTrim(id: assetID)
            } else {
                try await client.setVideoTrim(
                    id: assetID,
                    start: Self.milliseconds(start),
                    end: Self.milliseconds(end)
                )
            }
        } catch {
            isSaving = false
            ErrorToastCenter.shared.show(String(localized: "Couldn't save the trim"), error: error)
            return
        }
        preview?.stop()
        dismiss()
        let onFinished = onFinished
        Task {
            await ready.value
            // the trimmed duration is only known once the server encoded it.
            let detail = try? await client.assetDetail(id: assetID)
            onFinished(.saved(detail))
        }
    }

    private static func milliseconds(_ seconds: Double) -> Double {
        (seconds * 1000).rounded() / 1000
    }

    private func finish(_ outcome: AssetEditOutcome) {
        preview?.stop()
        onFinished(outcome)
        dismiss()
    }
}

// MARK: - scrubber

/// photos' `PXLivePhotoTrimScrubber` with `PXLivePhotoTrimScrubberSpec`'s
/// metrics: a 41pt filmstrip inset 18pt each side, 18x51 handles reached
/// within 55pt, and a 4pt playhead that becomes a loupe on the frame while
/// it is dragged. a handle held still for half a second zooms the timeline
/// five times around itself, `-[PXLivePhotoTrimScrubber _zoomAtTime:]`.
private struct TrimScrubber: View {
    static let filmstripHeight: CGFloat = 41
    static let handleWidth: CGFloat = 18
    static let handleHeight: CGFloat = 51
    private static let handleReach: CGFloat = 55
    private static let playheadWidth: CGFloat = 4
    private static let loupeInset: CGFloat = 3
    private static let zoomScale = 5.0
    private static let zoomDelay: Duration = .milliseconds(500)

    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    let currentTime: Double
    let frames: [UIImage?]
    let minimumKept: Double
    let onScrub: (Double) -> Void
    let onEditingChanged: (Bool) -> Void

    private enum Grip {
        case start
        case end
        case playhead
    }

    @State private var grip: Grip?
    /// the finger's distance from the gripped handle's edge.
    @State private var grabOffset: CGFloat = 0
    /// the time the zoomed timeline pivots on.
    @State private var zoomPivot: Double?
    @State private var zoomTask: Task<Void, Never>?
    @State private var atBound = false
    @State private var impact = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        GeometryReader { proxy in
            let track = max(proxy.size.width - Self.handleWidth * 2, 1)
            let window = visibleWindow
            let x = { (seconds: Double) in Self.handleWidth + CGFloat((seconds - window.lowerBound) / max(window.upperBound - window.lowerBound, 0.001)) * track }
            let startX = x(start)
            let endX = x(end)
            let isTrimmed = start > 0.01 || end < duration - 0.01
            let tint = isTrimmed || grip == .start || grip == .end ? Color.accentColor : Color.white.opacity(0.9)
            let stripTop = (Self.handleHeight - Self.filmstripHeight) / 2

            ZStack(alignment: .topLeading) {
                filmstrip(track: track, x: x)
                    .frame(width: track, height: Self.filmstripHeight)
                    .clipShape(.rect(cornerRadius: 4))
                    .offset(x: Self.handleWidth, y: stripTop)

                // outside the kept range.
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: max(0, min(startX, Self.handleWidth + track) - Self.handleWidth), height: Self.filmstripHeight)
                    .offset(x: Self.handleWidth, y: stripTop)
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: max(0, Self.handleWidth + track - max(endX, Self.handleWidth)), height: Self.filmstripHeight)
                    .offset(x: max(endX, Self.handleWidth), y: stripTop)

                // the bracket around the kept range.
                VStack(spacing: 0) {
                    Rectangle().frame(height: 3)
                    Spacer(minLength: 0)
                    Rectangle().frame(height: 3)
                }
                .foregroundStyle(tint)
                .frame(width: max(endX - startX, 0), height: Self.handleHeight)
                .offset(x: startX)

                handle(leading: true, tint: tint)
                    .offset(x: startX - Self.handleWidth)
                    .accessibilityLabel("Start")
                    .accessibilityValue(String(format: String(localized: "%.1f seconds"), start))
                    .accessibilityAdjustableAction { direction in
                        let delta = direction == .increment ? 0.5 : -0.5
                        start = min(max(0, start + delta), end - minimumKept)
                    }
                handle(leading: false, tint: tint)
                    .offset(x: endX)
                    .accessibilityLabel("End")
                    .accessibilityValue(String(format: String(localized: "%.1f seconds"), end))
                    .accessibilityAdjustableAction { direction in
                        let delta = direction == .increment ? 0.5 : -0.5
                        end = max(min(duration, end + delta), start + minimumKept)
                    }

                playhead(at: x(min(max(currentTime, start), end)))
            }
            .frame(width: proxy.size.width, height: Self.handleHeight, alignment: .topLeading)
            .contentShape(.rect)
            .gesture(drag(track: track, startX: startX, endX: endX))
        }
        .frame(height: Self.handleHeight)
        .animation(PhotosMotion.layout, value: zoomPivot)
    }

    /// the stretch of the original the track shows: all of it, or a fifth
    /// of it around the pivot, which keeps its place on screen.
    private var visibleWindow: ClosedRange<Double> {
        guard let pivot = zoomPivot, duration > 0 else { return 0...max(duration, 0.001) }
        let span = duration / Self.zoomScale
        let anchor = pivot / duration
        let lower = min(max(0, pivot - anchor * span), duration - span)
        return lower...(lower + span)
    }

    private func time(at x: CGFloat, track: CGFloat) -> Double {
        let window = visibleWindow
        let fraction = Double((x - Self.handleWidth) / track)
        return window.lowerBound + fraction * (window.upperBound - window.lowerBound)
    }

    private func filmstrip(track: CGFloat, x: @escaping (Double) -> CGFloat) -> some View {
        let count = max(frames.count, 1)
        let cell = duration / Double(count)
        return ZStack(alignment: .topLeading) {
            Color.white.opacity(0.08)
            ForEach(frames.indices, id: \.self) { index in
                let left = x(Double(index) * cell) - Self.handleWidth
                let right = x(Double(index + 1) * cell) - Self.handleWidth
                ZStack {
                    if let image = frames[index] {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: max(right - left, 0), height: Self.filmstripHeight)
                .clipped()
                .offset(x: left)
            }
        }
    }

    private func handle(leading: Bool, tint: Color) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: leading ? 6 : 0,
            bottomLeadingRadius: leading ? 6 : 0,
            bottomTrailingRadius: leading ? 0 : 6,
            topTrailingRadius: leading ? 0 : 6
        )
        .fill(tint)
        .overlay {
            Image(systemName: leading ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.black.opacity(0.6))
        }
        .frame(width: Self.handleWidth, height: Self.handleHeight)
    }

    /// a thin bar over the strip, or while dragged a loupe framing the
    /// frame under it, `PXLivePhotoTrimScrubberLoupeView`.
    @ViewBuilder private func playhead(at position: CGFloat) -> some View {
        if grip == .playhead {
            let height = Self.filmstripHeight + Self.loupeInset * 2
            let width = height * 0.75
            ZStack {
                if let image = frame(at: currentTime) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width - Self.loupeInset * 2, height: height - Self.loupeInset * 2)
                        .clipShape(.rect(cornerRadius: 2))
                }
                // `photoEditingTrimPlayheadLineColor` is the label colour.
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.primary, lineWidth: Self.loupeInset)
            }
            .frame(width: width, height: height)
            .offset(x: position - width / 2, y: (Self.handleHeight - height) / 2)
            .allowsHitTesting(false)
        } else if grip != .start, grip != .end {
            Capsule()
                .fill(Color.primary)
                .frame(width: Self.playheadWidth, height: Self.handleHeight)
                .offset(x: position - Self.playheadWidth / 2)
                .allowsHitTesting(false)
        }
    }

    private func frame(at seconds: Double) -> UIImage? {
        guard !frames.isEmpty, duration > 0 else { return nil }
        let index = min(frames.count - 1, max(0, Int(seconds / duration * Double(frames.count))))
        return frames[index]
    }

    /// the nearest handle within reach moves, anywhere else drags the
    /// playhead between them.
    private func drag(track: CGFloat, startX: CGFloat, endX: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if grip == nil {
                    let x = value.startLocation.x
                    let toStart = abs(x - (startX - Self.handleWidth / 2))
                    let toEnd = abs(x - (endX + Self.handleWidth / 2))
                    if min(toStart, toEnd) < Self.handleReach / 2 {
                        grip = toStart <= toEnd ? .start : .end
                        grabOffset = x - (grip == .start ? startX : endX)
                    } else {
                        grip = .playhead
                    }
                    atBound = false
                    impact.prepare()
                    onEditingChanged(true)
                }
                switch grip {
                case .start:
                    let wanted = time(at: value.location.x - grabOffset, track: track)
                    start = min(max(0, wanted), end - minimumKept)
                    bump(wanted != start)
                    onScrub(start)
                    scheduleZoom(at: start)
                case .end:
                    let wanted = time(at: value.location.x - grabOffset, track: track)
                    end = max(min(duration, wanted), start + minimumKept)
                    bump(wanted != end)
                    onScrub(end)
                    scheduleZoom(at: end)
                case .playhead, nil:
                    onScrub(min(max(time(at: value.location.x, track: track), start), end))
                }
            }
            .onEnded { _ in
                zoomTask?.cancel()
                zoomTask = nil
                zoomPivot = nil
                if grip == .start || grip == .end { onScrub(start) }
                grip = nil
                onEditingChanged(false)
            }
    }

    /// a handle reaching the end of the video or the shortest range
    /// knocks once, `_trimHandleDidReachBounds`.
    private func bump(_ clamped: Bool) {
        if clamped, !atBound { impact.impactOccurred() }
        atBound = clamped
    }

    /// any movement restarts the half second a held handle waits to zoom.
    private func scheduleZoom(at seconds: Double) {
        guard zoomPivot == nil else { return }
        zoomTask?.cancel()
        zoomTask = Task {
            try? await Task.sleep(for: Self.zoomDelay)
            guard !Task.isCancelled, grip == .start || grip == .end else { return }
            zoomPivot = seconds
            impact.impactOccurred()
        }
    }
}
