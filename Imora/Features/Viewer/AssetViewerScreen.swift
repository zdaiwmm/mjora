import Foundation
import SwiftUI
import AVKit
import Photos

nonisolated enum AssetChange {
    case favorite(String, Bool)
    case favoriteCommitted(String, Bool)
    case optimisticRemoval(String)
    case removalCommitted(String)
    case removalReverted(String)
    case albumMembershipProjected(String)
    case albumMembershipCommitted(String)
    case albumMembershipReverted(String)
    case removed(String)
    /// deleted from the device only - the server copy remains, so grids keep it.
    case localDeleted(String)
    /// pixels changed server side; the new thumbhash cache-busts stale thumbs.
    /// a trimmed video also carries its new duration.
    case edited(String, thumbhash: String?, duration: Int? = nil)
}

private struct ViewerRemoval {
    let asset: Asset
    let index: Int
}

/// full-bleed screen size plus the ignored bottom inset, mirrored into state
/// so gestures and the information panel share the media stage's numbers.
private nonisolated struct ViewerViewport: Equatable, Sendable {
    var size = CGSize.zero
    var bottomInset: CGFloat = 0
}

private struct ViewerPhysicalSafeAreaReader: UIViewRepresentable {
    let onChange: (UIEdgeInsets) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.reportIfNeeded()
    }

    final class ReaderView: UIView {
        var onChange: ((UIEdgeInsets) -> Void)?
        private var lastInsets: UIEdgeInsets?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportIfNeeded()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            reportIfNeeded()
        }

        func reportIfNeeded() {
            guard let window else { return }
            let insets = window.safeAreaInsets
            guard insets != lastInsets else { return }
            lastInsets = insets
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(insets)
            }
        }
    }
}

private struct AssetViewerMediaFrameAnchor: UIViewRepresentable {
    let assetID: String
    let aspectRatio: Double
    let onRegistrationChanged: (String, UIView, Double, Bool) -> Void

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        view.update(
            assetID: assetID,
            aspectRatio: aspectRatio,
            onRegistrationChanged: onRegistrationChanged
        )
    }

    static func dismantleUIView(_ view: AnchorView, coordinator: ()) {
        view.unregister()
    }

    final class AnchorView: UIView {
        private var assetID = ""
        private var aspectRatio = 1.0
        private var onRegistrationChanged: ((String, UIView, Double, Bool) -> Void)?
        private var isRegistered = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            window == nil ? unregister() : register()
        }

        func update(
            assetID: String,
            aspectRatio: Double,
            onRegistrationChanged: @escaping (String, UIView, Double, Bool) -> Void
        ) {
            let identityChanged = self.assetID != assetID
            if identityChanged { unregister() }
            self.assetID = assetID
            self.aspectRatio = aspectRatio
            self.onRegistrationChanged = onRegistrationChanged
            guard window != nil else { return }
            register()
        }

        func unregister() {
            guard isRegistered else { return }
            isRegistered = false
            onRegistrationChanged?(assetID, self, aspectRatio, false)
        }

        private func register() {
            guard !assetID.isEmpty else { return }
            isRegistered = true
            onRegistrationChanged?(assetID, self, aspectRatio, true)
        }
    }
}

/// Coarse scroll regions are the only vertical state published into SwiftUI.
/// The fitted asset itself follows native scroll geometry in a visual effect,
/// so scrolling never invalidates the viewer hierarchy once per pixel.
private enum AssetViewerScrollEndpoint: Equatable {
    case media
    case transition
    case information
}

/// the live offset and the endpoint a release resolved to. a reference box
/// written every scroll frame without invalidating any view, and read by the
/// target behavior, which only ever sees the projected landing.
/// both sides run on the main thread: scroll geometry callbacks and the
/// target behavior, which SwiftUI calls from the scroll view's release.
private nonisolated final class AssetInformationScrollTracker: @unchecked Sendable {
    var offset: CGFloat = 0
    /// where the finger's current drag began, so its release is resolved
    /// against the endpoint it left. kept here rather than in view state: a
    /// fast fling releases before the body runs again.
    var dragStartOffset: CGFloat = 0
    /// armed while a finger drags. swiftui also asks the target behavior
    /// during the viewer's own scroll animations, which must pass untouched,
    /// so only the first ask after a drag is a release.
    var awaitsRelease = false
    /// set by the target behavior when a release resolves to an endpoint,
    /// consumed by the phase handler, which springs there. points per second.
    var pendingRelease: (target: CGFloat, velocity: CGFloat, bouncesAtEdge: Bool)?
    /// the drag belongs to the information's own scroll view rather than
    /// photos' open and close pan.
    var scrollsInformation = false
    /// the drag's last direction, fed its distance from the start.
    var direction = ChangeDirectionFilter()
}

/// `PUChangeDirectionValueFilter`. a direction is only read past 5 points,
/// and only flips once the value comes back more than 5 points from its
/// furthest point. 1 is a growing value.
nonisolated struct ChangeDirectionFilter {
    private static let minimumChange: CGFloat = 5
    private(set) var output = 0
    private var pivot: CGFloat = 0

    mutating func input(_ value: CGFloat) {
        let grows: Bool
        switch output {
        case 0:
            guard abs(value) > Self.minimumChange else { return }
            grows = value >= 0
        case 1...:
            grows = value >= pivot
        default:
            grows = value > pivot
        }
        if grows {
            pivot = max(pivot, value - Self.minimumChange)
            output = 1
        } else {
            pivot = min(pivot, value + Self.minimumChange)
            output = -1
        }
    }
}

/// decides where a released drag rests. a release that resolves to the media
/// or the information stop is frozen where the finger lifted, and the phase
/// handler springs it there from the finger's speed, as photos does: native
/// deceleration crawls its last pixels for over a second. deeper metadata
/// reading keeps the native free scroll.
private nonisolated struct AssetInformationScrollTargetBehavior: ScrollTargetBehavior {
    let restingMediaFrame: CGRect?
    let tracker: AssetInformationScrollTracker

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard tracker.awaitsRelease else { return }
        tracker.awaitsRelease = false
        // the context reports points per millisecond.
        let velocity = context.velocity.dy * 1000
        let layout = AssetViewerPageLayout(
            viewport: context.containerSize,
            restingMediaFrame: restingMediaFrame
        )
        let maximumOffset = max(0, context.contentSize.height - context.containerSize.height)
        // photos' information scroll view: free reading, except that it
        // stops and bounces at its own top, the information stop.
        if tracker.scrollsInformation {
            let edge = layout.informationRevealOffset
            guard target.rect.minY < edge || tracker.offset < edge else {
                tracker.pendingRelease = nil
                return
            }
            tracker.pendingRelease = (edge, velocity, true)
            target.rect.origin.y = min(maximumOffset, max(0, tracker.offset))
            return
        }
        let landing = layout.landingOffset(
            direction: tracker.direction.output,
            offset: tracker.offset,
            velocity: velocity
        )
        if abs(landing - tracker.offset) > AssetViewerPageLayout.scrollCommandTolerance {
            tracker.pendingRelease = (min(maximumOffset, landing), velocity, false)
            target.rect.origin.y = min(maximumOffset, max(0, tracker.offset))
            return
        }
        tracker.pendingRelease = nil
        target.rect.origin.y = min(maximumOffset, landing)
    }
}

nonisolated enum AssetViewerScrollContent {
    static let space = "asset-viewer-scroll-content"
}

/// everything a page needs to place its media for a scroll sample, kept
/// sendable so the compositor can evaluate it every frame.
private nonisolated struct AssetViewerMediaScrollParameters: Sendable {
    let followsCompactScroll: Bool
    let aspectRatio: Double
    let showsChrome: Bool
    let topSafeAreaInset: CGFloat
    let bottomSafeAreaInset: CGFloat
    let isScreenCapture: Bool
    let bestSquareCenter: CGPoint
    let informationFloor: CGFloat

    /// the scroll offset is read against the scroll view and the content: a
    /// stage pinned beside the information moves its pages back down by the
    /// same amount in both, and only the difference is the scroll.
    func geometry(size: CGSize, frameInScroll: CGRect, frameInContent: CGRect) -> AssetViewerMediaGeometry {
        let scrolled = followsCompactScroll ? frameInContent.minY - frameInScroll.minY : 0
        let scrollOffset = informationFloor > 0 ? max(informationFloor, scrolled) : scrolled
        let plain = AssetViewerPageLayout(viewport: size)
        let resting = plain.presentationMediaFrame(
            aspectRatio: aspectRatio,
            showsChrome: showsChrome,
            topSafeAreaInset: topSafeAreaInset,
            bottomSafeAreaInset: bottomSafeAreaInset,
            isScreenCapture: isScreenCapture
        )
        let topGuide = max(0, topSafeAreaInset)
            + (showsChrome ? AssetViewerPageLayout.topChromeReservation : 0)
        return AssetViewerPageLayout(viewport: size, restingMediaFrame: resting)
            .mediaGeometry(
                scrollOffset: scrollOffset,
                aspectRatio: aspectRatio,
                restingFrame: resting,
                bestSquareCenter: bestSquareCenter,
                topGuide: topGuide
            )
    }
}

/// Moves fitted media through photos' transition into the square above the
/// information. The compositor reads the live frame directly, avoiding a
/// one-frame @State lag and leaving the scroll view's layout untouched. Pages
/// also clip to the media frame, which `.clipped()` used to do at rest.
private struct AssetViewerMediaScrollEffect: ViewModifier {
    let followsCompactScroll: Bool
    let aspectRatio: Double
    let showsChrome: Bool
    let topSafeAreaInset: CGFloat
    let bottomSafeAreaInset: CGFloat
    let isScreenCapture: Bool
    var bestSquareCenter = CGPoint(x: 0.5, y: 0.5)
    var clipsToMediaFrame = false
    /// photos' inset styling: off while the information shows.
    var stylesInset = false
    @Environment(\.assetViewerInformationFloor) private var informationFloor

    private var parameters: AssetViewerMediaScrollParameters {
        AssetViewerMediaScrollParameters(
            followsCompactScroll: followsCompactScroll,
            aspectRatio: aspectRatio,
            showsChrome: showsChrome,
            topSafeAreaInset: topSafeAreaInset,
            bottomSafeAreaInset: bottomSafeAreaInset,
            isScreenCapture: isScreenCapture,
            bestSquareCenter: bestSquareCenter,
            informationFloor: informationFloor
        )
    }

    /// `PXLemonadeOneUpSettings`: a 1 point border, white at 10% in dark
    /// mode, which the viewer always is.
    private static let hairlineOpacity = 0.1

    /// the unscaled media's rounded frame. the page scales it uniformly to
    /// its resting place, so radius and border are divided by that scale.
    private func insetStyle(in size: CGSize) -> (frame: CGRect, cornerRadius: CGFloat, hairline: CGFloat)? {
        guard stylesInset, isScreenCapture, showsChrome, size.width > 0, size.height > 0 else { return nil }
        let layout = AssetViewerPageLayout(viewport: size)
        let full = layout.fittedMediaFrame(aspectRatio: aspectRatio)
        let resting = layout.presentationMediaFrame(
            aspectRatio: aspectRatio,
            showsChrome: showsChrome,
            topSafeAreaInset: topSafeAreaInset,
            bottomSafeAreaInset: bottomSafeAreaInset,
            isScreenCapture: isScreenCapture
        )
        guard full.width > 0, layout.insetsMediaFrame(resting) else { return nil }
        let scale = resting.width / full.width
        return (full, layout.screenCaptureCornerRadius(aspectRatio: aspectRatio) / scale, 1 / scale)
    }

    @ViewBuilder func body(content: Content) -> some View {
        let parameters = parameters
        let moved = content
            .mask {
                GeometryReader { proxy in
                    let inset = insetStyle(in: proxy.size)
                    RoundedRectangle(cornerRadius: inset?.cornerRadius ?? 0, style: .continuous)
                        .frame(width: inset?.frame.width ?? proxy.size.width, height: inset?.frame.height ?? proxy.size.height)
                        .position(x: inset?.frame.midX ?? proxy.size.width / 2, y: inset?.frame.midY ?? proxy.size.height / 2)
                }
            }
            .overlay {
                GeometryReader { proxy in
                    let inset = insetStyle(in: proxy.size)
                    RoundedRectangle(cornerRadius: inset?.cornerRadius ?? 0, style: .continuous)
                        .strokeBorder(.white.opacity(Self.hairlineOpacity), lineWidth: inset?.hairline ?? 1)
                        .frame(width: inset?.frame.width ?? proxy.size.width, height: inset?.frame.height ?? proxy.size.height)
                        .position(x: inset?.frame.midX ?? proxy.size.width / 2, y: inset?.frame.midY ?? proxy.size.height / 2)
                        .opacity(inset == nil ? 0 : 1)
                }
                .allowsHitTesting(false)
            }
            .visualEffect { effect, proxy in
            let geometry = parameters.geometry(
                size: proxy.size,
                frameInScroll: proxy.frame(in: .scrollView(axis: .vertical)),
                frameInContent: proxy.frame(in: .named(AssetViewerScrollContent.space))
            )
            return effect
                .scaleEffect(geometry.scale, anchor: .center)
                .offset(geometry.offset)
        }
        if clipsToMediaFrame {
            moved.mask {
                Rectangle().visualEffect { effect, proxy in
                    let size = proxy.size
                    let window = parameters.geometry(
                        size: size,
                        frameInScroll: proxy.frame(in: .scrollView(axis: .vertical)),
                        frameInContent: proxy.frame(in: .named(AssetViewerScrollContent.space))
                    ).window ?? CGRect(origin: .zero, size: size)
                    return effect
                        .scaleEffect(
                            x: size.width > 0 ? window.width / size.width : 1,
                            y: size.height > 0 ? window.height / size.height : 1,
                            anchor: .topLeading
                        )
                        .offset(x: window.minX, y: window.minY)
                }
            }
        } else {
            moved
        }
    }
}

/// photos fades the information with the media's own layout progress, so a
/// drag fades it under the finger, and slides it in from below its resting
/// place on the toggle spring whenever it becomes visible.
private struct AssetInformationEntranceEffect: ViewModifier {
    let informationTop: CGFloat
    let revealOffset: CGFloat
    /// below it the information overscrolls on its own, as photos' inner
    /// information scroll view does past its top.
    let floor: CGFloat
    /// nonzero while a finger drags it past the floor.
    let rubberBandRange: CGFloat
    let appearanceOffset: CGFloat

    func body(content: Content) -> some View {
        content.visualEffect { [informationTop, revealOffset, floor, rubberBandRange, appearanceOffset] effect, proxy in
            let scrollOffset = informationTop - proxy.frame(in: .scrollView(axis: .vertical)).minY
            let overscroll = floor > 0 ? max(0, floor - scrollOffset) : 0
            let resisted = rubberBandRange > 0
                ? ScrollEdgePhysics.rubberBand(overscroll, range: rubberBandRange)
                : overscroll
            let progress = revealOffset > 0
                ? min(1, max(0, (scrollOffset + overscroll) / revealOffset))
                : 1
            return effect
                .opacity(progress)
                .offset(y: appearanceOffset + resisted - overscroll)
        }
    }
}

/// uikit's scroll physics, read from UIKitCore. offsets in points, time in
/// milliseconds, velocity in points per millisecond.
nonisolated enum ScrollEdgePhysics {
    /// `UIScrollViewDecelerationRateNormal`.
    static let decelerationFactor = 0.998
    /// the pull back toward an edge in `_getBouncingDecelerationOffset`.
    static let bounceExponent = -0.01005
    /// `_UIScrollViewRubberBandCoefficient`'s default.
    static let rubberBandCoefficient = 0.55

    /// `_UIScrollViewRubberBandOffsetWithoutDecorationForOffset`, with the
    /// scroll view's height as its range.
    static func rubberBand(_ overscroll: CGFloat, range: CGFloat) -> CGFloat {
        guard overscroll > 0, range > 0 else { return overscroll }
        return range * (1 - 1 / (overscroll * rubberBandCoefficient / range + 1))
    }
}

/// a curve the motion driver plays on the scroll view, time in
/// milliseconds. a sample is the offset and whether it has come to rest.
nonisolated protocol ScrollMotion {
    var start: Double { get }
    var rest: Double { get }
    func sample(at t: Double) -> (Double, Bool)
}

/// a released open or close pan, from `PUAccessoryVisibilityInteractionController`.
/// its overriding offset springs to the endpoint with the finger's speed
/// while its override factor springs from 1 to 0, both on `PXNumberAnimator`'s
/// default spring, stiffness 300 at critical damping. `PUAssetViewModel`
/// shows their blend, so the distance left is the two springs' product,
/// which overshoots about half as far as the finger's spring alone.
nonisolated struct AccessoryReleaseSpring: ScrollMotion {
    let start: Double
    let rest: Double
    /// points per millisecond.
    let velocity: Double

    private static let omega = 300.0.squareRoot() / 1000

    func sample(at t: Double) -> (Double, Bool) {
        let distance = distanceLeft(at: t)
        let speed = abs(distanceLeft(at: t + 1) - distance)
        return (rest + distance, abs(distance) < 0.1 && speed < 0.01)
    }

    private func distanceLeft(at t: Double) -> Double {
        let omega = Self.omega
        let from = start - rest
        let decay = exp(-omega * t)
        let spring = (from + (velocity + omega * from) * t) * decay
        let factor = (1 + omega * t) * decay
        return spring * factor
    }
}

/// uikit's deceleration toward a scroll edge and its bounce off it, from
/// `_getStandardDecelerationOffset` and `_getBouncingDecelerationOffset`.
/// inside the edge an offset decays as v F (1 - F^t) / (1 - F). past it,
/// the same decay is pulled back by e^(k t).
nonisolated struct ScrollEdgeBounce: ScrollMotion {
    let start: Double
    let edge: Double
    let velocity: Double

    var rest: Double { edge }

    /// the offset at t, and whether the bounce has come to rest.
    func sample(at t: Double) -> (Double, Bool) {
        let factor = ScrollEdgePhysics.decelerationFactor
        let reach = factor / (1 - factor)
        var inside = start - edge
        var speed = velocity
        var elapsed = t
        // decelerates freely until it reaches the edge, if it does.
        if inside > 0 {
            let toEdge = speed < 0 ? 1 + inside / (speed * reach) : 0
            guard toEdge > 0 else {
                let offset = start + speed * reach * (1 - pow(factor, t))
                return (offset, abs(speed * pow(factor, t)) < 0.001)
            }
            let crossing = log(toEdge) / log(factor)
            guard t > crossing else {
                return (start + speed * reach * (1 - pow(factor, t)), false)
            }
            speed *= pow(factor, crossing)
            inside = 0
            elapsed = t - crossing
        }
        let pull = exp(ScrollEdgePhysics.bounceExponent * elapsed)
        let past = pull * (inside + speed * reach * (1 - pow(factor, elapsed)))
        let next = exp(ScrollEdgePhysics.bounceExponent * (elapsed + 1))
            * (inside + speed * reach * (1 - pow(factor, elapsed + 1)))
        return (edge + past, abs(past) < 0.25 && abs(next) <= abs(past))
    }
}

/// plays a motion on the scroll view itself, frame by frame, as uikit plays
/// its own deceleration. swiftui's scroll animations only take its springs.
@MainActor
private final class ScrollMotionDriver {
    weak var scrollView: UIScrollView?
    private var link: CADisplayLink?
    private var motion: (any ScrollMotion)?
    private var startTime: CFTimeInterval = 0
    private var completion: ((Bool) -> Void)?

    var isRunning: Bool { link != nil }

    func run(_ motion: any ScrollMotion, completion: @escaping (Bool) -> Void) {
        stop(finished: false)
        guard let scrollView else { return completion(false) }
        // ends uikit's own deceleration toward the frozen release target.
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: motion.start),
            animated: false
        )
        self.motion = motion
        self.completion = completion
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop(finished: Bool) {
        link?.invalidate()
        link = nil
        motion = nil
        let completion = completion
        self.completion = nil
        completion?(finished)
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let scrollView, let motion else { return stop(finished: false) }
        // a finger catching the motion takes the scroll back.
        guard !scrollView.isTracking else { return stop(finished: false) }
        let (offset, finished) = motion.sample(at: (link.targetTimestamp - startTime) * 1000)
        scrollView.contentOffset.y = finished ? motion.rest : offset
        if finished { stop(finished: true) }
    }
}

/// hands the scroll view behind a swiftui `ScrollView` to the motion driver,
/// and its pan to `onPan`.
private struct ScrollViewLocator: UIViewRepresentable {
    let driver: ScrollMotionDriver
    let onPan: (UIPanGestureRecognizer) -> Void

    final class PanRelay: NSObject {
        var onPan: ((UIPanGestureRecognizer) -> Void)?

        @objc func relay(_ pan: UIPanGestureRecognizer) {
            onPan?(pan)
        }
    }

    func makeCoordinator() -> PanRelay {
        PanRelay()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let relay = context.coordinator
        relay.onPan = onPan
        guard driver.scrollView == nil else { return }
        DispatchQueue.main.async {
            var ancestor = view.superview
            while let candidate = ancestor, !(candidate is UIScrollView) {
                ancestor = candidate.superview
            }
            guard let scrollView = ancestor as? UIScrollView, driver.scrollView == nil else { return }
            driver.scrollView = scrollView
            scrollView.panGestureRecognizer.addTarget(relay, action: #selector(PanRelay.relay(_:)))
        }
    }
}

private struct AssetViewerInformationFloorKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// the information stop while a drag that began inside the information
    /// overscrolls it. the media holds its square there.
    var assetViewerInformationFloor: CGFloat {
        get { self[AssetViewerInformationFloorKey.self] }
        set { self[AssetViewerInformationFloorKey.self] = newValue }
    }
}

/// the album a grid belongs to, when it belongs to one. carries the owner so
/// the viewer can offer removal to the same people the server accepts it from.
nonisolated struct AlbumContext: Equatable {
    let id: String
    let ownerID: String?
    /// shared albums, whose photos take comments and likes.
    var activity: AlbumActivityScope? = nil
}

/// destructive flows that need a confirmation dialog before running.
private enum ViewerConfirmation: Identifiable {
    case trash
    case deletePermanently
    case deleteFromDevice
    case moveToLocked
    case removeFromLocked

    var id: Int {
        switch self {
        case .trash: 0
        case .deletePermanently: 1
        case .deleteFromDevice: 2
        case .moveToLocked: 3
        case .removeFromLocked: 4
        }
    }
}

/// ios 26 morphs a confirmation dialog out of the control that presented it, so
/// the modifier has to live on that control - on the screen root it anchors to
/// the whole window and the dialog floats in the middle pointing at nothing.
/// every trigger tags its source and only the matching attachment presents.
private enum ViewerConfirmationSource {
    case toolbar
    case menu
}

/// Destinations selected from information are pushed by the viewer after the
/// sheet has fully dismissed, so they use the full screen and native back
/// navigation instead of replacing the sheet's contents.
private enum AssetInformationDestination: Hashable {
    case person(Person)
    case album(Album)
}

/// shared body for the viewer's per-source confirmation attachments.
private struct ViewerConfirmationDialog<Actions: View>: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: $isPresented,
            titleVisibility: .visible,
            actions: actions,
            message: { Text(message) }
        )
    }
}

/// Owns the viewer's nonmodal information surface and any presentation that
/// originates inside it. Keeping the album picker on this sheet avoids asking
/// the underlying viewer controller to present through an existing sheet.
/// used on regular width only, where the sheet floats over unchanged media.
private struct AssetInformationSheet: View {
    private static let detent = PresentationDetent.fraction(
        AssetViewerPageLayout.informationSheetFraction
    )

    let asset: Asset
    let serverAssetID: String?
    let onDateAdjusted: (String, Date, Double) -> Void
    let onAlbumAdded: (String) -> Void
    let onOpenPerson: (Person) -> Void
    let onOpenAlbum: (Album) -> Void

    @State private var showAddToAlbum = false
    @State private var albumMembershipUpdate: AlbumMembershipUpdate?

    var body: some View {
        ScrollView {
            AssetInfoPanel(
                asset: asset,
                onDateAdjusted: onDateAdjusted,
                onAddToAlbum: (serverAssetID == nil && !asset.isLocal) || asset.visibility == .locked ? nil : { showAddToAlbum = true },
                onOpenPerson: onOpenPerson,
                onOpenAlbum: onOpenAlbum,
                albumMembershipUpdate: albumMembershipUpdate
            )
        }
        .scrollDismissesKeyboard(.interactively)
        // information continues the viewer's black stage, so the sheet is
        // pure black with dark-resolved content in either system appearance.
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .presentationDetents([Self.detent])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.black)
        .presentationBackgroundInteraction(.enabled(upThrough: Self.detent))
        .tint(.accentColor)
        .sheet(isPresented: $showAddToAlbum) {
            if serverAssetID != nil || asset.isLocal {
                AddToAlbumSheet(
                    assetIDs: serverAssetID.map { [$0] } ?? [],
                    localIdentifiers: serverAssetID == nil ? asset.localIdentifier.map { [$0] } ?? [] : [],
                    onMembershipUpdate: { update in
                        albumMembershipUpdate = AlbumMembershipUpdate(
                            operationID: update.operationID,
                            assetID: asset.id,
                            change: update.change
                        )
                    },
                    onDone: onAlbumAdded
                )
            }
        }
    }
}

/// Owns presentations launched from compact-width information. Its content is
/// part of the viewer's one vertical scroll view; there is intentionally no
/// nested scroll view or independently moving sheet here.
private struct AssetInformationPanel: View {
    let asset: Asset
    let serverAssetID: String?
    let isRevealed: Bool
    let bottomContentInset: CGFloat
    let onDateAdjusted: (String, Date, Double) -> Void
    let onAlbumAdded: (String) -> Void
    let onOpenPerson: (Person) -> Void
    let onOpenAlbum: (Album) -> Void

    @State private var showAddToAlbum = false
    @State private var albumMembershipUpdate: AlbumMembershipUpdate?

    var body: some View {
        AssetInfoPanel(
            asset: asset,
            showsHeader: false,
            isRevealed: isRevealed,
            onDateAdjusted: onDateAdjusted,
            onAddToAlbum: (serverAssetID == nil && !asset.isLocal) || asset.visibility == .locked ? nil : { showAddToAlbum = true },
            onOpenPerson: onOpenPerson,
            onOpenAlbum: onOpenAlbum,
            albumMembershipUpdate: albumMembershipUpdate
        )
        .padding(.bottom, bottomContentInset)
        .tint(.accentColor)
        .sheet(isPresented: $showAddToAlbum) {
            if serverAssetID != nil || asset.isLocal {
                AddToAlbumSheet(
                    assetIDs: serverAssetID.map { [$0] } ?? [],
                    localIdentifiers: serverAssetID == nil ? asset.localIdentifier.map { [$0] } ?? [] : [],
                    onMembershipUpdate: { update in
                        albumMembershipUpdate = AlbumMembershipUpdate(
                            operationID: update.operationID,
                            assetID: asset.id,
                            change: update.change
                        )
                    },
                    onDone: onAlbumAdded
                )
                // the viewer root tints primary; this modal wants the accent.
                .tint(.accentColor)
            }
        }
    }
}

/// pixels a page asks for. every warm-up has to name the same size to land on
/// the request the page will make, so it lives next to both.
let pagePixelSize: CGFloat = 2048

struct AssetViewerFittedMedia<Content: View>: View {
    let aspectRatio: Double
    @ViewBuilder let content: Content

    init(aspectRatio: Double, @ViewBuilder content: () -> Content) {
        self.aspectRatio = aspectRatio
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let frame = AssetViewerPageLayout(viewport: geometry.size)
                .fittedMediaFrame(aspectRatio: aspectRatio)
            content
                .frame(width: frame.width, height: frame.height)
                .clipped()
                .position(x: frame.midX, y: frame.midY)
        }
    }
}

struct AssetViewerScreen: View {
    @State private var pendingRebackup: RebackupConfirmation?
    @State private var showsBackupFailures = false
    /// pages either side of the current one kept warm. the pager mounts a page
    /// as it scrolls in, which on a quick swipe leaves no time for a download,
    /// so the neighbours are fetched while the current one is being looked at.
    private static let warmRadius = 2

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.openURL) private var openURL
    @Environment(SessionStore.self) private var session

    let onChange: (AssetChange) -> Void
    let onDismissed: () -> Void
    let onRequestDismissal: (() -> Void)?
    let onSelectionChanged: (String) -> Void
    let onPageZoomChanged: (Bool) -> Void
    let onInteractiveMediaInteractionStarted: () -> Void
    let onChromeVisibilityChanged: (Bool) -> Void
    let onMediaFrameSourceChanged: (String, UIView, Double, Bool) -> Void
    /// Mirrors whether the information sheet is absent, so the zoom
    /// transition only claims pans that belong to the unobstructed media.
    let onMediaAtTopChanged: (Bool) -> Void
    let onBoundImage: (Asset, BoundRemoteImage) -> Void
    let onBoundLocalImage: (Asset, BoundLocalImage) -> Void
    let onMediaIdentityChanged: () -> Void
    let presentationID: UUID
    let zoomNamespace: Namespace.ID?
    let isContextPreview: Bool
    let loadsViewerContent: Bool
    let transitionMediaVisible: Bool
    let usesExternalBackdrop: Bool
    let mediaTopSafeAreaInset: CGFloat?
    let mediaBottomSafeAreaInset: CGFloat?
    let openingMediaSurface: CommittedGridSurface?
    let editorOpeningSurface: () -> CommittedGridSurface?
    /// set when the grid behind is an album, which adds removal to the menu.
    let album: AlbumContext?
    /// set by album grids the signed-in user owns, so the photo on screen can
    /// become the album's cover. the album screen runs the request itself.
    let onSetAlbumCover: ((String) async -> Bool)?
    /// set when the grid behind belongs to one person, which lets the photo on
    /// screen become their portrait.
    let personID: String?
    let onLaunchMediaReady: () -> Void
    private let openingAssetID: String?

    @State private var assets: [Asset]
    /// id to index, rebuilt only when membership changes. every swipe used to
    /// pay several linear scans of the whole list, which shows at tens of
    /// thousands of assets.
    @State private var indexByAssetID: [String: Int]
    @State private var currentIndex: Int
    @State private var selectedAssetID: String?
    @State private var chromeVisible = true
    @State private var physicalSafeAreaInsets = UIEdgeInsets.zero
    @State private var showInfo = false
    /// the crease of a foldable display crossing the viewer, in global
    /// coordinates for the toolbar items that cannot see it themselves.
    @State private var displayFold: DisplayFold?
    /// set when folding halfway opened the information, so unfolding or
    /// closing puts it away again without touching a choice the user made.
    @State private var informationOpenedByPose = false
    @State private var devicePoseTask: Task<Void, Never>?
    @State private var stageSafeAreaInsets = EdgeInsets()
    @State private var barsBottomInset: CGFloat = 0
    @State private var viewerScrollPosition = ScrollPosition(edge: .top)
    /// Only endpoint transitions enter view state. Native scroll geometry owns
    /// every intermediate frame, which keeps UIKit photo/video pages stable.
    @State private var compactScrollEndpoint: AssetViewerScrollEndpoint = .media
    @State private var compactScrollIsActive = false
    @State private var compactSettledOffset: CGFloat = 0
    /// the scroll's top edge while a drag that began inside the information
    /// is in flight. 0 leaves the media reachable.
    @State private var informationFloor: CGFloat = 0
    /// the finger is past the information stop, which resists it.
    @State private var informationRubberBands = false
    @State private var scrollMotionDriver = ScrollMotionDriver()
    @State private var compactScrollTracker = AssetInformationScrollTracker()
    /// 0 to 1 on the toggle spring as the information becomes visible.
    @State private var informationAppearance: CGFloat = 0
    @State private var viewportRetargetTask: Task<Void, Never>?
    /// full-bleed viewport mirrored from the media stage geometry.
    @State private var viewport = ViewerViewport()
    @State private var informationNavigationPath: [AssetInformationDestination] = []
    @State private var pendingInformationDestination: AssetInformationDestination?
    @State private var showAddToAlbum = false
    @State private var shareRequest: AssetShareRequest?
    @State private var showShareLinks = false
    @State private var showActivity = false
    /// bumped when the activity sheet changed something, so the like button reloads.
    @State private var activityGeneration = 0
    @State private var showSimilar = false
    @State private var showEditor = false
    @State private var showProfileCrop = false
    @State private var deviceCopyRemoval = DeviceCopyRemovalCoordinator()
    @State private var confirmation: ViewerConfirmation?
    @State private var confirmationSource: ViewerConfirmationSource = .toolbar
    @State private var airPlayTrigger = 0
    @State private var currentPageZoomed = false
    @State private var mediaPresentationZoomed = false
    @State private var informationZoomHandoff = AssetViewerInformationZoomHandoff()
    @State private var zoomCommandBridge: AssetViewerZoomCommandBridge
    /// device copy of the current asset, when the backup index proves one exists.
    @State private var localIdentifier: String?
    /// server copy of a still-open local asset after it has been backed up.
    @State private var backedUpRemoteID: String?
    @State private var downloading = false
    @State private var mutatingAssetIDs: Set<String> = []
    /// the server's `canEdit` for photos the user does not own, by asset id.
    @State private var serverCanEdit: [String: Bool] = [:]
    /// the server's `spatialScene` for photos, by asset id.
    @State private var spatialSceneOffered: [String: Bool] = [:]
    /// the photo the spatial scene is on. keyed by id, so swiping away leaves it.
    @State private var spatialSceneAssetID: String?
    @State private var optimisticRemovals: [String: ViewerRemoval] = [:]
    @State private var optimisticEdits: [String: AssetEditProjection] = [:]
    @State private var measuredAspectRatios: [String: Double] = [:]
    /// photos' best square crop centre per asset: the face area's centre
    /// across a landscape image, `PFCropUtilitiesCore` crop mode 1.
    @State private var bestSquareCenters: [String: CGPoint] = [:]
    /// screen captures told by the server, which redraw their pages.
    @State private var serverScreenCaptures: [String: Bool] = [:]
    @State private var editCacheKeys: [String: String] = [:]
    @State private var toast: String?
    @State private var isDismissing = false
    @State private var didNotifyDismissal = false
    @State private var launchMediaBridge: AssetViewerLaunchMediaBridge
    @State private var launchMediaReady = false
    @State private var interactiveMediaLaidOut = false
    @State private var prefetcher = ThumbnailPrefetcher(
        targetPixelSize: pagePixelSize,
        localContentMode: .aspectFit
    )
    @State private var playback = VideoPlayback()

    init(
        assets: [Asset],
        indexByAssetID: [String: Int]? = nil,
        initialIndex: Int,
        presentationID: UUID,
        zoomNamespace: Namespace.ID? = nil,
        isContextPreview: Bool = false,
        loadsViewerContent: Bool = true,
        transitionMediaVisible: Bool = true,
        usesExternalBackdrop: Bool = false,
        mediaTopSafeAreaInset: CGFloat? = nil,
        mediaBottomSafeAreaInset: CGFloat? = nil,
        openingMediaSurface: CommittedGridSurface? = nil,
        editorOpeningSurface: @escaping () -> CommittedGridSurface? = { nil },
        zoomCommandBridge: AssetViewerZoomCommandBridge? = nil,
        album: AlbumContext? = nil,
        onSetAlbumCover: ((String) async -> Bool)? = nil,
        personID: String? = nil,
        onRequestDismissal: (() -> Void)? = nil,
        onLaunchMediaReady: @escaping () -> Void = {},
        onSelectionChanged: @escaping (String) -> Void = { _ in },
        onPageZoomChanged: @escaping (Bool) -> Void = { _ in },
        onInteractiveMediaInteractionStarted: @escaping () -> Void = {},
        onChromeVisibilityChanged: @escaping (Bool) -> Void = { _ in },
        onMediaFrameSourceChanged: @escaping (String, UIView, Double, Bool) -> Void = { _, _, _, _ in },
        onMediaAtTopChanged: @escaping (Bool) -> Void = { _ in },
        onBoundImage: @escaping (Asset, BoundRemoteImage) -> Void = { _, _ in },
        onBoundLocalImage: @escaping (Asset, BoundLocalImage) -> Void = { _, _ in },
        onMediaIdentityChanged: @escaping () -> Void = {},
        onDismissed: @escaping () -> Void,
        onChange: @escaping (AssetChange) -> Void
    ) {
        let safeIndex = assets.indices.contains(initialIndex) ? initialIndex : 0
        #if DEBUG || PHASE4_PERFORMANCE
        let constructionSpan = GalleryFrameMetrics.shared.beginSpan("screen-construction", correlationID: presentationID)
        defer { GalleryFrameMetrics.shared.endSpan(constructionSpan) }
        GalleryFrameMetrics.shared.mark("screen-construction-inputs", correlationID: presentationID, values: [
            "loadsContent": loadsViewerContent ? 1 : 0,
            "mediaVisible": transitionMediaVisible ? 1 : 0,
            "hostTop": mediaTopSafeAreaInset ?? -1,
            "hostBottom": mediaBottomSafeAreaInset ?? -1,
        ])
        #endif
        _assets = State(initialValue: assets)
        _indexByAssetID = State(initialValue: indexByAssetID ?? Self.indexMap(for: assets))
        _currentIndex = State(initialValue: safeIndex)
        _selectedAssetID = State(initialValue: assets.indices.contains(safeIndex) ? assets[safeIndex].id : nil)
        _physicalSafeAreaInsets = State(initialValue: Self.activeWindowSafeAreaInsets())
        self.presentationID = presentationID
        self.zoomNamespace = zoomNamespace
        self.isContextPreview = isContextPreview
        self.loadsViewerContent = loadsViewerContent
        self.transitionMediaVisible = transitionMediaVisible
        self.usesExternalBackdrop = usesExternalBackdrop
        self.mediaTopSafeAreaInset = mediaTopSafeAreaInset
        self.mediaBottomSafeAreaInset = mediaBottomSafeAreaInset
        self.openingMediaSurface = openingMediaSurface
        self.editorOpeningSurface = editorOpeningSurface
        _zoomCommandBridge = State(
            initialValue: zoomCommandBridge ?? AssetViewerZoomCommandBridge()
        )
        openingAssetID = assets.indices.contains(safeIndex) ? assets[safeIndex].id : nil
        let initialDuration = assets.indices.contains(safeIndex)
            ? Double(assets[safeIndex].duration ?? 0) / 1_000 : 0
        _playback = State(initialValue: VideoPlayback(seedDuration: initialDuration))
        _launchMediaBridge = State(
            initialValue: AssetViewerLaunchMediaBridge(
                isVisible: AssetViewerOpeningMediaHandoff.startsWithScrollCoupledPreview(
                    loadsViewerContent: loadsViewerContent,
                    usesExternalBackdrop: usesExternalBackdrop,
                    isContextPreview: isContextPreview,
                    hasOpeningImage: openingMediaSurface != nil
                )
            )
        )
        self.album = album
        self.onSetAlbumCover = onSetAlbumCover
        self.personID = personID
        self.onRequestDismissal = onRequestDismissal
        self.onLaunchMediaReady = onLaunchMediaReady
        self.onSelectionChanged = onSelectionChanged
        self.onPageZoomChanged = onPageZoomChanged
        self.onInteractiveMediaInteractionStarted = onInteractiveMediaInteractionStarted
        self.onChromeVisibilityChanged = onChromeVisibilityChanged
        self.onMediaFrameSourceChanged = onMediaFrameSourceChanged
        self.onMediaAtTopChanged = onMediaAtTopChanged
        self.onBoundImage = onBoundImage
        self.onBoundLocalImage = onBoundLocalImage
        self.onMediaIdentityChanged = onMediaIdentityChanged
        self.onDismissed = onDismissed
        self.onChange = onChange
    }

    /// photos floats its information beside the media only when both size
    /// classes are regular. every phone, a pro max in landscape included,
    /// keeps the media and information in one surface.
    private var stageSizeClass: UserInterfaceSizeClass {
        horizontalSizeClass == .regular && verticalSizeClass == .regular ? .regular : .compact
    }

    private var current: Asset? {
        assets.indices.contains(currentIndex) ? session.projectingFavorite(assets[currentIndex]) : nil
    }

    private struct SurfaceIdentity: Equatable {
        let id: String?
        let localID: String?
        let localRevision: String?
        let remoteRevision: String?
        let visibility: String?
        let edited: Bool?
        let pairedID: String?
        let editRevision: String?
        let optimisticOperation: UUID?
    }

    private var surfaceIdentity: SurfaceIdentity {
        let asset = current
        return .init(id: asset?.id, localID: asset?.localIdentifier, localRevision: asset?.localImageVersion,
            remoteRevision: asset?.thumbhash, visibility: asset?.visibility.rawValue, edited: asset?.isEdited,
            pairedID: asset.flatMap { session.backup?.localIdentifierByRemoteId[$0.id] },
            editRevision: asset.flatMap { editCacheKeys[$0.id] },
            optimisticOperation: asset.flatMap { optimisticEdits[$0.id]?.operationID })
    }

    private var mediaShowsChrome: Bool {
        chromePresentation.usesChromeMediaFrame
    }

    private var effectiveMediaTopSafeAreaInset: CGFloat {
        mediaTopSafeAreaInset ?? physicalSafeAreaInsets.top
    }

    private var effectiveMediaBottomSafeAreaInset: CGFloat {
        mediaBottomSafeAreaInset ?? physicalSafeAreaInsets.bottom
    }

    private static func indexMap(for assets: [Asset]) -> [String: Int] {
        var map = [String: Int](minimumCapacity: assets.count)
        for (index, asset) in assets.enumerated() { map[asset.id] = index }
        return map
    }

    private static func activeWindowSafeAreaInsets() -> UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first
        return scene?.windows.first(where: \.isKeyWindow)?.safeAreaInsets
            ?? scene?.windows.first?.safeAreaInsets
            ?? .zero
    }

    /// call after any mutation that changes membership or order.
    private func rebuildIndexMap() {
        indexByAssetID = Self.indexMap(for: assets)
    }

    private var serverAssetID: String? {
        guard let current else { return nil }
        return current.isLocal ? backedUpRemoteID : current.id
    }

    private var actionAvailability: AssetActionAvailability? {
        guard let current else { return nil }
        return AssetActionAvailability(
            asset: current,
            ownsAsset: current.isLocal || ownsCurrent,
            localRemoteIdentifier: backedUpRemoteID,
            pairedLocalIdentifier: current.isLocal ? current.localIdentifier : localIdentifier,
            perUserFavorites: session.capabilities.supportsPerUserFavorites,
            serverCanEdit: serverCanEdit[current.id],
            trimsVideos: session.capabilities.supportsTrim
        )
    }

    /// an owner may always edit, so only someone else's photo asks the
    /// server, which may let a space editor in. a server with spatial scene
    /// says on the same detail whether a photo offers it.
    private func loadServerDetail() async {
        guard let asset = current, !asset.isLocal, let client = session.client else { return }
        let needsCanEdit = !ownsCurrent && serverCanEdit[asset.id] == nil
        let needsSpatialScene = session.capabilities.supportsSpatialScene && asset.isImage
            && spatialSceneOffered[asset.id] == nil
        let needsScreenCapture = screenCaptureValue(asset) == nil
        guard needsCanEdit || needsSpatialScene || needsScreenCapture,
              let detail = try? await client.assetDetail(id: asset.id),
              !Task.isCancelled
        else { return }
        if needsCanEdit, let canEdit = detail.canEdit { serverCanEdit[asset.id] = canEdit }
        if needsSpatialScene { spatialSceneOffered[asset.id] = detail.spatialScene == true }
        if needsScreenCapture {
            let isScreenCapture = AssetScreenCapture.record(detail)
            withAnimation(reduceMotion ? nil : PhotosMotion.information) {
                serverScreenCaptures[asset.id] = isScreenCapture
            }
        }
    }

    private func screenCaptureValue(_ asset: Asset) -> Bool? {
        if let value = serverScreenCaptures[asset.id] { return value }
        return AssetScreenCapture.value(
            for: asset,
            localIdentifier: asset.localIdentifier ?? session.backup?.localIdentifierByRemoteId[asset.id]
        )
    }

    private func isScreenCapture(_ asset: Asset) -> Bool {
        screenCaptureValue(asset) ?? false
    }

    /// photos only styles inset media while the information is away.
    private var stylesMediaInset: Bool {
        !showInfo && compactScrollEndpoint == .media
    }

    /// `PFCropUtilitiesCore` crop mode 1, which photos' square uses: a
    /// centred square, slid across a landscape image to centre its faces and
    /// clamped inside it. upright images keep the centred square.
    private func loadBestSquareCenter() async {
        guard let asset = current, !asset.isLocal, asset.isImage,
              bestSquareCenters[asset.id] == nil,
              let client = session.client
        else { return }
        let aspectRatio = projectedAspectRatio(for: asset)
        guard aspectRatio > 1 else { return }
        guard let faces = try? await client.assetFaces(assetID: asset.id),
              !Task.isCancelled
        else { return }
        var minX = CGFloat.infinity
        var maxX = -CGFloat.infinity
        for face in faces {
            guard let x1 = face.boundingBoxX1, let x2 = face.boundingBoxX2,
                  let width = face.imageWidth, width > 0
            else { continue }
            minX = min(minX, CGFloat(x1) / CGFloat(width))
            maxX = max(maxX, CGFloat(x2) / CGFloat(width))
        }
        guard minX < maxX else {
            bestSquareCenters[asset.id] = CGPoint(x: 0.5, y: 0.5)
            return
        }
        let side = 1 / CGFloat(aspectRatio)
        let originX = min(1 - side, max(0, (minX + maxX) / 2 - side / 2))
        bestSquareCenters[asset.id] = CGPoint(x: originX + side / 2, y: 0.5)
    }

    private var offersSpatialScene: Bool {
        guard let current, !current.isLocal, current.isImage else { return false }
        return session.capabilities.supportsSpatialScene && spatialSceneOffered[current.id] == true
    }

    private var showsSpatialScene: Bool {
        offersSpatialScene && spatialSceneAssetID != nil && spatialSceneAssetID == current?.id
    }

    /// mutations are only offered on assets the signed-in user owns. an
    /// unknown user - offline restore - is treated as the owner, best effort.
    private var ownsCurrent: Bool {
        guard let asset = current else { return false }
        guard let userID = session.user?.id else { return true }
        return asset.ownerId == userID
    }

    /// the portrait is cropped from a face the server already detected on the
    /// photo, so this only stands up for the server copy of a live asset.
    private var canSetFeaturedPhoto: Bool {
        guard personID != nil, let asset = current else { return false }
        return !asset.isLocal && !asset.isTrashed
    }

    /// the server takes a removal from the album's owner or from the owner of
    /// the photo, and the web client offers it to exactly those two.
    private var canRemoveFromAlbum: Bool {
        guard let album, let asset = current, !asset.isLocal else { return false }
        guard let userID = session.user?.id else { return true }
        return asset.ownerId == userID || album.ownerID == userID
    }

    /// photos of a shared album with comments and likes on, once on the server.
    private var activityScope: AlbumActivityScope? {
        guard let scope = album?.activity, scope.isEnabled,
              let asset = current, !asset.isLocal, !asset.isTrashed, asset.visibility != .locked
        else { return nil }
        return scope
    }

    /// the album screen only hands the closure over to the album's owner, so
    /// the only check left here is that the photo lives on the server.
    private var canSetAlbumCover: Bool {
        guard onSetAlbumCover != nil, let asset = current else { return false }
        return !asset.isLocal && !asset.isTrashed
    }

    @ViewBuilder var body: some View {
        // zooming out targets the currently paged asset's tile when visible.
        if let zoomNamespace, !reduceMotion {
            core
                .id(presentationID)
                .navigationTransition(.zoom(sourceID: current?.id ?? "", in: zoomNamespace))
        } else {
            core.id(presentationID)
        }
    }

    private var core: some View {
        #if DEBUG || PHASE4_PERFORMANCE
        let bodySpan = GalleryFrameMetrics.shared.beginSpan("screen-core-expression", correlationID: presentationID)
        defer { GalleryFrameMetrics.shared.endSpan(bodySpan) }
        #endif
        return AnyView(viewerSurface)
            .deviceCopyRemovalPresentation(deviceCopyRemoval)
            .sheet(isPresented: $showsBackupFailures) {
            NavigationStack { BackupFailuresScreen() }
        }
        .confirmationDialog("Back Up Again?", isPresented: Binding(
                get: { pendingRebackup != nil }, set: { if !$0 { pendingRebackup = nil } }
            ), titleVisibility: .visible, presenting: pendingRebackup) { confirmation in
                Button("Back Up Again") {
                    let backup = session.backup
                    Task { await confirmRebackup(confirmation, backup: backup) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This photo was deleted in the cloud. Back Up Again restores its cloud copy from trash when available, or uploads a new copy if it was permanently deleted. The original stays on this device.")
            }
            .sheet(isPresented: regularInformationPresented, onDismiss: openPendingInformationDestination) {
                if let current {
                    AssetInformationSheet(
                        asset: current,
                        serverAssetID: serverAssetID,
                        onDateAdjusted: applyDateAdjustment,
                        onAlbumAdded: { toast = $0 },
                        onOpenPerson: { queueInformationDestination(.person($0)) },
                        onOpenAlbum: { queueInformationDestination(.album($0)) }
                    )
                }
            }
            .sheet(isPresented: $showAddToAlbum) {
                if let current {
                    AddToAlbumSheet(assetIDs: serverAssetID.map { [$0] } ?? [],
                                    localIdentifiers: serverAssetID == nil ? current.localIdentifier.map { [$0] } ?? [] : []) { message in
                        toast = message
                    }
                }
            }
            .background {
                AssetSharePresenter(request: $shareRequest)
            }
            .sheet(isPresented: $showShareLinks) {
                if let serverAssetID {
                    ShareLinksSheet(target: .assets([serverAssetID]))
                }
            }
            .sheet(isPresented: $showActivity) {
                if let scope = activityScope, let current {
                    AlbumActivitySheet(scope: scope, assetID: current.id) {
                        activityGeneration += 1
                    }
                }
            }
            .sheet(isPresented: $showSimilar) {
                if let current {
                    NavigationStack {
                        SearchResultsScreen(
                            title: String(localized: "Similar Photos"),
                            baseFilter: {
                                var filter = SearchFilter()
                                filter.queryAssetID = current.id
                                return filter
                            }(),
                            emptyIcon: "sparkle.magnifyingglass",
                            emptyMessage: String(localized: "No similar photos")
                        )
                    }
                }
            }
            .fullScreenCover(isPresented: $showEditor) {
                if let current {
                    let editedID = current.id
                    let isVideo = current.isVideo
                    AssetEditScreen(
                        asset: current,
                        openingSurface: editorOpeningSurface(),
                        localAssetIdentifier: current.localIdentifier,
                        onLocalSaved: { _ in commitLocalEdit(assetID: editedID) },
                        onRemoteSaveUnconfirmed: { _ in
                            apply(.edited(editedID, thumbhash: nil))
                        },
                        onProjected: projectEdit,
                        onReverted: { revertEdit(assetID: editedID, operationID: $0) },
                        onCommitted: { operationID, detail in
                            commitEdit(assetID: editedID, operationID: operationID, detail: detail)
                        },
                        onFinished: { outcome in
                            guard isVideo, case .saved(let detail) = outcome else { return }
                            commitTrim(assetID: editedID, detail: detail)
                        }
                    )
                    .editorPresentationTransition()
                    .onAppear {
                        if playback.ownerID == editedID, playback.isPlaying { playback.togglePlayPause() }
                    }
                }
            }
            .fullScreenCover(isPresented: $showProfileCrop) {
                if let current {
                    ProfilePictureCropScreen(asset: current) { message in
                        toast = message
                    }
                }
            }
            .task(id: loadsViewerContent ? current?.id : nil) {
                guard loadsViewerContent else { return }
                warmNeighbours()
                localIdentifier = nil
                backedUpRemoteID = nil
                guard let asset = current, let backup = session.backup else { return }
                if let localID = asset.localIdentifier {
                    localIdentifier = localID
                    let remoteID = await backup.remoteIdentifier(forLocal: localID)
                    guard !Task.isCancelled, current?.id == asset.id else { return }
                    backedUpRemoteID = remoteID
                    return
                }
                let identifier = await backup.localIdentifier(forRemote: asset.id)
                guard !Task.isCancelled, current?.id == asset.id else { return }
                localIdentifier = identifier
            }
            .task(id: loadsViewerContent ? current?.id : nil) {
                guard loadsViewerContent else { return }
                await loadServerDetail()
            }
            .task(id: loadsViewerContent ? current?.id : nil) {
                guard loadsViewerContent else { return }
                await loadBestSquareCenter()
            }
            .overlay(alignment: .top) {
                if let toast {
                    ToastBanner(text: toast) { self.toast = nil }
                        .avoidsActiveFold(displayFold)
                }
            }
    }

    // debug builds give every step of a modifier chain on an opaque view its
    // own stack copy, so one long chain here overflowed the 1MB main thread
    // stack on device. erasing splits it into short chains.
    private var viewerSurface: some View {
        AnyView(viewerNavigation)
            .containerBackground(
                usesExternalBackdrop ? Color.black : Color(uiColor: .systemBackground),
                for: .navigation
            )
            // photos hands the whole top of the screen to the media while its
            // information is up.
            .statusBarHidden(
                isContextPreview
                    || !chromeVisible
                    || (stageSizeClass != .regular && compactScrollEndpoint != .media)
            )
            .allowsHitTesting(!isContextPreview && !isDismissing)
            // hardware keyboard on ipad: paging, info and closing without
            // reaching for the screen. a text field on any sheet takes the
            // keyboard back for as long as it is up.
            .background {
                KeyCommandHost(
                    isActive: loadsViewerContent && !isContextPreview && !isDismissing,
                    commands: keyboardCommands
                )
            }
            .onAppear {
                onChromeVisibilityChanged(chromeVisible)
                if let selectedAssetID { onSelectionChanged(selectedAssetID) }
            }
            .onChange(of: surfaceIdentity) { _, _ in onMediaIdentityChanged() }
            .onChange(of: compactScrollEndpoint != .media) { _, visible in
                // photos shows its chrome with the information, which also puts
                // the media in the frame the information stop is measured from.
                if visible, !chromeVisible { setChromeVisible(true) }
                withAnimation(reduceMotion ? nil : PhotosMotion.information) {
                    informationAppearance = visible ? 1 : 0
                }
            }
            .onChange(of: selectedAssetID) { _, id in
                deviceCopyRemoval.cancel()
                cancelPendingInformationZoom()
                guard let id, let index = indexByAssetID[id] else { return }
                currentIndex = index
                // every asset stops where its own media becomes the square.
                // a shorter stop on the previous media can leave the offset
                // short of this one, so any visible information retargets.
                if stageSizeClass != .regular, compactScrollEndpoint != .media {
                    Task { @MainActor in
                        await Task.yield()
                        // a settle still in flight is fine to retarget, a finger is not.
                        guard compactScrollEndpoint != .media,
                              !compactScrollTracker.awaitsRelease
                        else { return }
                        scrollCompact(to: compactPageLayout.informationRevealOffset)
                    }
                }
                currentPageZoomed = false
                mediaPresentationZoomed = false
                spatialSceneAssetID = nil
                onSelectionChanged(id)
                onPageZoomChanged(false)
            }
            .onDisappear {
                cancelPendingInformationZoom()
                prefetcher.cancel()
                viewportRetargetTask?.cancel()
                guard !didNotifyDismissal else { return }
                didNotifyDismissal = true
                currentPageZoomed = false
                mediaPresentationZoomed = false
                onPageZoomChanged(false)
                onDismissed()
            }
    }

    private var viewerNavigation: some View {
        NavigationStack(path: $informationNavigationPath) {
            viewerRoot
        }
    }

    private var viewerRoot: some View {
        AnyView(viewerStage)
            // the native bars alone; accessories are anchored to the stage.
            .background {
                Color.clear
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.safeAreaInsets.bottom
                    } action: { inset in
                        #if DEBUG || PHASE4_PERFORMANCE
                        GalleryFrameMetrics.shared.mark("screen-toolbar-bottom-inset", correlationID: presentationID,
                            values: ["old": barsBottomInset, "new": inset, "changed": barsBottomInset != inset ? 1 : 0])
                        #endif
                        barsBottomInset = inset
                    }
            }
            .toolbarVisibility(
                chromePresentation.showsNavigationBar ? .visible : .hidden,
                for: .navigationBar
            )
            .toolbarVisibility(
                chromePresentation.showsViewerBottomBar ? .visible : .hidden,
                for: .bottomBar
            )
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar, .bottomBar)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            .navigationBarTitleDisplayMode(.inline)
            .tint(.white)
            .navigationDestination(for: AssetInformationDestination.self) { destination in
                informationDestinationView(destination)
                    .tint(.accentColor)
                    .toolbarBackgroundVisibility(.automatic, for: .navigationBar)
                    .toolbarColorScheme(nil, for: .navigationBar)
            }
            .onChange(of: showInfo, initial: true) { _, visible in
                if !visible { informationOpenedByPose = false }
                reportMediaAtTop()
            }
            .onDevicePoseChange(perform: handleDevicePose)
            .onChange(of: informationNavigationPath) {
                reportMediaAtTop()
            }
            .onChange(of: pendingInformationDestination) {
                reportMediaAtTop()
            }
            .onChange(of: stageSizeClass) { _, sizeClass in
                if sizeClass == .regular {
                    viewportRetargetTask?.cancel()
                    compactScrollEndpoint = .media
                    compactScrollIsActive = false
                    compactSettledOffset = 0
                    viewerScrollPosition.scrollTo(y: 0)
                } else if showInfo {
                    viewportRetargetTask?.cancel()
                    viewportRetargetTask = Task { @MainActor in
                        await Task.yield()
                        guard !Task.isCancelled,
                              stageSizeClass != .regular,
                              showInfo
                        else { return }
                        scrollCompact(to: compactPageLayout.informationRevealOffset)
                    }
                }
            }
            // the toolbar values are large, so they join the chain last.
            .toolbar { topToolbarContent }
            .toolbar { bottomToolbarContent }
    }

    private var viewerStage: some View {
        GeometryReader { geometry in
            let pageLayout = compactLayout(
                geometry.size,
                bottomInset: geometry.safeAreaInsets.bottom
            )

            Group {
                if stageSizeClass == .regular {
                    regularStage
                } else {
                    compactViewer(pageLayout)
                }
            }
            .onDisplayFoldChange { displayFold = $0 }
            .onGeometryChange(for: ViewerViewport.self) { proxy in
                ViewerViewport(
                    size: proxy.size,
                    bottomInset: proxy.safeAreaInsets.bottom
                )
            } action: { updateViewport($0) }
            .overlay(alignment: .topLeading) {
                if current?.isLivePhoto == true, chromePresentation.showsCarousel {
                    LivePhotoControlsBar(playback: playback)
                        .padding(.leading, 16)
                        .padding(.top, physicalSafeAreaInsets.top + 58)
                }
            }
            .overlay(alignment: .bottom) {
                bottomAccessoryBar
                    .padding(.bottom, physicalSafeAreaInsets.bottom + 60)
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            if showsSpatialSceneToggle {
                spatialSceneToggle
                    .padding(.top, 15)
                    .padding(.trailing, 16)
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? nil : PhotosMotion.controls,
            value: showsSpatialSceneToggle
        )
        // measured outside the full bleed stage, so it still carries the
        // bars and the camera housing the stage itself extends under.
        .background {
            Color.clear
                .onGeometryChange(for: EdgeInsets.self) { proxy in
                    proxy.safeAreaInsets
                } action: { insets in
                    #if DEBUG || PHASE4_PERFORMANCE
                    GalleryFrameMetrics.shared.mark("screen-stage-safe-area", correlationID: presentationID, values: [
                        "changed": stageSafeAreaInsets != insets ? 1 : 0,
                        "oldTop": stageSafeAreaInsets.top, "oldBottom": stageSafeAreaInsets.bottom,
                        "oldLeading": stageSafeAreaInsets.leading, "oldTrailing": stageSafeAreaInsets.trailing,
                        "newTop": insets.top, "newBottom": insets.bottom,
                        "newLeading": insets.leading, "newTrailing": insets.trailing,
                    ])
                    #endif
                    stageSafeAreaInsets = insets
                }
        }
    }

    private func compactViewer(_ layout: AssetViewerPageLayout) -> some View {
        ScrollView(.vertical) {
            // One native scroll owns both regions. In particular, the media is
            // not an overlay/header, so a second upward gesture carries it
            // completely offscreen while information continues naturally.
            // This stack is intentionally eager: there are only two children,
            // and evicting the pager would recreate zoom/video state on return.
            VStack(spacing: 0) {
                mediaStage(followsCompactScroll: true)
                    .frame(height: layout.mediaHeight)
                    .clipped()
                    // side by side, the media stays put while the information
                    // scrolls up beside it.
                    // below a floor, the square stays put as the information
                    // overscrolls: photos never moves its media back down.
                    .visualEffect { [sideBySide = layout.usesSideBySideInformation, floor = informationFloor] effect, proxy in
                        let offset = -proxy.frame(in: .scrollView(axis: .vertical)).minY
                        let pinned = floor > 0 ? min(0, offset - floor) : 0
                        return effect.offset(y: sideBySide ? max(0, offset) : pinned)
                    }
                    .environment(\.assetViewerInformationFloor, informationFloor)

                if let current {
                    Group {
                        if loadsViewerContent {
                            AssetInformationPanel(
                                asset: current,
                                serverAssetID: serverAssetID,
                                // the endpoint leaves .media the moment a drag starts
                                // revealing information, so the load still begins
                                // ahead of the panel actually settling on screen.
                                isRevealed: showInfo || compactScrollEndpoint != .media,
                                bottomContentInset: layout.bottomSafeAreaInset + 80,
                                onDateAdjusted: applyDateAdjustment,
                                onAlbumAdded: { toast = $0 },
                                onOpenPerson: { queueInformationDestination(.person($0)) },
                                onOpenAlbum: { queueInformationDestination(.album($0)) }
                            )
                            .modifier(
                                AssetInformationEntranceEffect(
                                    informationTop: layout.informationTop,
                                    revealOffset: layout.informationRevealOffset,
                                    floor: informationFloor,
                                    rubberBandRange: informationRubberBands ? layout.viewport.height : 0,
                                    appearanceOffset: reduceMotion
                                        ? 0
                                        : informationAppearanceDistance(layout) * (1 - informationAppearance)
                                )
                            )
                        } else {
                            Color.clear
                        }
                    }
                    .frame(minHeight: layout.informationMinimumHeight, alignment: .top)
                    // beside the media it keeps clear of the camera housing.
                    .padding(
                        .trailing,
                        layout.usesSideBySideInformation ? stageSafeAreaInsets.trailing : 0
                    )
                    .frame(maxWidth: .infinity)
                    // information continues the black media stage below the
                    // fold, so its content always resolves dark. at rest it
                    // stays clear: a screen capture fills the page once the
                    // bars hide, past where the information attaches.
                    .background(Color.black.opacity(compactScrollEndpoint == .media ? 0 : 1))
                    .environment(\.colorScheme, .dark)
                    .padding(
                        .leading,
                        layout.usesSideBySideInformation ? layout.sideBySideMediaWidth : 0
                    )
                    // attached right under the resting media, as photos lays
                    // its accessory content out from the media's bottom.
                    .padding(.top, layout.informationTop - layout.mediaHeight)
                    // at rest it lies under the empty stage below the media,
                    // which must keep paging and toggling chrome.
                    .allowsHitTesting(compactScrollEndpoint != .media)
                }
            }
            .coordinateSpace(.named(AssetViewerScrollContent.space))
            .background(ScrollViewLocator(driver: scrollMotionDriver, onPan: trackCompactPan))
        }
        .scrollPosition($viewerScrollPosition)
        .scrollTargetBehavior(
            AssetInformationScrollTargetBehavior(
                restingMediaFrame: restingMediaFrame(in: layout.viewport),
                tracker: compactScrollTracker
            )
        )
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .scrollDisabled(!loadsViewerContent || currentPageZoomed || isContextPreview)
        .scrollEdgeEffectHidden(true, for: .top)
        // photos keeps the stage pure black under the carousel and toolbar.
        .scrollEdgeEffectHidden(compactScrollEndpoint == .media, for: .bottom)
        // top overscroll shows the media backdrop, bottom overscroll the black
        // information surface.
        .background {
            VStack(spacing: 0) {
                usesExternalBackdrop ? Color.black : Color(uiColor: .systemBackground)
                Color.black
            }
            .ignoresSafeArea()
        }
        .transaction { transaction in
            // Metadata loads below a fixed media boundary; automatic relative
            // offset correction would only move an already-settled viewer.
            transaction.scrollContentOffsetAdjustmentBehavior = .disabled
        }
        .onScrollGeometryChange(for: AssetViewerScrollEndpoint.self) { scroll in
            compactEndpoint(for: scroll)
        } action: { _, endpoint in
            updateCompactEndpoint(endpoint)
        }
        .onScrollGeometryChange(for: CGFloat.self) { scroll in
            scroll.visibleRect.minY
        } action: { _, offset in
            compactScrollTracker.offset = offset
        }
        .onScrollPhaseChange { oldPhase, phase, context in
            #if DEBUG || PHASE4_PERFORMANCE
            GalleryFrameMetrics.shared.mark("screen-compact-scroll-phase", correlationID: presentationID, values: [
                "oldActive": compactScrollIsActive ? 1 : 0, "newActive": phase != .idle ? 1 : 0,
                "oldSettledOffset": compactSettledOffset, "newVisibleOffset": context.geometry.visibleRect.minY,
                "containerWidth": context.geometry.containerSize.width,
                "containerHeight": context.geometry.containerSize.height,
            ])
            #endif
            let beginsInteraction = AssetViewerOpeningMediaHandoff.beginsCompactInteraction(
                isTracking: phase == .tracking,
                isInteracting: phase == .interacting,
                previousWasTracking: oldPhase == .tracking
            )
            if beginsInteraction {
                scrollMotionDriver.stop(finished: false)
                cancelPendingInformationZoom()
                claimOpeningTransitionMedia()
            }
            compactScrollIsActive = phase != .idle
            let liveLayout = compactLayout(context.geometry.containerSize)
            let offset = max(0, context.geometry.visibleRect.minY)
            // a quick flick can reach this handler already decelerating.
            let fingerLifted = phase != .tracking && phase != .interacting
            if fingerLifted, let release = compactScrollTracker.pendingRelease {
                compactScrollTracker.pendingRelease = nil
                if release.bouncesAtEdge {
                    bounceCompact(
                        at: release.target,
                        velocity: release.velocity,
                        range: liveLayout.viewport.height
                    )
                } else {
                    scrollCompact(to: release.target, velocity: release.velocity)
                }
                return
            }
            if fingerLifted, informationRubberBands {
                informationRubberBands = false
            }
            guard phase == .idle, !scrollMotionDriver.isRunning else { return }
            informationFloor = 0
            let presentation = liveLayout.presentation(scrollOffset: offset)
            if let canonicalOffset = liveLayout.canonicalEndpointOffset(
                scrollOffset: offset
            ) {
                compactSettledOffset = canonicalOffset
                showInfo = liveLayout.informationRevealOffset > 0
                    && canonicalOffset == liveLayout.informationRevealOffset
                if abs(canonicalOffset - offset) > AssetViewerPageLayout.scrollCommandTolerance {
                    viewerScrollPosition.scrollTo(y: canonicalOffset)
                }
                return
            }
            compactSettledOffset = presentation.scrollOffset
            // a touch that catches a transition mid flight can rest the media
            // between endpoints where nothing else moves the scroll again, so
            // recover to the nearest endpoint.
            if !presentation.isMediaAtTop, !presentation.isShowingInformation {
                let target = presentation.informationProgress >= 0.5
                    ? liveLayout.informationRevealOffset
                    : 0
                scrollCompact(to: target)
            }
        }
    }

    /// information beside the media rather than over it whenever a fold
    /// crosses the viewer: the sheet would sit right on the crease and hide
    /// the photo it describes.
    private var splitsInformation: Bool {
        stageSizeClass == .regular
            && displayFold != nil
            && !isContextPreview
    }

    @ViewBuilder private var regularStage: some View {
        if #available(iOS 27.1, *), splitsInformation {
            ArrangementView {
                mediaStage(followsCompactScroll: false)
                    .splitArrangementLayoutRatio(showInfo ? nil : 1)
            } secondary: {
                if showInfo, let current {
                    AssetInformationSheet(
                        asset: current,
                        serverAssetID: serverAssetID,
                        onDateAdjusted: applyDateAdjustment,
                        onAlbumAdded: { toast = $0 },
                        onOpenPerson: { queueInformationDestination(.person($0)) },
                        onOpenAlbum: { queueInformationDestination(.album($0)) }
                    )
                    .safeAreaPadding(stageSafeAreaInsets)
                }
            }
            .arrangementViewStyle(.split)
            // a partly folded display keeps the media off the crease, so
            // with nothing beside it the far half carries on the stage.
            .background(Color.black)
        }
        else {
            mediaStage(followsCompactScroll: false)
        }
    }

    /// folding halfway props the device up like a book or a laptop, which
    /// makes room for the details on the other half. the pose has to hold
    /// for a moment, as opening or closing passes through it on the way.
    private func handleDevicePose(_ pose: DevicePose) {
        devicePoseTask?.cancel()
        switch pose {
            case .partiallyOpen:
                devicePoseTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled,
                          splitsInformation,
                          !showInfo,
                          !currentPageZoomed
                    else { return }
                    setInfoVisible(true)
                    informationOpenedByPose = showInfo
                }
            case .fullyOpen, .closed:
                guard informationOpenedByPose else { return }
                informationOpenedByPose = false
                setInfoVisible(false)
        }
    }

    private func mediaStage(followsCompactScroll: Bool) -> some View {
        ZStack {
            Color.black
                .accessibilityIdentifier("asset-viewer")
                .accessibilityValue(selectedAssetID ?? "")

            ZStack {
                if loadsViewerContent {
                    AssetPager(
                        assets: assets,
                        indexByID: indexByAssetID,
                        selection: $selectedAssetID,
                        followsCompactScroll: followsCompactScroll,
                        showsChrome: mediaShowsChrome,
                        topSafeAreaInset: effectiveMediaTopSafeAreaInset,
                        bottomSafeAreaInset: effectiveMediaBottomSafeAreaInset,
                        mutesVideo: isContextPreview,
                        playback: playback,
                        optimisticEdits: optimisticEdits,
                        measuredAspectRatios: measuredAspectRatios,
                        editCacheKeys: editCacheKeys,
                        bestSquareCenters: bestSquareCenters,
                        isScreenCapture: isScreenCapture,
                        stylesInset: stylesMediaInset,
                        openingAssetID: openingAssetID,
                        launchMediaBridge: launchMediaBridge,
                        openingMediaSurface: openingMediaSurface,
                        onBoundImage: onBoundImage,
                        onBoundLocalImage: onBoundLocalImage,
                        onLaunchMediaReady: {
                            launchMediaReady = true
                            onLaunchMediaReady()
                        },
                        allowsDoubleTapZoom: stageSizeClass == .regular
                            || compactScrollEndpoint == .media,
                        onMediaTap: handleMediaTap,
                        onDoubleTapZoomChanged: handleDoubleTapZoomChange,
                        onHorizontalInteractionStarted: handleHorizontalInteractionStarted,
                        onZoomInteractionStarted: claimInteractiveMedia,
                        onZoomPresentationChanged: { isZoomed in
                            withAnimation(
                                reduceMotion
                                    ? .linear(duration: 0.12)
                                    : PhotosMotion.controls
                            ) {
                                mediaPresentationZoomed = isZoomed
                            }
                        },
                        onAspectRatioMeasured: recordMeasuredAspectRatio
                    ) { id, isZoomed in
                        guard id == selectedAssetID else { return }
                        if isZoomed { claimInteractiveMedia() }
                        setCurrentPageZoomed(isZoomed)
                    }
                    .environment(zoomCommandBridge)
                    .onGeometryChange(for: Bool.self) { proxy in
                        proxy.size.width > 0 && proxy.size.height > 0
                    } action: { isLaidOut in
                        if isLaidOut { interactiveMediaLaidOut = true }
                    }
                }

                if let current, loadsViewerContent, showsSpatialScene {
                    SpatialSceneOverlay(
                        assetID: current.id,
                        cacheKey: editCacheKeys[current.id] ?? current.thumbhash,
                        aspectRatio: projectedAspectRatio(for: current),
                        onTap: handleMediaTap,
                        onFailure: {
                            spatialSceneAssetID = nil
                            toast = String(localized: "Spatial Scene is not available for this photo.")
                        }
                    )
                    .modifier(
                        AssetViewerMediaScrollEffect(
                            followsCompactScroll: followsCompactScroll,
                            aspectRatio: projectedAspectRatio(for: current),
                            showsChrome: mediaShowsChrome,
                            topSafeAreaInset: effectiveMediaTopSafeAreaInset,
                            bottomSafeAreaInset: effectiveMediaBottomSafeAreaInset,
                            isScreenCapture: isScreenCapture(current),
                            bestSquareCenter: bestSquareCenters[current.id] ?? CGPoint(x: 0.5, y: 0.5),
                            clipsToMediaFrame: true,
                            stylesInset: stylesMediaInset
                        )
                    )
                    .transition(.opacity)
                }

                if let current {
                    let aspectRatio = projectedAspectRatio(for: current)
                    AssetViewerMediaFrameAnchor(
                        assetID: current.id,
                        aspectRatio: aspectRatio,
                        onRegistrationChanged: onMediaFrameSourceChanged
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(
                        AssetViewerMediaScrollEffect(
                            followsCompactScroll: followsCompactScroll,
                            aspectRatio: aspectRatio,
                            showsChrome: mediaShowsChrome,
                            topSafeAreaInset: effectiveMediaTopSafeAreaInset,
                            bottomSafeAreaInset: effectiveMediaBottomSafeAreaInset,
                            isScreenCapture: isScreenCapture(current),
                            bestSquareCenter: bestSquareCenters[current.id] ?? CGPoint(x: 0.5, y: 0.5)
                        )
                    )
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(transitionMediaVisible ? 1 : 0)
            .scrollEdgeEffectHidden(true, for: .top)
            .accessibilityIdentifier("asset-media")
            .simultaneousGesture(
                infoSwipeGesture,
                isEnabled: stageSizeClass == .regular
            )

            AirPlayRoutePicker(trigger: $airPlayTrigger)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)

            ViewerPhysicalSafeAreaReader { insets in
                #if DEBUG || PHASE4_PERFORMANCE
                GalleryFrameMetrics.shared.mark("screen-physical-safe-area", correlationID: presentationID, values: [
                    "changed": physicalSafeAreaInsets != insets ? 1 : 0,
                    "oldTop": physicalSafeAreaInsets.top, "oldBottom": physicalSafeAreaInsets.bottom,
                    "oldLeft": physicalSafeAreaInsets.left, "oldRight": physicalSafeAreaInsets.right,
                    "newTop": insets.top, "newBottom": insets.bottom,
                    "newLeft": insets.left, "newRight": insets.right,
                ])
                #endif
                physicalSafeAreaInsets = insets
            }
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        }
        .task(id: loadsViewerContent && interactiveMediaLaidOut && launchMediaReady) {
            guard loadsViewerContent else {
                launchMediaBridge.isVisible = false
                interactiveMediaLaidOut = false
                return
            }
            guard interactiveMediaLaidOut, launchMediaReady else { return }
            await Task.yield()
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: 0.08)) {
                launchMediaBridge.isVisible = false
            }
        }
        .onChange(of: loadsViewerContent) { _, loads in
            guard loads else { return }
            launchMediaBridge.isVisible = AssetViewerOpeningMediaHandoff.startsWithScrollCoupledPreview(
                loadsViewerContent: true, usesExternalBackdrop: usesExternalBackdrop,
                isContextPreview: isContextPreview, hasOpeningImage: openingMediaSurface != nil
            )
        }
    }

    /// Accessories fade in place above the bottom toolbar. Keeping them in
    /// the full-bleed stage avoids following the toolbar's animated safe area.
    /// The transport occupies real layout space so all of it receives touches.
    private var bottomAccessoryBar: some View {
        VStack(spacing: 14) {
            if chromePresentation.reservesTransportControls {
                VideoControlsBar(playback: playback)
                    .environment(\.colorScheme, .dark)
                    .accessibilityHidden(!chromePresentation.showsTransportControls)
            }
            AssetViewerCarousel(
                assets: assets,
                indexByAssetID: indexByAssetID,
                selection: $selectedAssetID,
                aspectRatio: projectedAspectRatio(for:)
            )
            .accessibilityHidden(!chromePresentation.showsCarousel)
        }
        .opacity(chromePresentation.showsCarousel ? 1 : 0)
        .allowsHitTesting(chromePresentation.showsCarousel)
        .accessibilityHidden(!chromePresentation.showsCarousel)
        .padding(.bottom, 4)
    }

    // MARK: - prefetching

    /// downloads and decodes the pages around the current one so a swipe lands
    /// on pixels instead of a placeholder. device-paired videos are skipped -
    /// they play locally - but a remote video page opens on exactly this
    /// preview url as its poster, so it warms like a photo.
    private func warmNeighbours() {
        guard assets.indices.contains(currentIndex) else { return prefetcher.cancel() }
        let lower = max(0, currentIndex - Self.warmRadius)
        let upper = min(assets.count - 1, currentIndex + Self.warmRadius)

        var remote: Set<URL> = []
        var local: Set<String> = []
        var localScopes: [String: String] = [:]
        for asset in assets[lower...upper] {
            let paired = asset.isEdited == true || asset.visibility == .locked ? nil : session.backup?.localIdentifierByRemoteId[asset.id]
            if let localIdentifier = asset.localIdentifier ?? paired {
                if !asset.isVideo {
                    local.insert(localIdentifier)
                    localScopes[localIdentifier] = AssetThumbnailSource.localCacheScope(accountKey: session.client?.offlineAccountKey,
                        version: asset.localImageVersion ?? asset.thumbhash, pixels: pagePixelSize)
                }
            } else if let client = session.client {
                remote.insert(
                    client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: asset.thumbhash)
                )
            }
        }
        prefetcher.warm(remote: remote, local: local, localScopes: localScopes, allowsNetwork: true)
    }

    private func toggleInfo() {
        var handoff = informationZoomHandoff
        let effect = handoff.toggle(
            assetID: selectedAssetID,
            isInformationPresented: informationControlIsPresented,
            isZoomed: currentPageZoomed
        )
        informationZoomHandoff = handoff
        applyInformationZoomEffect(effect)
    }

    private func applyInformationZoomEffect(
        _ effect: AssetViewerInformationZoomHandoff.Effect
    ) {
        switch effect {
        case .none:
            break
        case .showInformation:
            setInfoVisible(true)
        case .hideInformation:
            setInfoVisible(false)
        case let .requestFit(request):
            claimOpeningTransitionMedia()
            let started = zoomCommandBridge.fitActivePage(
                assetID: request.assetID
            ) { completed in
                completeInformationZoom(request, completed: completed)
            }
            if !started {
                completeInformationZoom(request, completed: false)
            }
        }
    }

    private func completeInformationZoom(
        _ request: AssetViewerInformationZoomHandoff.Request,
        completed: Bool
    ) {
        var handoff = informationZoomHandoff
        let effect: AssetViewerInformationZoomHandoff.Effect
        if completed {
            effect = handoff.fitCompleted(
                request,
                selectedAssetID: selectedAssetID
            )
        } else {
            handoff.fitCancelled(request)
            effect = .none
        }
        informationZoomHandoff = handoff
        applyInformationZoomEffect(effect)
    }

    private func cancelPendingInformationZoom() {
        guard informationZoomHandoff.pendingRequest != nil else { return }
        informationZoomHandoff.cancelPending()
        zoomCommandBridge.cancelPendingFit()
    }

    private var informationControlIsPresented: Bool {
        stageSizeClass == .regular
            ? showInfo
            : compactScrollEndpoint != .media
    }

    private func setInfoVisible(_ visible: Bool) {
        guard !visible || !currentPageZoomed else { return }
        if visible { claimOpeningTransitionMedia() }
        if stageSizeClass == .regular {
            guard showInfo != visible else { return }
            showInfo = visible
            return
        }
        if reduceMotion { showInfo = visible }
        let target = visible ? compactPageLayout.informationRevealOffset : 0
        if reduceMotion { compactSettledOffset = target }
        scrollCompact(to: target)
    }

    private var compactPageLayout: AssetViewerPageLayout {
        compactLayout(viewport.size, bottomInset: viewport.bottomInset)
    }

    /// the current asset's resting media frame with chrome, where photos
    /// attaches the information. chrome always shows with the information.
    private func restingMediaFrame(in size: CGSize) -> CGRect? {
        guard let current, size.width > 0, size.height > 0 else { return nil }
        return AssetViewerPageLayout(viewport: size).presentationMediaFrame(
            aspectRatio: projectedAspectRatio(for: current),
            showsChrome: true,
            topSafeAreaInset: effectiveMediaTopSafeAreaInset,
            bottomSafeAreaInset: effectiveMediaBottomSafeAreaInset,
            isScreenCapture: isScreenCapture(current)
        )
    }

    /// how far below its place the information starts when it appears:
    /// its visible height at the stop down to the bottom bar, 386pt on a
    /// 402x874 phone in photos.
    /// photos' `layout:minimumVisibleAccessoryHeightForItemAtIndexPath:`,
    /// which its accessory transition coordinator pushes the appearing panel
    /// down by: the page height above the bars and below the square, which
    /// only a page taller than wide reserves.
    private func informationAppearanceDistance(_ layout: AssetViewerPageLayout) -> CGFloat {
        let size = layout.viewport
        let top = size.width / size.height <= 1 ? size.width : 0
        return max(0, size.height - barsBottomInset - top)
    }

    /// arms the release rules from the scroll view's own pan, which uikit
    /// calls before it asks where a release lands. a drag starting on the
    /// information stop belongs to the information's own scroll view if it
    /// first moves deeper, and to photos' open and close pan otherwise, as
    /// their gesture recognizers decide in photos.
    private func trackCompactPan(_ pan: UIPanGestureRecognizer) {
        guard let scrollView = pan.view as? UIScrollView else { return }
        let tracker = compactScrollTracker
        let translation = -pan.translation(in: scrollView).y
        switch pan.state {
        case .began:
            scrollMotionDriver.stop(finished: false)
            let layout = compactPageLayout
            // uikit mostly zeroes the translation as its pan begins, so the
            // finger's speed tells where it heads, as it does for photos'
            // `gestureRecognizerShouldBegin:`.
            let start = max(0, scrollView.contentOffset.y - translation)
            let headsDeeper = pan.velocity(in: scrollView).y < 0
            tracker.dragStartOffset = start
            tracker.direction = ChangeDirectionFilter()
            tracker.direction.input(translation)
            tracker.scrollsInformation = layout.startsInsideInformation(start)
                || (layout.startsAtInformationStop(start) && headsDeeper)
            tracker.pendingRelease = nil
            tracker.awaitsRelease = true
            informationFloor = tracker.scrollsInformation ? layout.informationRevealOffset : 0
            informationRubberBands = tracker.scrollsInformation
        case .changed:
            tracker.direction.input(translation)
            // photos' close pan carries the media past its resting place 1:1
            // with the finger, where uikit would rubber band.
            let offset = tracker.dragStartOffset + translation
            if !tracker.scrollsInformation, tracker.dragStartOffset > 0, offset < 0 {
                scrollView.contentOffset.y = offset
            }
        default:
            // uikit has asked where the release lands by now, or never will.
            DispatchQueue.main.async { tracker.awaitsRelease = false }
        }
    }

    private func compactLayout(_ size: CGSize, bottomInset: CGFloat = 0) -> AssetViewerPageLayout {
        AssetViewerPageLayout(
            viewport: size,
            bottomSafeAreaInset: bottomInset,
            restingMediaFrame: restingMediaFrame(in: size)
        )
    }

    /// a nil velocity is the info button's toggle. a release passes the
    /// finger's speed in points per second along the offset, played with
    /// photos' release spring.
    private func scrollCompact(to offset: CGFloat, velocity: CGFloat? = nil) {
        let target = max(0, offset)
        compactScrollTracker.awaitsRelease = false
        scrollMotionDriver.stop(finished: false)
        if target < informationFloor { informationFloor = 0 }
        let action = { viewerScrollPosition.scrollTo(y: target) }
        if reduceMotion {
            action()
            return
        }
        guard let velocity else {
            withAnimation(PhotosMotion.information, action)
            return
        }
        let release = AccessoryReleaseSpring(
            start: compactScrollTracker.offset,
            rest: target,
            velocity: velocity / 1000
        )
        scrollMotionDriver.run(release) { finished in
            guard finished else { return }
            compactSettledOffset = target
            showInfo = target > 0
        }
        if !scrollMotionDriver.isRunning {
            withAnimation(PhotosMotion.information, action)
        }
    }

    /// a drag that began inside the information released toward its stop.
    /// uikit would have rubber banded the finger, so the scroll first takes
    /// that offset, then decelerates and bounces off the stop as uikit does.
    private func bounceCompact(at edge: CGFloat, velocity: CGFloat, range: CGFloat) {
        compactScrollTracker.awaitsRelease = false
        var start = compactScrollTracker.offset
        if start < edge {
            start = edge - ScrollEdgePhysics.rubberBand(edge - start, range: range)
        }
        informationRubberBands = false
        guard !reduceMotion else {
            informationFloor = 0
            viewerScrollPosition.scrollTo(y: edge)
            return
        }
        let bounce = ScrollEdgeBounce(start: start, edge: edge, velocity: velocity / 1000)
        scrollMotionDriver.run(bounce) { finished in
            informationFloor = 0
            guard finished else { return }
            compactSettledOffset = edge
            showInfo = true
        }
        if !scrollMotionDriver.isRunning {
            scrollCompact(to: edge, velocity: velocity)
        }
    }

    /// Uses the ScrollView's own viewport and normalized visible origin. This
    /// remains correct when content insets exist and changes only at the two
    /// canonical endpoints, never once per rendered pixel.
    private func compactEndpoint(for scroll: ScrollGeometry) -> AssetViewerScrollEndpoint {
        let presentation = compactLayout(scroll.containerSize)
            .presentation(scrollOffset: max(informationFloor, scroll.visibleRect.minY))
        if presentation.isMediaAtTop { return .media }
        if presentation.isShowingInformation { return .information }
        return .transition
    }

    private func updateCompactEndpoint(_ endpoint: AssetViewerScrollEndpoint) {
        #if DEBUG || PHASE4_PERFORMANCE
        GalleryFrameMetrics.shared.mark("screen-compact-endpoint", correlationID: presentationID, values: [
            "changed": compactScrollEndpoint != endpoint ? 1 : 0,
            "oldMedia": compactScrollEndpoint == .media ? 1 : 0, "newMedia": endpoint == .media ? 1 : 0,
            "oldInformation": compactScrollEndpoint == .information ? 1 : 0,
            "newInformation": endpoint == .information ? 1 : 0,
        ])
        #endif
        compactScrollEndpoint = endpoint
        switch endpoint {
        case .media:
            showInfo = false
        case .information:
            showInfo = true
        case .transition:
            break
        }
        reportMediaAtTop()
    }

    private func updateViewport(_ newViewport: ViewerViewport) {
        let oldViewport = viewport
        #if DEBUG || PHASE4_PERFORMANCE
        GalleryFrameMetrics.shared.mark("screen-viewport", correlationID: presentationID, values: [
            "changed": oldViewport != newViewport ? 1 : 0,
            "oldWidth": oldViewport.size.width, "oldHeight": oldViewport.size.height,
            "oldBottom": oldViewport.bottomInset,
            "newWidth": newViewport.size.width, "newHeight": newViewport.size.height,
            "newBottom": newViewport.bottomInset,
        ])
        #endif
        viewport = newViewport
        viewportRetargetTask?.cancel()

        // Canonical information positions follow the physical viewport across
        // rotation. Deep metadata and an in-flight close retain native motion.
        let oldLayout = compactLayout(oldViewport.size, bottomInset: oldViewport.bottomInset)
        guard stageSizeClass != .regular,
              compactScrollEndpoint == .information,
              !compactScrollIsActive,
              oldViewport.size != .zero,
              oldViewport.size != newViewport.size,
              abs(compactSettledOffset - oldLayout.informationRevealOffset) <= 1
        else { return }

        viewportRetargetTask = Task { @MainActor in
            await Task.yield()
            // the new viewport may already read the old stop as a transition.
            guard !Task.isCancelled,
                  stageSizeClass != .regular,
                  showInfo,
                  !compactScrollIsActive
            else { return }
            let latestReveal = compactPageLayout.informationRevealOffset
            viewerScrollPosition.scrollTo(y: latestReveal)
            compactSettledOffset = latestReveal
        }
    }

    /// the native floating sheet serves regular width only. compact width
    /// renders the in-hierarchy panel instead.
    private var regularInformationPresented: Binding<Bool> {
        Binding(
            get: {
                showInfo
                    && stageSizeClass == .regular
                    && !splitsInformation
            },
            set: { value in
                showInfo = value
            }
        )
    }

    private func applyDateAdjustment(_ assetID: String, _ fileCreatedAt: Date, _ offsetHours: Double) {
        guard let index = indexByAssetID[assetID] else { return }
        assets[index].fileCreatedAt = fileCreatedAt
        assets[index].localOffsetHours = offsetHours
    }

    private func queueInformationDestination(_ destination: AssetInformationDestination) {
        setChromeVisible(true)
        if stageSizeClass == .regular, !splitsInformation {
            pendingInformationDestination = destination
            onMediaAtTopChanged(false)
            showInfo = false
        } else {
            // the panel is part of this hierarchy, so the destination pushes
            // right over it and pops back to it intact.
            informationNavigationPath.append(destination)
            reportMediaAtTop()
        }
    }

    private func setChromeVisible(_ visible: Bool) {
        guard chromeVisible != visible else { return }
        chromeVisible = visible
        onChromeVisibilityChanged(visible)
    }

    private func handleMediaTap() {
        if stageSizeClass != .regular,
           compactScrollEndpoint != .media {
            setInfoVisible(false)
            return
        }
        withAnimation(reduceMotion ? .linear(duration: 0.12) : PhotosMotion.controls) {
            setChromeVisible(!chromeVisible)
        }
    }

    private func handleHorizontalInteractionStarted() {
        cancelPendingInformationZoom()
        claimOpeningTransitionMedia()
    }

    private func handleDoubleTapZoomChange(_ isZoomingIn: Bool) {
        claimInteractiveMedia()
        withAnimation(reduceMotion ? .linear(duration: 0.12) : PhotosMotion.controls) {
            mediaPresentationZoomed = isZoomingIn
            setChromeVisible(!isZoomingIn)
        }
    }

    private func setCurrentPageZoomed(_ isZoomed: Bool) {
        guard currentPageZoomed != isZoomed else { return }
        currentPageZoomed = isZoomed
        onPageZoomChanged(isZoomed)
    }

    private func claimInteractiveMedia() {
        claimOpeningTransitionMedia()
    }

    private func claimOpeningTransitionMedia() {
        onInteractiveMediaInteractionStarted()
    }

    private func projectedAspectRatio(for asset: Asset) -> Double {
        if let projection = optimisticEdits[asset.id],
           let image = UIImage(data: projection.imageData),
           image.size.height > 0 {
            return Double(image.size.width / image.size.height)
        }
        return measuredAspectRatios[asset.id] ?? asset.ratio
    }

    private func recordMeasuredAspectRatio(_ assetID: String, _ image: UIImage) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let ratio = Double(image.size.width / image.size.height)
        guard ratio.isFinite else { return }
        guard let index = indexByAssetID[assetID],
              assets.indices.contains(index)
        else { return }
        let effectiveRatio = projectedAspectRatio(for: assets[index])
        if effectiveRatio > 0,
           abs(ratio - effectiveRatio) <= effectiveRatio * 0.03 {
            return
        }
        measuredAspectRatios[assetID] = ratio
    }

    private func openPendingInformationDestination() {
        guard let destination = pendingInformationDestination else { return }
        informationNavigationPath.append(destination)
        pendingInformationDestination = nil
        reportMediaAtTop()
    }

    private func reportMediaAtTop() {
        onMediaAtTopChanged(
            (stageSizeClass == .regular
                ? !showInfo
                : compactScrollEndpoint == .media)
                && pendingInformationDestination == nil
                && informationNavigationPath.isEmpty
        )
    }

    @ViewBuilder private func informationDestinationView(
        _ destination: AssetInformationDestination
    ) -> some View {
        switch destination {
        case .person(let person):
            PersonScreen(person: person)
        case .album(let album):
            AlbumDetailScreen(
                album: album,
                onAlbumRestored: restoreInformationAlbum
            )
        }
    }

    private func restoreInformationAlbum(_ album: Album) {
        Task { @MainActor in
            // Let AlbumDetail's optimistic pop finish before replaying the
            // failed command's destination into this viewer-owned stack.
            await Task.yield()
            guard !informationNavigationPath.contains(where: { destination in
                guard case .album(let current) = destination else { return false }
                return current.id == album.id
            }) else { return }
            informationNavigationPath.append(.album(album))
        }
    }

    /// Regular width keeps a lightweight swipe-to-open affordance because its
    /// information uses a floating sheet. Compact width is the native outer
    /// ScrollView itself and needs no competing gesture recognizer.
    private var infoSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard stageSizeClass == .regular else { return }
                guard !currentPageZoomed, !showInfo else { return }
                let upwardDistance = -value.translation.height
                guard upwardDistance > 60,
                      upwardDistance > abs(value.translation.width)
                else { return }
                cancelPendingInformationZoom()
                setInfoVisible(true)
            }
    }

    // MARK: - chrome

    private var chromePresentation: AssetViewerChromePresentation {
        let isCompact = stageSizeClass != .regular
        let isAtMedia = isCompact ? compactScrollEndpoint == .media : !showInfo
        let isPlayable = current?.isVideo == true || current?.isLivePhoto == true
        let isPlayerReady = current.map {
            playback.ownerID == $0.id && playback.player != nil
        } ?? false
        return AssetViewerChromePresentation(
            isCompact: isCompact,
            isAtMedia: isAtMedia,
            // information beside the media leaves it unobstructed.
            isInformationPresented: showInfo && !splitsInformation,
            isChromeVisible: chromeVisible,
            isContextPreview: isContextPreview,
            isPlayable: isPlayable,
            isPlayerReady: isPlayerReady,
            isLivePhoto: current?.isLivePhoto == true,
            isMediaZoomed: mediaPresentationZoomed
        )
    }

    /// Native toolbar placements own Dynamic Island, status-bar and home-
    /// indicator clearance and supply the platform's standard hit targets.
    @ToolbarContentBuilder private var topToolbarContent: some ToolbarContent {
        if chromePresentation.mountsTopToolbarItems {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    requestDismissal()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel("Close")
                .accessibilityIdentifier("viewer-close")
            }

            if usesLandscapeToolbar, let current {
                ToolbarSpacer(.fixed, placement: .topBarLeading)
                landscapeLeadingItems(current)
            }

            ToolbarItem(placement: .principal) {
                // information beside the media already leads with the date.
                if let current, !(splitsInformation && showInfo) {
                    titlePill(current)
                        .avoidsActiveFold(displayFold)
                }
            }

            if usesLandscapeToolbar, let current {
                landscapeTrailingItems(current)
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                if let current {
                    backupStatusControl(current)
                }
                if activityScope != nil {
                    Button {
                        showActivity = true
                    } label: {
                        Image(systemName: "bubble.left")
                    }
                    .accessibilityLabel("Comments")
                    .accessibilityIdentifier("viewer-activity")
                }
                moreMenu
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("viewer-menu")
            }
        }
    }

    @ToolbarContentBuilder private var bottomToolbarContent: some ToolbarContent {
        if let current, !usesLandscapeToolbar {
            if current.isLocal {
                localToolbarItems(current)
            } else if current.isTrashed {
                trashedToolbarItems
            } else if current.visibility == .locked {
                lockedToolbarItems(current)
            } else {
                remoteToolbarItems(current)
            }
        }
    }

    /// photos on a phone in landscape has no bottom toolbar: its actions join
    /// the top bar, share and favorite leading, edit, info and delete
    /// trailing, ahead of the more menu.
    private var usesLandscapeToolbar: Bool {
        stageSizeClass != .regular && compactPageLayout.usesSideBySideInformation
    }

    @ToolbarContentBuilder private func landscapeLeadingItems(_ current: Asset) -> some ToolbarContent {
        if !current.isTrashed {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button {
                    shareRequest = AssetShareRequest(assets: [current])
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share")
                .accessibilityIdentifier("viewer-share")

                if actionAvailability?.canFavorite == true {
                    Button {
                        Task { await toggleFavorite() }
                    } label: {
                        Image(systemName: current.isFavorite ? "heart.fill" : "heart")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(current.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                    .accessibilityIdentifier("viewer-favorite")
                    .disabled(mutatingAssetIDs.contains(current.id))
                }

                if !current.isLocal, current.visibility != .locked, let activityScope {
                    AssetLikeButton(scope: activityScope, assetID: current.id, refreshTrigger: activityGeneration)
                }
            }
        }
    }

    @ToolbarContentBuilder private func landscapeTrailingItems(_ current: Asset) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if current.isTrashed {
                if actionAvailability?.canRestore == true {
                    Button {
                        Task { await restore() }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .accessibilityLabel("Restore")
                    .accessibilityIdentifier("viewer-restore")
                }
            } else {
                if actionAvailability?.canEdit == true {
                    Button {
                        showEditor = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Edit")
                    .accessibilityIdentifier("viewer-edit")
                    .disabled(optimisticEdits[current.id] != nil)
                }

                Button {
                    toggleInfo()
                } label: {
                    Image(systemName: informationControlIsPresented ? "info.circle.fill" : "info.circle")
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(informationControlIsPresented ? "Hide Info" : "Show Info")
                .accessibilityIdentifier("viewer-info")
            }

            if current.isTrashed || (!current.isLocal && current.visibility == .locked) {
                if actionAvailability?.canDeletePermanently == true {
                    Button {
                        ask(.deletePermanently, from: .toolbar)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete Permanently")
                    .modifier(confirmationDialog(from: .toolbar))
                }
            } else if current.isLocal
                || actionAvailability?.canDeleteFromDevice == true
                || actionAvailability?.canTrashEverywhere == true {
                deleteMenu
            }
        }
    }

    /// Photos-style placement: share stands alone on the left, the common
    /// nondestructive controls share one glass pill in the center, and delete
    /// stays at the far right with explicit device/everywhere choices.
    @ToolbarContentBuilder private func remoteToolbarItems(_ current: Asset) -> some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button {
                shareRequest = AssetShareRequest(assets: [current])
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share")
            .accessibilityIdentifier("viewer-share")
        }

        ToolbarSpacer(.flexible, placement: .bottomBar)

        if actionAvailability?.canFavorite == true {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    Task { await toggleFavorite() }
                } label: {
                    Image(systemName: current.isFavorite ? "heart.fill" : "heart")
                        .contentTransition(.symbolEffect(.replace))
                        .animation(reduceMotion ? nil : PhotosMotion.layout, value: current.isFavorite)
                }
                .accessibilityLabel(current.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                .accessibilityIdentifier("viewer-favorite")
                .disabled(mutatingAssetIDs.contains(current.id))
            }
        }

        if let activityScope {
            ToolbarItem(placement: .bottomBar) {
                AssetLikeButton(scope: activityScope, assetID: current.id, refreshTrigger: activityGeneration)
            }
        }

        ToolbarItem(placement: .bottomBar) {
            Button {
                toggleInfo()
            } label: {
                Image(systemName: informationControlIsPresented ? "info.circle.fill" : "info.circle")
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(informationControlIsPresented ? "Hide Info" : "Show Info")
            .accessibilityIdentifier("viewer-info")
        }

        if actionAvailability?.canEdit == true {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    showEditor = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Edit")
                .accessibilityIdentifier("viewer-edit")
                .disabled(optimisticEdits[current.id] != nil)
            }
        }

        if actionAvailability?.canDeleteFromDevice == true
            || actionAvailability?.canTrashEverywhere == true {
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                deleteMenu
            }
        }
    }

    /// trashed assets offer restore and permanent delete, like the photos
    /// app's recently deleted album.
    @ToolbarContentBuilder private var trashedToolbarItems: some ToolbarContent {
        if actionAvailability?.canRestore == true {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    Task { await restore() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .accessibilityLabel("Restore")
                .accessibilityIdentifier("viewer-restore")
            }
        }

        if actionAvailability?.canRestore == true,
           actionAvailability?.canDeletePermanently == true {
            ToolbarSpacer(.flexible, placement: .bottomBar)
        }

        if actionAvailability?.canDeletePermanently == true {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    ask(.deletePermanently, from: .toolbar)
                } label: {
                    Image(systemName: "trash")
                }
                .modifier(confirmationDialog(from: .toolbar))
            }
        }
    }

    /// the locked folder keeps share, favorite, info and edit; delete is
    /// permanent there, the trash never showing a locked asset.
    @ToolbarContentBuilder private func lockedToolbarItems(_ current: Asset) -> some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button {
                shareRequest = AssetShareRequest(assets: [current])
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share")
            .accessibilityIdentifier("viewer-share")
        }

        ToolbarSpacer(.flexible, placement: .bottomBar)

        if actionAvailability?.canFavorite == true {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    Task { await toggleFavorite() }
                } label: {
                    Image(systemName: current.isFavorite ? "heart.fill" : "heart")
                        .contentTransition(.symbolEffect(.replace))
                        .animation(reduceMotion ? nil : PhotosMotion.layout, value: current.isFavorite)
                }
                .accessibilityLabel(current.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                .accessibilityIdentifier("viewer-favorite")
                .disabled(mutatingAssetIDs.contains(current.id))
            }
        }

        ToolbarItem(placement: .bottomBar) {
            Button {
                toggleInfo()
            } label: {
                Image(systemName: informationControlIsPresented ? "info.circle.fill" : "info.circle")
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(informationControlIsPresented ? "Hide Info" : "Show Info")
            .accessibilityIdentifier("viewer-info")
        }

        if actionAvailability?.canEdit == true {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    showEditor = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Edit")
                .accessibilityIdentifier("viewer-edit")
                .disabled(optimisticEdits[current.id] != nil)
            }
        }

        if actionAvailability?.canDeletePermanently == true {
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button {
                    ask(.deletePermanently, from: .toolbar)
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete Permanently")
                .modifier(confirmationDialog(from: .toolbar))
            }
        }
    }

    /// Device stills use the same nondestructive controls as cloud photos.
    @ToolbarContentBuilder private func localToolbarItems(_ current: Asset) -> some ToolbarContent {
        remoteToolbarItems(current)
    }

    private var deleteMenu: some View {
        Menu {
            if actionAvailability?.canDeleteFromDevice == true {
                Button(role: .destructive) {
                    ask(.deleteFromDevice, from: .toolbar)
                } label: {
                    Label("Delete from This Device", systemImage: "iphone.slash")
                }
                .accessibilityIdentifier("viewer-delete-device")
            }
            if actionAvailability?.canTrashEverywhere == true {
                Button(role: .destructive) {
                    ask(.trash, from: .toolbar)
                } label: {
                    Label(
                        localIdentifier == nil ? "Move to Trash" : "Move to Trash Everywhere",
                        systemImage: "trash"
                    )
                }
                .accessibilityIdentifier("viewer-trash")
            }
        } label: {
            Image(systemName: "trash")
        }
        .accessibilityLabel("Delete")
        .modifier(confirmationDialog(from: .toolbar))
    }

    private var moreMenu: some View {
        Menu {
            if let current {
                Section {
                    Button { toggleInfo() } label: {
                        Label(
                            informationControlIsPresented ? "Hide Info" : "Show Info",
                            systemImage: "info.circle"
                        )
                    }
                    if actionAvailability?.canEdit == true {
                        Button { showEditor = true } label: {
                            Label("Edit", systemImage: "slider.horizontal.3")
                        }
                        .accessibilityIdentifier("viewer-edit")
                        .disabled(optimisticEdits[current.id] != nil)
                    }
                    if actionAvailability?.canAddToAlbum == true {
                        Button { showAddToAlbum = true } label: {
                            Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                        }
                        .accessibilityIdentifier("viewer-add-to-album")
                    }
                    if canRemoveFromAlbum {
                        Button { Task { await removeFromAlbum() } } label: {
                            Label("Remove from Album", systemImage: "rectangle.stack.badge.minus")
                        }
                        .accessibilityIdentifier("viewer-remove-from-album")
                    }
                    if canSetAlbumCover {
                        Button { Task { await setAlbumCover() } } label: {
                            Label("Set as Album Cover", systemImage: "photo.badge.checkmark")
                        }
                        .accessibilityIdentifier("viewer-album-cover")
                        .disabled(mutatingAssetIDs.contains(current.id))
                    }
                    if actionAvailability?.canViewInTimeline == true {
                        Button { viewCurrentInTimeline() } label: {
                            Label("View in Timeline", systemImage: "photo.on.rectangle.angled")
                        }
                        .accessibilityIdentifier("viewer-view-in-timeline")
                    }
                    if actionAvailability?.canShareLink == true {
                        Button { showShareLinks = true } label: {
                            Label("Share Link", systemImage: "link")
                        }
                        .accessibilityIdentifier("viewer-share-link")
                    }
                }

                if current.isLocal, serverAssetID != nil {
                    Section {
                        Button { Task { await openInBrowser() } } label: {
                            Label("Open in Browser", systemImage: "safari")
                        }
                    }
                } else if current.visibility == .locked {
                    // nothing that would surface a locked asset elsewhere.
                    Section {
                        Button { airPlayTrigger += 1 } label: {
                            Label("Cast", systemImage: "airplay.video")
                        }
                        if actionAvailability?.canDownload == true {
                            downloadMenuItem
                        }
                    }
                } else if !current.isTrashed {
                    Section {
                        Button { airPlayTrigger += 1 } label: {
                            Label("Cast", systemImage: "airplay.video")
                        }
                        if session.features?.smartSearch == true {
                            Button { showSimilar = true } label: {
                                Label("View Similar", systemImage: "sparkle.magnifyingglass")
                            }
                            .accessibilityIdentifier("viewer-similar")
                        }
                        if canSetFeaturedPhoto {
                            Button { Task { await setFeaturedPhoto() } } label: {
                                Label("Set as Featured Photo", systemImage: "person.crop.square")
                            }
                            .accessibilityIdentifier("viewer-featured-photo")
                            .disabled(mutatingAssetIDs.contains(current.id))
                        }
                        if current.isImage, ownsCurrent {
                            Button { showProfileCrop = true } label: {
                                Label("Set as Profile Picture", systemImage: "person.crop.circle")
                            }
                            .disabled(session.isProfileImageMutationInFlight)
                        }
                        if actionAvailability?.canDownload == true {
                            downloadMenuItem
                        }
                        Button { Task { await openInBrowser() } } label: {
                            Label("Open in Browser", systemImage: "safari")
                        }
                    }
                }

                if actionAvailability?.canArchive == true {
                    Section {
                        Button { Task { await toggleArchive() } } label: {
                            Label(
                                current.visibility == .archive ? "Unarchive" : "Archive",
                                systemImage: current.visibility == .archive ? "tray.and.arrow.up" : "archivebox"
                            )
                        }
                    }
                }

                if actionAvailability?.canLock == true {
                    Section {
                        Button { ask(.moveToLocked, from: .menu) } label: {
                            Label("Move to Locked Folder", systemImage: "lock")
                        }
                        .accessibilityIdentifier("viewer-lock")
                        .disabled(mutatingAssetIDs.contains(current.id))
                    }
                }

                if actionAvailability?.canUnlock == true {
                    Section {
                        Button { ask(.removeFromLocked, from: .menu) } label: {
                            Label("Remove from Locked Folder", systemImage: "lock.open")
                        }
                        .accessibilityIdentifier("viewer-unlock")
                        .disabled(mutatingAssetIDs.contains(current.id))
                    }
                }

                if actionAvailability?.canDeleteFromDevice == true
                    || actionAvailability?.canTrashEverywhere == true
                    || actionAvailability?.canDeletePermanently == true {
                    Section {
                        if actionAvailability?.canDeleteFromDevice == true {
                            Button(role: .destructive) {
                                ask(.deleteFromDevice, from: .menu)
                            } label: {
                                Label("Delete from This Device", systemImage: "iphone.slash")
                            }
                            .accessibilityIdentifier("viewer-delete-device")
                        }
                        if actionAvailability?.canTrashEverywhere == true {
                            Button(role: .destructive) {
                                ask(.trash, from: .menu)
                            } label: {
                                Label(
                                    localIdentifier == nil ? "Move to Trash" : "Move to Trash Everywhere",
                                    systemImage: "trash"
                                )
                            }
                            .accessibilityIdentifier("viewer-delete")
                        }
                        if actionAvailability?.canDeletePermanently == true {
                            Button(role: .destructive) {
                                ask(.deletePermanently, from: .menu)
                            } label: {
                                Label("Delete Permanently", systemImage: "trash.slash")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        // the dialog anchors to the menu button, not to the vanished menu item.
        .modifier(confirmationDialog(from: .menu))
    }

    @ViewBuilder private var downloadMenuItem: some View {
        if downloading {
            Button {} label: {
                Label("Downloading…", systemImage: "arrow.down.circle.dotted")
            }
            .disabled(true)
        } else {
            Button { Task { await download() } } label: {
                Label("Download to Device", systemImage: "arrow.down.circle")
            }
            .accessibilityIdentifier("viewer-download")
        }
    }

    /// photos floats this under the top bar on its own, away from the other
    /// controls, and only while the media is unobstructed.
    private var showsSpatialSceneToggle: Bool {
        offersSpatialScene
            && chromePresentation.mountsTopToolbarItems
            && (stageSizeClass == .regular || compactScrollEndpoint == .media)
    }

    private var spatialSceneToggle: some View {
        Button {
            withAnimation(reduceMotion ? nil : PhotosMotion.controls) {
                spatialSceneAssetID = showsSpatialScene ? nil : current?.id
            }
        } label: {
            // photos' visionkit chip, measured at 36x19 under the top bar.
            HStack(spacing: 4.5) {
                Image(systemName: showsSpatialScene ? "spatial.capture.fill" : "spatial.capture")
                    .font(.system(size: 12))
                    .contentTransition(.symbolEffect(.replace))
                Image(systemName: "chevron.forward")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.leading, 5.5)
            .padding(.trailing, 4.5)
            .frame(height: 19)
            .background {
                Capsule()
                    .fill(.white.opacity(0.12))
                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
            }
            .padding(8)
            .contentShape(.rect)
            .padding(-8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsSpatialScene ? "Hide Spatial Scene" : "Show Spatial Scene")
        .accessibilityIdentifier("viewer-spatial-scene")
    }

    @ViewBuilder private func backupStatusControl(_ current: Asset) -> some View {
        if let localID = current.localIdentifier {
            if session.backup?.remoteRemovedLocalIDs.contains(localID) == true {
                Menu {
                    Label("Deleted in Cloud", systemImage: "icloud.slash")
                    Button("Back Up Again…") {
                        pendingRebackup = session.backup?.rebackupConfirmation(localIdentifier: localID)
                    }
                    .accessibilityIdentifier("viewer-rebackup-confirmation")
                } label: {
                    Image(systemName: "icloud.slash")
                }
                .accessibilityLabel("Deleted in Cloud")
                .accessibilityIdentifier("viewer-cloud-deleted")
            } else if PhotoBackupStatus.resolve(asset: current, backup: session.backup) == .backedUp {
                Menu {
                    Button {} label: {
                        Label("Backed Up", systemImage: "checkmark.icloud")
                    }
                    .disabled(true)
                    if serverAssetID != nil {
                        Button { showAddToAlbum = true } label: {
                            Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                        }
                    }
                } label: {
                    Image(systemName: "checkmark.icloud")
                }
                .accessibilityLabel("Backed up")
            } else {
                switch PhotoBackupStatus.resolve(asset: current, backup: session.backup) {
                case .uploading(let fraction):
                    ProgressView(value: fraction)
                        .progressViewStyle(.circular)
                        .frame(width: 24, height: 24)
                        .accessibilityLabel("Backing up")
                        .accessibilityValue("\(Int(fraction * 100)) percent")
                case .failed:
                    Menu {
                        Button("Retry Backup") { Task { await backUpCurrent() } }
                        Button("Review Failed Items") { showsBackupFailures = true }
                    } label: {
                        Image(systemName: "exclamationmark.icloud")
                    }
                    .accessibilityLabel("Backup failed. Try again")
                    .accessibilityIdentifier("viewer-backup-failed")
                case .backedUp, .cloudDeleted:
                    EmptyView()
                case .notBackedUp, .sizeExcluded:
                    if session.backup?.sizeExcludedLocalIdentifiers.contains(localID) == true {
                        Menu {
                            Button {} label: {
                                Label("Excluded by Upload Size Limit", systemImage: "minus.circle")
                            }
                            .disabled(true)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .accessibilityLabel("Excluded from backup by the upload size limit")
                        .accessibilityIdentifier("viewer-backup-size-excluded")
                    } else {
                        Button { Task { await backUpCurrent() } } label: {
                            Image(systemName: "icloud.slash")
                        }
                        .accessibilityLabel("Not backed up. Back up now")
                        .accessibilityIdentifier("viewer-back-up")
                    }
                }
            }
        } else if !current.isTrashed {
            Menu {
                Button {} label: {
                    Label("Backed Up", systemImage: "checkmark.icloud")
                }
                .disabled(true)
                if actionAvailability?.canDownload == true {
                    Button { Task { await download() } } label: {
                        Label(
                            downloading ? "Downloading…" : "Download to Device",
                            systemImage: downloading ? "arrow.down.circle.dotted" : "arrow.down.circle"
                        )
                    }
                    .disabled(downloading)
                }
                if actionAvailability?.canAddToAlbum == true {
                    Button { showAddToAlbum = true } label: {
                        Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                    }
                }
            } label: {
                Image(systemName: "checkmark.icloud")
            }
            .accessibilityLabel("Backed up")
        }
    }

    /// floating glass title: the place when known, the relative day and time.
    private func titlePill(_ current: Asset) -> some View {
        let date = current.localDate
        let day = relativeDayLabel(for: date) ?? date.formatted(dateTitleFormat(for: date))
        let time = date.formatted(.dateTime.hour().minute().utc())
        let place = PhotoPlaceName.title(city: current.city, country: current.country)
        return VStack(spacing: 1) {
            Text(place ?? day)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(place == nil ? time : "\(day), \(time)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 136, idealWidth: 156, maxWidth: 210)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }

    /// today and yesterday compare the asset's local wall clock against the
    /// device's, both mapped into the utc calendar space the viewer formats in.
    private func relativeDayLabel(for date: Date) -> String? {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let todayWall = Date().addingTimeInterval(TimeInterval(TimeZone.current.secondsFromGMT()))
        if calendar.isDate(date, inSameDayAs: todayWall) { return String(localized: "Today") }
        if let yesterdayWall = calendar.date(byAdding: .day, value: -1, to: todayWall),
           calendar.isDate(date, inSameDayAs: yesterdayWall) {
            return String(localized: "Yesterday")
        }
        return nil
    }

    /// photos-style title: day and month, with the year once it differs from
    /// the current one.
    private func dateTitleFormat(for date: Date) -> Date.FormatStyle {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day().utc()
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return style
        }
        return style.year()
    }

    // MARK: - confirmation dialogs

    private func ask(_ kind: ViewerConfirmation, from source: ViewerConfirmationSource) {
        confirmationSource = source
        confirmation = kind
    }

    private func confirmationDialog(from source: ViewerConfirmationSource) -> some ViewModifier {
        ViewerConfirmationDialog(
            isPresented: Binding(
                get: { confirmation != nil && confirmationSource == source },
                set: { if !$0 { confirmation = nil } }
            ),
            title: confirmationTitle,
            message: confirmationMessage,
            actions: { confirmationActions }
        )
    }

    private var confirmationTitle: String {
        let noun = current?.isVideo == true ? String(localized: "Video") : String(localized: "Photo")
        switch confirmation {
        case .trash:
            return localIdentifier == nil
                ? String(localized: "Move \(noun) to Trash?")
                : String(localized: "Move \(noun) to Trash Everywhere?")
        case .deletePermanently: return String(localized: "Delete \(noun) Permanently?")
        case .deleteFromDevice: return String(localized: "Delete from This Device?")
        case .moveToLocked: return String(localized: "Move \(noun) to Locked Folder?")
        case .removeFromLocked: return String(localized: "Remove \(noun) from Locked Folder?")
        case nil: return ""
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .trash:
            if current?.isLocal == true {
                return serverAssetID == nil
                    ? String(localized: "This photo is not backed up. It will be removed from your device photo library.")
                    : String(localized: "It will move to the server trash and the copy in your device photo library will be deleted.")
            }
            return localIdentifier != nil
                ? String(localized: "It will move to the server trash and the copy in your device photo library will be deleted.")
                : String(localized: "It will move to the server trash and can be restored from there.")
        case .deletePermanently:
            return localIdentifier != nil
                ? String(localized: "It will be permanently deleted from the server and from this device. This cannot be undone.")
                : String(localized: "It will be permanently deleted from the server. This cannot be undone.")
        case .deleteFromDevice:
            if current?.isLocal == true, serverAssetID == nil {
                return String(localized: "This photo is not backed up. It will be removed from your device photo library permanently.")
            }
            return String(localized: "The copy in your device photo library will be deleted. The server copy is kept.")
        case .moveToLocked:
            return localIdentifier != nil
                ? String(localized: "It will be removed from every album and only show in the locked folder. The copy in your device photo library will be deleted.")
                : String(localized: "It will be removed from every album and only show in the locked folder.")
        case .removeFromLocked:
            return String(localized: "It will show in your library again.")
        case nil:
            return ""
        }
    }

    @ViewBuilder private var confirmationActions: some View {
        switch confirmation {
        case .trash:
            Button(localIdentifier == nil ? "Move to Trash" : "Move to Trash Everywhere", role: .destructive) {
                Task { await trash() }
            }
            .accessibilityIdentifier("viewer-trash-confirm")
        case .deletePermanently:
            Button("Delete Permanently", role: .destructive) {
                Task { await deletePermanently() }
            }
        case .deleteFromDevice:
            Button("Delete from Device", role: .destructive) {
                Task { await deleteFromDevice() }
            }
            .accessibilityIdentifier("viewer-delete-device-confirm")
        case .moveToLocked:
            Button("Move") {
                Task { await moveToLockedFolder() }
            }
            .accessibilityIdentifier("viewer-lock-confirm")
        case .removeFromLocked:
            Button("Remove") {
                Task { await removeFromLockedFolder() }
            }
            .accessibilityIdentifier("viewer-unlock-confirm")
        case nil:
            EmptyView()
        }
        Button("Cancel", role: .cancel) {}
    }

    // MARK: - actions

    private func viewCurrentInTimeline() {
        guard let current, actionAvailability?.canViewInTimeline == true else { return }
        let target = TimelineNavigationTarget(asset: current, serverAssetID: serverAssetID)
        requestDismissal()
        Task { @MainActor in
            await Task.yield()
            TimelineNavigationRouter.shared.open(target)
        }
    }

    // MARK: - keyboard

    private var keyboardCommands: [KeyCommandBinding] {
        [
            KeyCommandBinding(title: String(localized: "Previous Photo"), input: UIKeyCommand.inputLeftArrow) {
                stepSelection(by: -1)
            },
            KeyCommandBinding(title: String(localized: "Next Photo"), input: UIKeyCommand.inputRightArrow) {
                stepSelection(by: 1)
            },
            KeyCommandBinding(title: String(localized: "Play or Pause"), input: " ") {
                togglePlaybackFromKeyboard()
            },
            KeyCommandBinding(title: String(localized: "Info"), input: "i", modifiers: .command) {
                toggleInfo()
            },
            KeyCommandBinding(title: String(localized: "Close"), input: UIKeyCommand.inputEscape) {
                closeFromKeyboard()
            },
        ]
    }

    /// pages through the semantic selection; the pager follows it exactly as
    /// it follows a swipe.
    private func stepSelection(by offset: Int) {
        guard let selectedAssetID, let index = indexByAssetID[selectedAssetID] else { return }
        let target = index + offset
        guard assets.indices.contains(target) else { return }
        self.selectedAssetID = assets[target].id
    }

    private func togglePlaybackFromKeyboard() {
        guard let current, current.isVideo || current.isLivePhoto else { return }
        playback.togglePlayPause()
    }

    /// escape peels one layer: open information first, then the viewer.
    private func closeFromKeyboard() {
        if informationControlIsPresented {
            setInfoVisible(false)
        } else {
            requestDismissal()
        }
    }

    private func requestDismissal() {
        cancelPendingInformationZoom()
        // uikit-owned viewers dedupe and track cancellation in their controller
        // phase. keeping this local latch set after a cancelled interactive close
        // would leave the restored viewer permanently unable to receive taps.
        if let onRequestDismissal {
            onRequestDismissal()
            return
        }
        guard !isDismissing else { return }
        isDismissing = true
        dismiss()
    }

    private func apply(_ change: AssetChange) {
        switch change {
        case .favorite(let id, let value):
            if let index = indexByAssetID[id] {
                assets[index].isFavorite = value
            }
        case .favoriteCommitted:
            break
        case .albumMembershipProjected, .albumMembershipCommitted, .albumMembershipReverted:
            break
        case .optimisticRemoval(let id), .removed(let id):
            if let index = indexByAssetID[id] {
                assets.remove(at: index)
                rebuildIndexMap()
                let resolution = AssetViewerSelectionResolution.resolve(
                    remainingAssetIDs: assets.map(\.id),
                    selectedAssetID: selectedAssetID,
                    removedIndex: index
                )
                currentIndex = resolution.index
                selectedAssetID = resolution.assetID
                if resolution.assetID == nil {
                    requestDismissal()
                }
            }
        case .removalCommitted, .removalReverted:
            break
        case .localDeleted:
            break
        case .edited(let id, let thumbhash, let duration):
            if let index = indexByAssetID[id] {
                if let thumbhash { assets[index].thumbhash = thumbhash }
                if let duration { assets[index].duration = duration }
            }
            // the device copy is now the pre-edit original, so it stops
            // standing in for this asset anywhere in the app.
            session.backup?.noteRemoteEdits([id])
        }
        onChange(change)
    }

    private func projectEdit(_ projection: AssetEditProjection) {
        optimisticEdits[projection.assetID] = projection
    }

    private func revertEdit(assetID: String, operationID: UUID) {
        guard optimisticEdits[assetID]?.operationID == operationID else { return }
        optimisticEdits.removeValue(forKey: assetID)
    }

    private func commitEdit(assetID: String, operationID: UUID, detail: AssetDetail?) {
        guard optimisticEdits[assetID]?.operationID == operationID else { return }
        editCacheKeys[assetID] = detail?.thumbhash ?? operationID.uuidString
        if let index = indexByAssetID[assetID] {
            let projectedRatio = optimisticEdits[assetID]
                .flatMap { UIImage(data: $0.imageData) }
                .flatMap { image -> Double? in
                    guard image.size.height > 0 else { return nil }
                    return Double(image.size.width / image.size.height)
                }
            let committedRatio = projectedRatio
                ?? detail?.asAsset().ratio
                ?? assets[index].ratio
            assets[index].ratio = committedRatio
            measuredAspectRatios[assetID] = committedRatio
        }
        optimisticEdits.removeValue(forKey: assetID)
        apply(.edited(assetID, thumbhash: detail?.thumbhash))
        toast = String(localized: "Edits saved")
    }

    /// a trim has no local render to show meanwhile, so the page reloads the
    /// video once the server encoded it.
    private func commitTrim(assetID: String, detail: AssetDetail?) {
        playback.reload(assetID: assetID)
        apply(.edited(assetID, thumbhash: detail?.thumbhash, duration: detail?.duration))
        toast = String(localized: "Edits saved")
    }

    private func toggleFavorite() async {
        guard let client = session.client, let asset = current else { return }
        guard mutatingAssetIDs.insert(asset.id).inserted else { return }
        defer { mutatingAssetIDs.remove(asset.id) }
        let newValue = !asset.isFavorite
        apply(.favorite(asset.id, newValue))
        do {
            let result = try await session.setFavorite(asset, value: newValue)
            guard session.client === client else { return }
            apply(.favoriteCommitted(asset.id, newValue))
            if result.storageFailed {
                toast = newValue
                    ? String(localized: "Added to Favorites on this device. Cloud sync couldn't be queued.")
                    : String(localized: "Removed from Favorites on this device. Cloud sync couldn't be queued.")
            } else if result.syncPending {
                toast = newValue
                    ? String(localized: "Added to Favorites. Cloud sync is pending.")
                    : String(localized: "Removed from Favorites. Cloud sync is pending.")
            }
        } catch {
            guard session.client === client else { return }
            apply(.favorite(asset.id, asset.isFavorite))
            ErrorToastCenter.shared.show(String(localized: "Couldn't update the favorite"), error: error)
        }
    }

    private func commitLocalEdit(assetID: String) {
        if let index = indexByAssetID[assetID] {
            assets[index].localImageVersion = UUID().uuidString
            if let id = assets[index].localIdentifier,
               let photo = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
                assets[index].isEdited = PHAssetResource.assetResources(for: photo).contains { $0.type == .adjustmentData }
            }
        }
        LocalImageLoader.shared.noteLibraryChange()
        session.realtime?.notifyLocalChange()
        toast = String(localized: "Edits saved")
    }

    private func toggleArchive() async {
        guard let client = session.client, let asset = current else { return }
        guard mutatingAssetIDs.insert(asset.id).inserted else { return }
        defer { mutatingAssetIDs.remove(asset.id) }
        let visibility: AssetVisibility = asset.visibility == .archive ? .timeline : .archive
        beginOptimisticRemoval(asset)
        do {
            try await client.setVisibility(ids: [asset.id], visibility)
            commitOptimisticRemoval(asset.id)
        } catch {
            rollbackOptimisticRemoval(asset.id)
            ErrorToastCenter.shared.show(String(localized: "Couldn't update the archive"), error: error)
        }
    }

    /// device first, like deleteEverywhere: the folder would otherwise keep
    /// showing through the device copy in the merged grid, and a declined
    /// system dialog leaves the server untouched.
    private func moveToLockedFolder() async {
        guard let client = session.client, let asset = current, let serverAssetID else { return }
        guard mutatingAssetIDs.insert(asset.id).inserted else { return }
        defer { mutatingAssetIDs.remove(asset.id) }
        let localID = await resolveLocalIdentifier()
        guard current?.id == asset.id, client.context.isActive else { return }
        if let localID {
            do {
                guard let backup = session.backup else { throw CleanupVerificationError.changed }
                let outcome = try await deviceCopyRemoval.remove(localIDs: [localID], backup: backup)
                guard outcome.deletedIDs == [localID] else { throw CleanupVerificationError.changed }
            } catch {
                if !(error is CancellationError) && !PhotoLibraryService.isUserCancelled(error) {
                    ErrorToastCenter.shared.show(String(localized: "Couldn't delete from this device"), error: error)
                }
                return
            }
            if current?.id == asset.id { localIdentifier = nil }
        }
        guard client.context.isActive else { return }
        beginOptimisticRemoval(asset)
        do {
            try await client.setVisibility(ids: [serverAssetID], .locked)
            commitOptimisticRemoval(asset.id)
        } catch {
            rollbackOptimisticRemoval(asset.id)
            if localID != nil { onChange(.localDeleted(asset.id)) }
            ErrorToastCenter.shared.show(
                localID == nil
                    ? String(localized: "Couldn't move to the locked folder")
                    : String(localized: "Deleted from this device, but couldn't move to the locked folder"),
                error: error
            )
        }
    }

    private func removeFromLockedFolder() async {
        guard let client = session.client, let asset = current, let serverAssetID else { return }
        guard mutatingAssetIDs.insert(asset.id).inserted else { return }
        defer { mutatingAssetIDs.remove(asset.id) }
        beginOptimisticRemoval(asset)
        do {
            try await client.setVisibility(ids: [serverAssetID], .timeline)
            commitOptimisticRemoval(asset.id)
        } catch {
            rollbackOptimisticRemoval(asset.id)
            ErrorToastCenter.shared.show(String(localized: "Couldn't remove from the locked folder"), error: error)
        }
    }

    /// makes this photo the person's portrait. the server picks their face out
    /// of it and re-renders the thumbnail in a job, announcing it over the
    /// socket - which is what refreshes the avatars, not this call returning.
    private func setFeaturedPhoto() async {
        guard let client = session.client, let personID, let asset = current else { return }
        guard mutatingAssetIDs.insert(asset.id).inserted else { return }
        defer { mutatingAssetIDs.remove(asset.id) }
        do {
            try await client.updatePerson(id: personID, featureFaceAssetID: asset.id)
            toast = String(localized: "Featured photo updated")
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't set the featured photo"), error: error)
        }
    }

    /// the album screen projects the cover and reports the failure, so only
    /// the success is echoed here, where the album screen is covered.
    private func setAlbumCover() async {
        guard let onSetAlbumCover, let asset = current else { return }
        guard mutatingAssetIDs.insert(asset.id).inserted else { return }
        defer { mutatingAssetIDs.remove(asset.id) }
        if await onSetAlbumCover(asset.id) {
            toast = String(localized: "Album cover updated")
        }
    }

    /// takes the photo out of the album only - it stays in the library, which
    /// is why this needs no confirmation, matching the official mobile client.
    private func removeFromAlbum() async {
        guard let client = session.client, let album, let asset = current else { return }
        guard mutatingAssetIDs.insert(asset.id).inserted else { return }
        defer { mutatingAssetIDs.remove(asset.id) }
        onChange(.albumMembershipProjected(asset.id))
        beginOptimisticRemoval(asset)
        do {
            let results = try await client.removeAssets(albumID: album.id, ids: [asset.id])
            guard results.first(where: { $0.id == asset.id })?.success == true else {
                rollbackOptimisticRemoval(asset.id)
                onChange(.albumMembershipReverted(asset.id))
                ErrorToastCenter.shared.show(String(localized: "Couldn't remove this photo from the album. The change was undone."))
                return
            }
            commitOptimisticRemoval(asset.id)
            onChange(.albumMembershipCommitted(asset.id))
            toast = String(localized: "Removed from the album")
        } catch {
            rollbackOptimisticRemoval(asset.id)
            onChange(.albumMembershipReverted(asset.id))
            ErrorToastCenter.shared.show(String(localized: "Couldn't remove this photo from the album"), error: error)
        }
    }

    private func restore() async {
        guard let client = session.client, let asset = current else { return }
        guard mutatingAssetIDs.insert(asset.id).inserted else { return }
        defer { mutatingAssetIDs.remove(asset.id) }
        beginOptimisticRemoval(asset)
        do {
            try await client.restoreAssets(ids: [asset.id])
            commitOptimisticRemoval(asset.id)
        } catch {
            rollbackOptimisticRemoval(asset.id)
            ErrorToastCenter.shared.show(String(localized: "Couldn't restore this photo"), error: error)
        }
    }

    private func trash() async {
        guard let asset = current else { return }
        guard let serverAssetID else {
            await deleteLocalOnlyAsset()
            return
        }
        guard let client = session.client else { return }
        guard mutatingAssetIDs.insert(asset.id).inserted else { return }
        defer { mutatingAssetIDs.remove(asset.id) }
        if let localID = await resolveLocalIdentifier() {
            await deleteEverywhere(
                serverID: serverAssetID,
                sourceAssetID: asset.id,
                localIdentifier: localID,
                force: false
            )
            return
        }
        beginOptimisticRemoval(asset)
        do {
            try await client.trashAssets(ids: [serverAssetID])
            commitOptimisticRemoval(asset.id)
        } catch {
            rollbackOptimisticRemoval(asset.id)
            ErrorToastCenter.shared.show(String(localized: "Couldn't move this photo to trash"), error: error)
        }
    }

    private func deletePermanently() async {
        guard let client = session.client, let asset = current, let serverAssetID else { return }
        guard mutatingAssetIDs.insert(asset.id).inserted else { return }
        defer { mutatingAssetIDs.remove(asset.id) }
        if let localID = await resolveLocalIdentifier() {
            await deleteEverywhere(
                serverID: serverAssetID,
                sourceAssetID: asset.id,
                localIdentifier: localID,
                force: true
            )
            return
        }
        beginOptimisticRemoval(asset)
        do {
            try await client.trashAssets(ids: [serverAssetID], force: true)
            commitOptimisticRemoval(asset.id)
        } catch {
            rollbackOptimisticRemoval(asset.id)
            ErrorToastCenter.shared.show(String(localized: "Couldn't delete this photo"), error: error)
        }
    }

    /// the background lookup may still be in flight right after paging, and
    /// missing it would leave an orphaned copy on the device.
    private func resolveLocalIdentifier() async -> String? {
        if let localIdentifier { return localIdentifier }
        guard let asset = current else { return nil }
        if let localID = asset.localIdentifier {
            localIdentifier = localID
            return localID
        }
        guard let backup = session.backup else { return nil }
        let resolved = await backup.localIdentifier(forRemote: asset.id)
        if current?.id == asset.id { localIdentifier = resolved }
        return resolved
    }

    /// device first: declining the system dialog aborts with nothing changed.
    /// after the device copy is gone the index is updated immediately, even if
    /// the server call then fails.
    private func deleteEverywhere(
        serverID: String,
        sourceAssetID: String,
        localIdentifier: String,
        force: Bool
    ) async {
        guard let client = session.client,
              let removedAsset = assets.first(where: { $0.id == sourceAssetID })
        else { return }
        do {
            try await PhotoLibraryService.delete(localIdentifiers: [localIdentifier])
        } catch {
            if !PhotoLibraryService.isUserCancelled(error) {
                ErrorToastCenter.shared.show(String(localized: "Couldn't delete from this device"), error: error)
            }
            return
        }
        session.backup?.noteLocalDeletion([localIdentifier])
        self.localIdentifier = nil
        beginOptimisticRemoval(removedAsset)
        do {
            try await client.trashAssets(ids: [serverID], force: force)
            commitOptimisticRemoval(sourceAssetID)
        } catch {
            rollbackOptimisticRemoval(sourceAssetID)
            onChange(.localDeleted(sourceAssetID))
            ErrorToastCenter.shared.show(
                String(localized: "Deleted from this device, but couldn't delete the server copy"),
                error: error
            )
        }
    }

    /// removes a device-only asset that has no server copy yet.
    private func deleteLocalOnlyAsset() async {
        guard let asset = current, let localId = asset.localIdentifier else { return }
        do {
            try await PhotoLibraryService.delete(localIdentifiers: [localId])
        } catch {
            if !PhotoLibraryService.isUserCancelled(error) {
                ErrorToastCenter.shared.show(String(localized: "Couldn't delete from this device"), error: error)
            }
            return
        }
        session.backup?.noteLocalDeletion([localId])
        onChange(.removed(asset.id))
        removeCurrent()
    }

    /// saves the server original into the photo library; the index pairing is
    /// recorded by the backup manager so the delete options appear right away.
    private func download() async {
        guard let asset = current, let backup = session.backup else { return }
        downloading = true
        defer { downloading = false }
        do {
            let localId = try await backup.download(asset: asset)
            if current?.id == asset.id { localIdentifier = localId }
            toast = String(localized: "Saved to your photo library")
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't download this photo"), error: error)
        }
    }

    private func confirmRebackup(_ confirmation: RebackupConfirmation, backup: BackupManager?) async {
        guard let backup else { return }
        do {
            let remoteID = try await backup.rebackupAfterConfirmation(confirmation)
            guard session.backup === backup, current?.localIdentifier == confirmation.localIdentifier else { return }
            backedUpRemoteID = remoteID
            assets[currentIndex].isLocalBackedUp = true
            toast = String(localized: "Backed up")
        } catch {
            guard session.backup === backup else { return }
            ErrorToastCenter.shared.show(String(localized: "Couldn't back up this photo"), error: error)
        }
    }

    private func backUpCurrent() async {
        guard let asset = current,
              let localID = asset.localIdentifier,
              let backup = session.backup
        else { return }
        do {
            let remoteID = try await backup.backUp(localIdentifier: localID)
            guard current?.id == asset.id else { return }
            backedUpRemoteID = remoteID
            assets[currentIndex].isLocalBackedUp = true
            toast = String(localized: "Backed up")
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't back up this photo"), error: error)
        }
    }

    private func deleteFromDevice() async {
        guard let asset = current else { return }
        guard mutatingAssetIDs.insert(asset.id).inserted else { return }
        defer { mutatingAssetIDs.remove(asset.id) }
        guard let localID = await resolveLocalIdentifier(), current?.id == asset.id else { return }
        // Capture the server relationship before suspension; paging must never
        // redirect the removal or its UI updates to another photo.
        let backup = session.backup
        let resolvedRemoteID = await backup?.remoteIdentifier(forLocal: localID)
        let hasServerCopy = !asset.isLocal || serverAssetID != nil || resolvedRemoteID != nil || asset.isLocalBackedUp
        guard current?.id == asset.id else { return }
        do {
            if hasServerCopy {
                guard let backup else { throw CleanupVerificationError.changed }
                let outcome = try await deviceCopyRemoval.remove(localIDs: [localID], backup: backup)
                guard outcome.deletedIDs == [localID] else { throw CleanupVerificationError.changed }
            } else {
                // The existing confirmation explicitly deletes a local-only
                // photo. There is no retained server copy to verify.
                try await PhotoLibraryService.delete(localIdentifiers: [localID])
                backup?.noteLocalDeletion([localID])
            }
        } catch {
            if !(error is CancellationError) && !PhotoLibraryService.isUserCancelled(error) {
                ErrorToastCenter.shared.show(String(localized: "Couldn't delete from this device"), error: error)
            }
            return
        }
        if current?.id == asset.id { localIdentifier = nil }
        if asset.isLocal {
            onChange(hasServerCopy ? .localDeleted(asset.id) : .removed(asset.id))
            if current?.id == asset.id { removeCurrent() }
            return
        }
        onChange(.localDeleted(asset.id))
    }

    private func openInBrowser() async {
        guard let client = session.client, let serverAssetID else { return }
        let base = await client.serverWebURL()
        openURL(base.appending(path: "photos/\(serverAssetID)"))
    }

    private func beginOptimisticRemoval(_ asset: Asset) {
        guard optimisticRemovals[asset.id] == nil,
              let index = indexByAssetID[asset.id]
        else { return }
        optimisticRemovals[asset.id] = ViewerRemoval(asset: asset, index: index)
        apply(.optimisticRemoval(asset.id))
    }

    private func commitOptimisticRemoval(_ id: String) {
        optimisticRemovals[id] = nil
        onChange(.removalCommitted(id))
    }

    private func rollbackOptimisticRemoval(_ id: String) {
        guard let removal = optimisticRemovals.removeValue(forKey: id) else { return }
        if indexByAssetID[id] == nil {
            assets.insert(removal.asset, at: min(removal.index, assets.count))
            rebuildIndexMap()
            if selectedAssetID == nil || assets.count == 1 {
                currentIndex = min(removal.index, assets.count - 1)
                selectedAssetID = id
            }
        }
        onChange(.removalReverted(id))
    }

    private func removeCurrent() {
        guard assets.indices.contains(currentIndex) else { return }
        let removedIndex = currentIndex
        assets.remove(at: removedIndex)
        rebuildIndexMap()
        let resolution = AssetViewerSelectionResolution.resolve(
            remainingAssetIDs: assets.map(\.id),
            selectedAssetID: selectedAssetID,
            removedIndex: removedIndex
        )
        currentIndex = resolution.index
        selectedAssetID = resolution.assetID
        if resolution.assetID == nil {
            requestDismissal()
        }
    }
}

// MARK: - toast

/// short-lived confirmation banner, photos style: unobtrusive capsule at the
/// top that fades on its own.
struct ToastBanner: View {
    let text: String
    let onDone: () -> Void

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: text) {
                do { try await Task.sleep(for: .seconds(2.2)) } catch { return }
                withAnimation(PhotosMotion.layout) { onDone() }
            }
    }
}

// MARK: - airplay

/// invisible system route picker; bumping `trigger` opens the airplay sheet.
private struct AirPlayRoutePicker: UIViewRepresentable {
    @Binding var trigger: Int

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.alpha = 0.02
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        guard trigger != context.coordinator.lastTrigger else { return }
        context.coordinator.lastTrigger = trigger
        guard trigger > 0 else { return }
        DispatchQueue.main.async {
            for case let button as UIButton in view.subviews {
                button.sendActions(for: .touchUpInside)
                break
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastTrigger = 0
    }
}

// MARK: - pager

/// lazy horizontal pager. lazyhstack only materializes pages near the
/// viewport, so opening and closing the viewer costs o(visible) instead of
/// o(library) like the page style tabview, which froze the zoom transition.
private struct AssetPager: View {
    /// realized pages further than this from the current one give up their
    /// heavy content. lazyhstack never destroys a realized page, so a long
    /// browse session would otherwise pin every decoded bitmap it visited.
    private static let retainRadius = 3

    let assets: [Asset]
    let indexByID: [String: Int]
    @Binding var selection: String?
    let followsCompactScroll: Bool
    let showsChrome: Bool
    let topSafeAreaInset: CGFloat
    let bottomSafeAreaInset: CGFloat
    let mutesVideo: Bool
    let playback: VideoPlayback
    let optimisticEdits: [String: AssetEditProjection]
    let measuredAspectRatios: [String: Double]
    let editCacheKeys: [String: String]
    /// unit centre of each asset's best square crop, where known.
    let bestSquareCenters: [String: CGPoint]
    let isScreenCapture: (Asset) -> Bool
    let stylesInset: Bool
    let openingAssetID: String?
    let launchMediaBridge: AssetViewerLaunchMediaBridge
    let openingMediaSurface: CommittedGridSurface?
    let onBoundImage: (Asset, BoundRemoteImage) -> Void
    let onBoundLocalImage: (Asset, BoundLocalImage) -> Void
    let onLaunchMediaReady: () -> Void
    let allowsDoubleTapZoom: Bool
    let onMediaTap: () -> Void
    let onDoubleTapZoomChanged: (Bool) -> Void
    let onHorizontalInteractionStarted: () -> Void
    let onZoomInteractionStarted: () -> Void
    let onZoomPresentationChanged: (Bool) -> Void
    let onAspectRatioMeasured: (String, UIImage) -> Void
    let onZoomChanged: (String, Bool) -> Void
    private let initialSelection: String?

    /// The physical pager target is intentionally distinct from semantic
    /// selection. A ScrollPosition retains its initial ID until lazy targets
    /// register, while the legacy optional-ID binding could silently remain at
    /// page zero when this pager was nested inside the vertical information
    /// scroll view.
    @State private var position: ScrollPosition
    @State private var visibleAssetID: String?
    @State private var isUserScrolling = false
    @State private var initialPositionResolved = false

    /// a container resize preserves the raw horizontal offset, not the page.
    /// user scrolling degrades the position to that offset, so a rotation
    /// would land misaligned or on a neighbouring asset. the pager pins the
    /// asset it was showing until the new geometry settles.
    @State private var resizeTargetID: String?
    @State private var resizeSettleTask: Task<Void, Never>?

    init(
        assets: [Asset],
        indexByID: [String: Int],
        selection: Binding<String?>,
        followsCompactScroll: Bool,
        showsChrome: Bool,
        topSafeAreaInset: CGFloat,
        bottomSafeAreaInset: CGFloat,
        mutesVideo: Bool,
        playback: VideoPlayback,
        optimisticEdits: [String: AssetEditProjection],
        measuredAspectRatios: [String: Double],
        editCacheKeys: [String: String],
        bestSquareCenters: [String: CGPoint],
        isScreenCapture: @escaping (Asset) -> Bool,
        stylesInset: Bool,
        openingAssetID: String?,
        launchMediaBridge: AssetViewerLaunchMediaBridge,
        openingMediaSurface: CommittedGridSurface?,
        onBoundImage: @escaping (Asset, BoundRemoteImage) -> Void,
        onBoundLocalImage: @escaping (Asset, BoundLocalImage) -> Void,
        onLaunchMediaReady: @escaping () -> Void,
        allowsDoubleTapZoom: Bool,
        onMediaTap: @escaping () -> Void,
        onDoubleTapZoomChanged: @escaping (Bool) -> Void,
        onHorizontalInteractionStarted: @escaping () -> Void,
        onZoomInteractionStarted: @escaping () -> Void,
        onZoomPresentationChanged: @escaping (Bool) -> Void,
        onAspectRatioMeasured: @escaping (String, UIImage) -> Void,
        onZoomChanged: @escaping (String, Bool) -> Void
    ) {
        self.assets = assets
        self.indexByID = indexByID
        _selection = selection
        self.followsCompactScroll = followsCompactScroll
        self.showsChrome = showsChrome
        self.topSafeAreaInset = topSafeAreaInset
        self.bottomSafeAreaInset = bottomSafeAreaInset
        self.mutesVideo = mutesVideo
        self.playback = playback
        self.optimisticEdits = optimisticEdits
        self.measuredAspectRatios = measuredAspectRatios
        self.editCacheKeys = editCacheKeys
        self.bestSquareCenters = bestSquareCenters
        self.isScreenCapture = isScreenCapture
        self.stylesInset = stylesInset
        self.openingAssetID = openingAssetID
        self.launchMediaBridge = launchMediaBridge
        self.openingMediaSurface = openingMediaSurface
        self.onBoundImage = onBoundImage
        self.onBoundLocalImage = onBoundLocalImage
        self.onLaunchMediaReady = onLaunchMediaReady
        self.allowsDoubleTapZoom = allowsDoubleTapZoom
        self.onMediaTap = onMediaTap
        self.onDoubleTapZoomChanged = onDoubleTapZoomChanged
        self.onHorizontalInteractionStarted = onHorizontalInteractionStarted
        self.onZoomInteractionStarted = onZoomInteractionStarted
        self.onZoomPresentationChanged = onZoomPresentationChanged
        self.onAspectRatioMeasured = onAspectRatioMeasured
        self.onZoomChanged = onZoomChanged
        initialSelection = selection.wrappedValue
        if let initialSelection = selection.wrappedValue {
            _position = State(
                initialValue: ScrollPosition(id: initialSelection, anchor: .center)
            )
        } else {
            _position = State(initialValue: ScrollPosition(idType: String.self))
        }
    }

    var body: some View {
        let centreIndex = selection.flatMap { indexByID[$0] }
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(assets) { asset in
                    let presentationAspectRatio = projectedAspectRatio(for: asset)
                    AssetPage(
                        asset: asset,
                        aspectRatio: presentationAspectRatio,
                        isActive: asset.id == selection,
                        isNearby: isNearby(asset.id, centre: centreIndex),
                        mutesVideo: mutesVideo,
                        playback: playback,
                        optimisticEdit: optimisticEdits[asset.id],
                        editCacheKey: editCacheKeys[asset.id],
                        ownsLaunchMedia: AssetViewerOpeningMediaHandoff.showsScrollCoupledPreview(
                            isVisible: true,
                            assetID: asset.id,
                            openingAssetID: openingAssetID
                        ),
                        launchMediaBridge: launchMediaBridge,
                        openingMediaSurface: openingMediaSurface,
                        onBoundImage: { bound in
                            guard asset.id == selection, optimisticEdits[asset.id] == nil else { return }
                            onBoundImage(asset, bound)
                        },
                        onBoundLocalImage: { bound in
                            guard asset.id == selection, optimisticEdits[asset.id] == nil else { return }
                            onBoundLocalImage(asset, bound)
                        },
                        onMediaReady: {
                            guard asset.id == openingAssetID else { return }
                            onLaunchMediaReady()
                        },
                        allowsDoubleTapZoom: allowsDoubleTapZoom && asset.id == selection,
                        onMediaTap: onMediaTap,
                        onDoubleTapZoomChanged: onDoubleTapZoomChanged,
                        onZoomInteractionStarted: onZoomInteractionStarted,
                        onZoomPresentationChanged: onZoomPresentationChanged,
                        onImage: { onAspectRatioMeasured(asset.id, $0) }
                    ) { isZoomed in
                        onZoomChanged(asset.id, isZoomed)
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
                    .modifier(
                        AssetViewerMediaScrollEffect(
                            followsCompactScroll: followsCompactScroll,
                            aspectRatio: presentationAspectRatio,
                            showsChrome: showsChrome,
                            topSafeAreaInset: topSafeAreaInset,
                            bottomSafeAreaInset: bottomSafeAreaInset,
                            isScreenCapture: isScreenCapture(asset),
                            bestSquareCenter: bestSquareCenters[asset.id] ?? CGPoint(x: 0.5, y: 0.5),
                            clipsToMediaFrame: true,
                            stylesInset: stylesInset
                        )
                    )
                    .id(asset.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition($position, anchor: .center)
        .scrollIndicators(.hidden)
        .onScrollPhaseChange { oldPhase, phase, _ in
            isUserScrolling = phase != .idle
            if phase == .idle, let visibleAssetID, selection != visibleAssetID {
                selection = visibleAssetID
            }
            if AssetViewerOpeningMediaHandoff.beginsCompactInteraction(
                isTracking: phase == .tracking,
                isInteracting: phase == .interacting,
                previousWasTracking: oldPhase == .tracking
            ) {
                onHorizontalInteractionStarted()
            }
        }
        .onAppear {
            guard let initialSelection else {
                initialPositionResolved = true
                return
            }
            position.scrollTo(id: initialSelection, anchor: .center)
        }
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.51) { visibleIDs in
            guard let id = visibleIDs.first(where: { indexByID[$0] != nil }) else { return }

            // Ignore a transient page-zero report while the LazyHStack is
            // registering the immutable initial target. Retrying the pending
            // position happens before semantic selection can be overwritten.
            if !initialPositionResolved, id != initialSelection {
                if let initialSelection {
                    position.scrollTo(id: initialSelection, anchor: .center)
                }
                return
            }

            initialPositionResolved = true

            // reports inside a resize settle window describe whichever page
            // the stale offset uncovered. they must not steal selection, only
            // trigger another correction toward the pinned asset.
            if let target = resizeTargetID {
                if indexByID[target] == nil || id == target {
                    resizeTargetID = nil
                } else {
                    position.scrollTo(id: target, anchor: .center)
                    return
                }
            }

            visibleAssetID = id
            if !isUserScrolling, selection != id { selection = id }
        }
        .onChange(of: selection) { _, id in
            guard let id,
                  indexByID[id] != nil,
                  id != visibleAssetID
            else { return }
            // an external selection change mid resize wins over the pin.
            if resizeTargetID != nil { resizeTargetID = id }
            position.scrollTo(id: id, anchor: .center)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.width
        } action: { oldWidth, newWidth in
            guard oldWidth > 0, oldWidth != newWidth,
                  let target = resizeTargetID ?? selection ?? visibleAssetID,
                  indexByID[target] != nil
            else { return }
            resizeTargetID = target
            position.scrollTo(id: target, anchor: .center)
            // paging only aligns on drag release, so a resize needs one more
            // correction with settled metrics. the pin expires on a short
            // timer because a quiet resize never reports the pinned id back -
            // and it must outlive the whole rotation pass, since a heavy page
            // can delay the stale visibility report past any yield-based
            // window and let it steal selection for a frame.
            resizeSettleTask?.cancel()
            resizeSettleTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled else { return }
                if resizeTargetID == target, indexByID[target] != nil {
                    position.scrollTo(id: target, anchor: .center)
                }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                resizeTargetID = nil
            }
        }
    }

    /// unknown ids or an unknown centre stay heavy - a transient map mismatch
    /// must never blank the page on screen.
    private func isNearby(_ id: String, centre: Int?) -> Bool {
        guard let centre, let index = indexByID[id] else { return true }
        return abs(index - centre) <= Self.retainRadius
    }

    private func projectedAspectRatio(for asset: Asset) -> Double {
        if let projection = optimisticEdits[asset.id],
           let image = UIImage(data: projection.imageData),
           image.size.height > 0 {
            return Double(image.size.width / image.size.height)
        }
        return measuredAspectRatios[asset.id] ?? asset.ratio
    }
}

// MARK: - single page

@MainActor
@Observable
final class AssetViewerLaunchMediaBridge {
    var isVisible: Bool

    init(isVisible: Bool) {
        self.isVisible = isVisible
    }
}

struct AssetViewerLaunchMediaModifier: ViewModifier {
    @Environment(SessionStore.self) private var session: SessionStore
    let asset: Asset
    let openingSurface: CommittedGridSurface?
    let ownsLaunchMedia: Bool
    let bridge: AssetViewerLaunchMediaBridge

    func body(content: Content) -> some View {
        let _ = ImageLoadRecovery.shared.generation
        let _ = asset.visibility == .locked ? session.lockedFolder?.publicationGeneration : nil
        ZStack {
            content
            if ownsLaunchMedia, bridge.isVisible, let openingSurface, openingSurface.isCurrent() {
                AssetViewerLaunchMedia(
                    asset: asset,
                    openingImage: openingSurface.image
                )
                .allowsHitTesting(false)
                .transition(.opacity)
                .zIndex(1)
            }
        }
    }
}

private struct AssetViewerLaunchMedia: View {
    let asset: Asset
    let openingImage: UIImage

    var body: some View {
        AssetViewerFittedMedia(aspectRatio: asset.ratio) {
            Image(uiImage: openingImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}

private struct AssetPage: View {
    @Environment(SessionStore.self) private var session
    let asset: Asset
    let aspectRatio: Double
    let isActive: Bool
    /// far pages drop their heavy content - zoom scroll view, hosting
    /// controller and decoded bitmaps - and become an empty frame. the swap
    /// happens well offscreen, and returning rebuilds from the image caches.
    let isNearby: Bool
    let mutesVideo: Bool
    let playback: VideoPlayback
    let optimisticEdit: AssetEditProjection?
    let editCacheKey: String?
    let ownsLaunchMedia: Bool
    let launchMediaBridge: AssetViewerLaunchMediaBridge
    let openingMediaSurface: CommittedGridSurface?
    let onBoundImage: (BoundRemoteImage) -> Void
    let onBoundLocalImage: (BoundLocalImage) -> Void
    let onMediaReady: () -> Void
    let allowsDoubleTapZoom: Bool
    let onMediaTap: () -> Void
    let onDoubleTapZoomChanged: (Bool) -> Void
    let onZoomInteractionStarted: () -> Void
    let onZoomPresentationChanged: (Bool) -> Void
    let onImage: (UIImage) -> Void
    let onZoomChanged: (Bool) -> Void

    /// photokit could not serve the device copy after all; the page falls back
    /// to the server for the rest of its life.
    @State private var localUnavailable = false

    /// full-size pixels already on the device beat a download of the same
    /// photo. the index only pairs assets whose server copy still matches.
    private var deviceIdentifier: String? {
        guard !localUnavailable else { return nil }
        if let localIdentifier = asset.localIdentifier { return localIdentifier }
        guard asset.isEdited != true, asset.visibility != .locked else { return nil }
        return session.backup?.localIdentifierByRemoteId[asset.id]
    }

    private var localGridSurface: CommittedGridSurface? {
        guard ownsLaunchMedia, let surface = openingMediaSurface, let client = session.client,
              let provenance = surface.localProvenance, provenance.localIdentifier == deviceIdentifier,
              surface.key == MediaPresentationCoordinator.gridKey(asset: asset, client: client, pixels: CGFloat(surface.key.pixelBucket)),
              surface.key.isCurrentContent, LocalImageLoader.currentModificationRevision(provenance.localIdentifier) == provenance.modificationRevision
        else { return nil }
        return surface
    }

    private func localScope(pixels: CGFloat) -> String {
        AssetThumbnailSource.localCacheScope(accountKey: session.client?.offlineAccountKey,
            version: asset.localImageVersion ?? asset.thumbhash, pixels: pixels)
    }

    private var remoteGridPixels: CGFloat? {
        guard ownsLaunchMedia, let surface = openingMediaSurface, let client = session.client,
              surface.key == MediaPresentationCoordinator.gridKey(asset: asset, client: client, pixels: CGFloat(surface.key.pixelBucket)),
              surface.key.isCurrentContent else { return nil }
        return CGFloat(surface.key.pixelBucket)
    }

    var body: some View {
        // content mounts with the page, on the lazy stack's schedule - as it
        // scrolls in, not once the pager has settled on it. gating on the
        // selection instead built the hosting controller mid-swipe, which is
        // exactly when a stall shows. kept transparent so the screen backdrop
        // still fades during drag dismiss.
        ZStack {
            Color.clear
            if isNearby {
                pageContent
            }
        }
    }

    @ViewBuilder private var pageContent: some View {
        if let optimisticEdit, let image = UIImage(data: optimisticEdit.imageData) {
            ZoomableScrollView(
                assetID: asset.id,
                contentID: "\(asset.id)#edit-\(optimisticEdit.operationID)",
                isActivePage: isActive,
                allowsDoubleTapZoom: allowsDoubleTapZoom,
                onMediaTap: onMediaTap,
                onDoubleTapZoomChanged: onDoubleTapZoomChanged,
                onZoomInteractionStarted: onZoomInteractionStarted,
                onZoomPresentationChanged: onZoomPresentationChanged,
                onZoomChanged: onZoomChanged
            ) {
                AssetViewerFittedMedia(aspectRatio: aspectRatio) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .onAppear(perform: onMediaReady)
                }
                .modifier(launchMediaModifier)
            }
        } else if asset.isVideo {
            VideoPlayerPage(
                asset: asset,
                aspectRatio: aspectRatio,
                deviceIdentifier: deviceIdentifier,
                isActive: isActive,
                forcesMute: mutesVideo,
                playback: playback,
                onMediaReady: onMediaReady,
                onImage: onImage,
                ownsLaunchMedia: ownsLaunchMedia,
                launchMediaBridge: launchMediaBridge,
                openingMediaSurface: openingMediaSurface,
                posterCacheScope: localScope(pixels: pagePixelSize),
                posterFallbackPixels: deviceIdentifier == nil ? remoteGridPixels : localGridSurface.map { CGFloat($0.key.pixelBucket) },
                posterFallbackScope: localGridSurface.map { localScope(pixels: CGFloat($0.key.pixelBucket)) },
                onBoundImage: onBoundImage,
                onBoundLocalImage: onBoundLocalImage,
                allowsDoubleTapZoom: allowsDoubleTapZoom,
                onMediaTap: onMediaTap,
                onDoubleTapZoomChanged: onDoubleTapZoomChanged,
                onZoomInteractionStarted: onZoomInteractionStarted,
                onZoomPresentationChanged: onZoomPresentationChanged,
                onZoomChanged: onZoomChanged
            )
        } else if asset.isLivePhoto {
            LivePhotoPage(
                asset: asset,
                aspectRatio: aspectRatio,
                deviceIdentifier: deviceIdentifier,
                isActive: isActive,
                forcesMute: mutesVideo,
                playback: playback,
                onMediaReady: onMediaReady,
                onImage: onImage,
                ownsLaunchMedia: ownsLaunchMedia,
                launchMediaBridge: launchMediaBridge,
                openingMediaSurface: openingMediaSurface,
                posterCacheScope: localScope(pixels: pagePixelSize),
                posterFallbackPixels: deviceIdentifier == nil ? remoteGridPixels : localGridSurface.map { CGFloat($0.key.pixelBucket) },
                posterFallbackScope: localGridSurface.map { localScope(pixels: CGFloat($0.key.pixelBucket)) },
                onBoundImage: onBoundImage,
                onBoundLocalImage: onBoundLocalImage,
                allowsDoubleTapZoom: allowsDoubleTapZoom,
                onMediaTap: onMediaTap,
                onDoubleTapZoomChanged: onDoubleTapZoomChanged,
                onZoomInteractionStarted: onZoomInteractionStarted,
                onZoomPresentationChanged: onZoomPresentationChanged,
                onZoomChanged: onZoomChanged
            )
        } else if let localId = deviceIdentifier {
            ZoomableScrollView(
                assetID: asset.id,
                contentID: "\(asset.id)#ratio-\(aspectRatio.bitPattern)",
                isActivePage: isActive,
                allowsDoubleTapZoom: allowsDoubleTapZoom,
                onMediaTap: onMediaTap,
                onDoubleTapZoomChanged: onDoubleTapZoomChanged,
                onZoomInteractionStarted: onZoomInteractionStarted,
                onZoomPresentationChanged: onZoomPresentationChanged,
                onZoomChanged: onZoomChanged
            ) {
                AssetViewerFittedMedia(aspectRatio: aspectRatio) {
                    LocalPhotoImage(
                        localIdentifier: localId,
                        targetPixelSize: pagePixelSize,
                        cacheScope: localScope(pixels: pagePixelSize),
                        fallbackTargetPixelSize: localGridSurface.map { CGFloat($0.key.pixelBucket) },
                        fallbackRequestContentMode: .aspectFit,
                        fallbackCoversTarget: true,
                        fallbackCacheScope: localGridSurface.map { localScope(pixels: CGFloat($0.key.pixelBucket)) },
                        requiresBoundFallback: true,
                        requestContentMode: .aspectFit,
                        contentMode: .fit,
                        expectedAspectRatio: asset.ratio,
                        onUnavailable: { localUnavailable = true },
                        onImage: onImage,
                        onReady: onMediaReady,
                        onBoundImage: onBoundLocalImage
                    )
                }
                .modifier(launchMediaModifier)
            }
        } else if let client = session.client {
            // the thumbhash cache key re-renders the page when edits land.
            let cacheKey = editCacheKey ?? asset.thumbhash
            ZoomableScrollView(
                assetID: asset.id,
                contentID: "\(asset.id)#\(cacheKey ?? "")#ratio-\(aspectRatio.bitPattern)",
                isActivePage: isActive,
                allowsDoubleTapZoom: allowsDoubleTapZoom,
                onMediaTap: onMediaTap,
                onDoubleTapZoomChanged: onDoubleTapZoomChanged,
                onZoomInteractionStarted: onZoomInteractionStarted,
                onZoomPresentationChanged: onZoomPresentationChanged,
                onZoomChanged: onZoomChanged
            ) {
                AssetViewerFittedMedia(aspectRatio: aspectRatio) {
                    RemoteImage(
                        url: client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: cacheKey),
                        targetPixelSize: pagePixelSize,
                        thumbhash: asset.thumbhash,
                        fallbackURL: client.thumbnailURL(assetID: asset.id, cacheKey: cacheKey),
                        fallbackTargetPixelSize: remoteGridPixels ?? 640,
                        contentMode: .fit,
                        onImage: onImage,
                        onReady: onMediaReady,
                        onBoundImage: onBoundImage
                    )
                }
                .modifier(launchMediaModifier)
            }
        }
    }

    private var launchMediaModifier: AssetViewerLaunchMediaModifier {
        AssetViewerLaunchMediaModifier(
            asset: asset,
            openingSurface: openingMediaSurface,
            ownsLaunchMedia: ownsLaunchMedia,
            bridge: launchMediaBridge
        )
    }
}

// MARK: - zoom container

/// rotation resizes the page without going through swiftui updates, so the
/// scroll view watches its own bounds and reports size changes to re-fit the
/// asset. otherwise the stale zoom offset from the previous orientation
/// survives until the page is remounted.
final class AssetZoomScrollView: UIScrollView {
    var onBoundsSizeChanged: (() -> Void)?
    var onHierarchyChanged: (() -> Void)?
    private var lastBoundsSize = CGSize.zero

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        reportHierarchyChange()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportHierarchyChange()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastBoundsSize else { return }
        let hadValidSize = lastBoundsSize != .zero
        lastBoundsSize = bounds.size
        if hadValidSize {
            DispatchQueue.main.async { [weak self] in
                self?.onBoundsSizeChanged?()
            }
        }
    }

    private func reportHierarchyChange() {
        DispatchQueue.main.async { [weak self] in
            self?.onHierarchyChanged?()
        }
    }
}

struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    @Environment(AssetViewerZoomCommandBridge.self) private var zoomCommandBridge

    let assetID: String
    let contentID: String
    let isActivePage: Bool
    let allowsDoubleTapZoom: Bool
    let onMediaTap: () -> Void
    let onDoubleTapZoomChanged: (Bool) -> Void
    let onZoomInteractionStarted: () -> Void
    let onZoomPresentationChanged: (Bool) -> Void
    let onZoomChanged: (Bool) -> Void
    var onLiveHold: ((LiveHoldEvent, Double) -> Void)? = nil
    @ViewBuilder let content: Content

    func makeUIView(context: Context) -> AssetZoomScrollView {
        let scrollView = AssetZoomScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 6
        scrollView.minimumZoomScale = 1
        scrollView.bounces = true
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.isDirectionalLockEnabled = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        // a page at rest fills the frame and has nothing to pan, but its scroll
        // view still claims the touch and only hands it over once it decides it
        // cannot scroll. that hand-off is the lag before a flick pages or a
        // swipe down starts the dismissal, so panning is off until zoomed in.
        scrollView.panGestureRecognizer.isEnabled = false

        let hosted = context.coordinator.hostingController
        hosted.view.backgroundColor = .clear
        hosted.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(hosted.view)
        NSLayoutConstraint.activate([
            hosted.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hosted.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hosted.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hosted.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            hosted.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            hosted.view.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        let coordinator = context.coordinator
        coordinator.scrollView = scrollView
        coordinator.attachCommandBridge(zoomCommandBridge)
        scrollView.onBoundsSizeChanged = { [weak scrollView] in
            guard let scrollView else { return }
            coordinator.resetToFit(scrollView)
        }
        scrollView.onHierarchyChanged = { [weak scrollView, weak coordinator] in
            guard let scrollView, let coordinator else { return }
            coordinator.attachGestureHub(from: scrollView)
        }
        return scrollView
    }

    func updateUIView(_ scrollView: AssetZoomScrollView, context: Context) {
        let wasActivePage = context.coordinator.isActivePage
        context.coordinator.zoomCommandAssetID = assetID
        context.coordinator.isActivePage = isActivePage
        context.coordinator.allowsDoubleTapZoom = allowsDoubleTapZoom
        context.coordinator.onMediaTap = onMediaTap
        context.coordinator.onDoubleTapZoomChanged = onDoubleTapZoomChanged
        context.coordinator.onZoomInteractionStarted = onZoomInteractionStarted
        context.coordinator.onZoomPresentationChanged = onZoomPresentationChanged
        context.coordinator.onZoomChanged = onZoomChanged
        context.coordinator.onLiveHold = onLiveHold
        context.coordinator.attachCommandBridge(zoomCommandBridge)
        if wasActivePage, !isActivePage {
            context.coordinator.resetToFit(scrollView)
        }
        context.coordinator.updateGestureHubActivity()
        context.coordinator.updateCommandBridgeActivity()
        guard context.coordinator.contentID != contentID else { return }
        context.coordinator.contentID = contentID
        context.coordinator.hostingController.rootView = content
        context.coordinator.resetZoomReporting()
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        scrollView.panGestureRecognizer.isEnabled = false
    }

    static func dismantleUIView(_ scrollView: AssetZoomScrollView, coordinator: Coordinator) {
        // dismantle can run while the hosting hierarchy invalidates its
        // attribute graph, where any synchronous swiftui state write
        // re-enters the invalidation and traps on exclusivity. callbacks go
        // inert and the delegate detaches before the mechanical reset.
        coordinator.prepareForDismantle()
        scrollView.delegate = nil
        scrollView.onBoundsSizeChanged = nil
        scrollView.onHierarchyChanged = nil
        coordinator.resetToFit(scrollView)
        coordinator.detachGestureHub()
        coordinator.detachCommandBridge()
        coordinator.hostingController.view.removeFromSuperview()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            contentID: contentID,
            assetID: assetID,
            content: content,
            isActivePage: isActivePage,
            allowsDoubleTapZoom: allowsDoubleTapZoom,
            onMediaTap: onMediaTap,
            onDoubleTapZoomChanged: onDoubleTapZoomChanged,
            onZoomInteractionStarted: onZoomInteractionStarted,
            onZoomPresentationChanged: onZoomPresentationChanged,
            onZoomChanged: onZoomChanged,
            onLiveHold: onLiveHold
        )
    }

    @MainActor
    final class Coordinator: NSObject,
        UIScrollViewDelegate,
        AssetViewerZoomGestureTarget,
        AssetViewerZoomCommandTarget {
        private struct PendingInformationFit {
            let generation: Int
            let contentID: String
            let completion: (Bool) -> Void
        }

        let hostingController: UIHostingController<Content>
        var contentID: String
        var zoomCommandAssetID: String
        var isActivePage: Bool
        var allowsDoubleTapZoom: Bool
        var onMediaTap: () -> Void
        var onDoubleTapZoomChanged: (Bool) -> Void
        var onZoomInteractionStarted: () -> Void
        var onZoomPresentationChanged: (Bool) -> Void
        var onZoomChanged: (Bool) -> Void
        var onLiveHold: ((LiveHoldEvent, Double) -> Void)?
        weak var scrollView: UIScrollView?
        private weak var gestureHub: AssetViewerZoomGestureHub?
        private weak var commandBridge: AssetViewerZoomCommandBridge?
        private var lastReportedZoomed = false
        private var doubleTapTargetZoomed = false
        private var programmaticZoomTarget: AssetViewerDoubleTapZoom.Target?
        private var hasAppliedProgrammaticZoom = false
        private var isApplyingProgrammaticZoom = false
        private var doubleTapActionGeneration = 0
        private var hasScheduledDoubleTap = false
        private var informationFitGeneration = 0
        private var pendingInformationFit: PendingInformationFit?

        init(
            contentID: String,
            assetID: String,
            content: Content,
            isActivePage: Bool,
            allowsDoubleTapZoom: Bool,
            onMediaTap: @escaping () -> Void,
            onDoubleTapZoomChanged: @escaping (Bool) -> Void,
            onZoomInteractionStarted: @escaping () -> Void,
            onZoomPresentationChanged: @escaping (Bool) -> Void,
            onZoomChanged: @escaping (Bool) -> Void,
            onLiveHold: ((LiveHoldEvent, Double) -> Void)? = nil
        ) {
            self.contentID = contentID
            zoomCommandAssetID = assetID
            hostingController = UIHostingController(rootView: content)
            self.isActivePage = isActivePage
            self.allowsDoubleTapZoom = allowsDoubleTapZoom
            self.onMediaTap = onMediaTap
            self.onDoubleTapZoomChanged = onDoubleTapZoomChanged
            self.onZoomInteractionStarted = onZoomInteractionStarted
            self.onZoomPresentationChanged = onZoomPresentationChanged
            self.onZoomChanged = onZoomChanged
            self.onLiveHold = onLiveHold
        }

        func resetZoomReporting() {
            cancelInformationFit(reconcilesZoomState: false)
            cancelPendingDoubleTap(reconcilesZoomState: false)
            lastReportedZoomed = false
            doubleTapTargetZoomed = false
            if isActivePage { onZoomPresentationChanged(false) }
            onZoomChanged(false)
        }

        /// makes every swiftui-facing callback inert ahead of teardown and
        /// resolves a pending information fit on the next tick, so nothing
        /// writes swiftui state while the graph is invalidating.
        func prepareForDismantle() {
            onMediaTap = {}
            onDoubleTapZoomChanged = { _ in }
            onZoomInteractionStarted = {}
            onZoomPresentationChanged = { _ in }
            onZoomChanged = { _ in }
            onLiveHold = nil
            guard let pendingInformationFit else { return }
            self.pendingInformationFit = nil
            informationFitGeneration &+= 1
            DispatchQueue.main.async { pendingInformationFit.completion(false) }
        }

        /// re-fits the asset after the page geometry changed, e.g. rotation.
        /// zooming out through the delegate keeps pan and zoom reporting in
        /// sync; the offset still needs clearing since a min-zoom page never
        /// gets clamped by the scroll view itself while panning is disabled.
        func resetToFit(_ scrollView: UIScrollView) {
            cancelInformationFit(reconcilesZoomState: false)
            cancelPendingDoubleTap(reconcilesZoomState: false)
            if scrollView.zoomScale != scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
            }
            scrollView.contentOffset = .zero
            scrollView.panGestureRecognizer.isEnabled = false
            doubleTapTargetZoomed = false
            lastReportedZoomed = false
            if isActivePage { onZoomPresentationChanged(false) }
            onZoomChanged(false)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostingController.view
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let isZoomed = isZoomed(scrollView)
            scrollView.panGestureRecognizer.isEnabled = isZoomed
                && pendingInformationFit == nil
            if pendingInformationFit != nil { return }
            if let programmaticZoomTarget {
                if hasAppliedProgrammaticZoom,
                   hasReached(programmaticZoomTarget, in: scrollView) {
                    self.programmaticZoomTarget = nil
                    hasAppliedProgrammaticZoom = false
                }
            } else if isZoomed != doubleTapTargetZoomed {
                doubleTapTargetZoomed = isZoomed
                if isActivePage { onZoomPresentationChanged(isZoomed) }
            }
            guard isZoomed != lastReportedZoomed else { return }
            lastReportedZoomed = isZoomed
            onZoomChanged(isZoomed)
        }

        func scrollViewDidEndZooming(
            _ scrollView: UIScrollView,
            with view: UIView?,
            atScale scale: CGFloat
        ) {
            guard pendingInformationFit != nil else { return }
            switch AssetViewerInformationFitEnd.resolution(
                isApplyingProgrammaticZoom: isApplyingProgrammaticZoom,
                isZoomAnimating: scrollView.isZoomAnimating,
                isZoomed: isZoomed(scrollView)
            ) {
            case .ignore:
                break
            case .cancel:
                cancelInformationFit(reconcilesZoomState: true)
            case .complete:
                finishInformationFit(in: scrollView)
            }
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            routeLiveHold(.zoomBegan)
            guard let pinchGesture = scrollView.pinchGestureRecognizer else { return }
            let pinchIsActive = pinchGesture.state == .began || pinchGesture.state == .changed
            if AssetViewerOpeningMediaHandoff.claimsPreviewForPinch(
                isActivePage: isActivePage,
                isApplyingProgrammaticZoom: isApplyingProgrammaticZoom,
                pinchIsActive: pinchIsActive
            ) {
                onZoomInteractionStarted()
            }
            guard !isApplyingProgrammaticZoom, pinchIsActive else { return }
            let hadInformationFit = pendingInformationFit != nil
            let hadProgrammaticZoom = hasScheduledDoubleTap || programmaticZoomTarget != nil
            if hadInformationFit {
                cancelInformationFit(reconcilesZoomState: false)
            }
            cancelPendingDoubleTap(reconcilesZoomState: false)
            let isZoomed = isZoomed(scrollView)
            doubleTapTargetZoomed = isZoomed
            lastReportedZoomed = isZoomed
            if isActivePage {
                if hadInformationFit {
                    onZoomPresentationChanged(isZoomed)
                } else if hadProgrammaticZoom {
                    onDoubleTapZoomChanged(isZoomed)
                } else {
                    onZoomPresentationChanged(isZoomed)
                }
            }
            onZoomChanged(isZoomed)
        }

        func attachGestureHub(from scrollView: UIScrollView) {
            guard scrollView.window != nil,
                  let pagerScrollView = enclosingPagerScrollView(from: scrollView)
            else {
                detachGestureHub()
                return
            }
            let hub = AssetViewerZoomGestureHub.attached(to: pagerScrollView)
            if gestureHub !== hub {
                detachGestureHub()
                gestureHub = hub
            }
            hub.setActive(self, isActive: isActivePage)
        }

        func detachGestureHub() {
            cancelPendingDoubleTap()
            gestureHub?.setActive(self, isActive: false)
            gestureHub = nil
        }

        func updateGestureHubActivity() {
            if !isActivePage { cancelPendingDoubleTap() }
            gestureHub?.setActive(self, isActive: isActivePage)
        }

        func attachCommandBridge(_ bridge: AssetViewerZoomCommandBridge) {
            guard commandBridge !== bridge else { return }
            detachCommandBridge()
            commandBridge = bridge
            bridge.setActive(self, isActive: isActivePage)
        }

        func detachCommandBridge() {
            cancelInformationFit(reconcilesZoomState: false)
            commandBridge?.setActive(self, isActive: false)
            commandBridge = nil
        }

        func updateCommandBridgeActivity() {
            if !isActivePage {
                cancelInformationFit(reconcilesZoomState: false)
            }
            commandBridge?.setActive(self, isActive: isActivePage)
        }

        func routeMediaTap() {
            onMediaTap()
        }

        var supportsLiveHold: Bool {
            guard isActivePage, onLiveHold != nil, let scrollView else { return false }
            return abs(scrollView.zoomScale - scrollView.minimumZoomScale) <= 0.01
        }

        func routeLiveHold(_ event: LiveHoldEvent) {
            guard let scrollView else { return }
            onLiveHold?(event, Double(scrollView.zoomScale / max(0.001, scrollView.minimumZoomScale)))
        }

        func routeDoubleTap(at point: CGPoint, from view: UIView) {
            guard allowsDoubleTapZoom else { return }
            routeLiveHold(.zoomBegan)
            performDoubleTap(at: hostingController.view.convert(point, from: view))
        }

        @discardableResult
        func routeZoomToFit(completion: @escaping (Bool) -> Void) -> Bool {
            guard isActivePage, let scrollView else { return false }
            cancelInformationFit(reconcilesZoomState: false)
            cancelPendingDoubleTap(reconcilesZoomState: false)

            informationFitGeneration &+= 1
            pendingInformationFit = PendingInformationFit(
                generation: informationFitGeneration,
                contentID: contentID,
                completion: completion
            )
            doubleTapTargetZoomed = false
            lastReportedZoomed = false
            scrollView.panGestureRecognizer.isEnabled = false
            onZoomPresentationChanged(false)
            onZoomChanged(false)

            guard isZoomed(scrollView) else {
                finishInformationFit(in: scrollView)
                return true
            }

            let animated = !UIAccessibility.isReduceMotionEnabled
            isApplyingProgrammaticZoom = true
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: animated)
            isApplyingProgrammaticZoom = false
            if !animated || !scrollView.isZoomAnimating {
                finishInformationFit(in: scrollView)
            }
            return true
        }

        func cancelRoutedZoomToFit() {
            guard pendingInformationFit != nil else { return }
            if let scrollView {
                isApplyingProgrammaticZoom = true
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
                isApplyingProgrammaticZoom = false
                scrollView.contentOffset = .zero
                scrollView.panGestureRecognizer.isEnabled = false
            }
            cancelInformationFit(reconcilesZoomState: true)
        }

        private func enclosingPagerScrollView(from scrollView: UIScrollView) -> UIScrollView? {
            var ancestor = scrollView.superview
            while let view = ancestor {
                if let pagerScrollView = view as? UIScrollView {
                    return pagerScrollView
                }
                ancestor = view.superview
            }
            return nil
        }

        private func performDoubleTap(at point: CGPoint) {
            guard let scrollView else { return }
            cancelInformationFit(reconcilesZoomState: true)
            let zoomsIn = !doubleTapTargetZoomed
            let interactionScale = zoomsIn
                ? scrollView.minimumZoomScale
                : max(
                    scrollView.zoomScale,
                    scrollView.minimumZoomScale + AssetViewerDoubleTapZoom.fitTolerance * 2
                )
            let target = AssetViewerDoubleTapZoom.target(
                currentScale: interactionScale,
                minimumScale: scrollView.minimumZoomScale,
                maximumScale: scrollView.maximumZoomScale,
                viewport: scrollView.bounds.size,
                tap: point
            )
            programmaticZoomTarget = target
            hasAppliedProgrammaticZoom = false
            switch target {
            case let .fit(scale):
                doubleTapTargetZoomed = false
                onDoubleTapZoomChanged(false)
                scheduleDoubleTap(.fit(scale: scale), in: scrollView)
            case let .zoom(rect):
                doubleTapTargetZoomed = true
                onDoubleTapZoomChanged(true)
                scheduleDoubleTap(.zoom(rect: rect), in: scrollView)
            }
        }

        private func scheduleDoubleTap(
            _ target: AssetViewerDoubleTapZoom.Target,
            in scrollView: UIScrollView
        ) {
            doubleTapActionGeneration &+= 1
            let generation = doubleTapActionGeneration
            let expectedContentID = contentID
            hasScheduledDoubleTap = true
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self,
                      self.doubleTapActionGeneration == generation
                else { return }
                self.hasScheduledDoubleTap = false
                guard let scrollView,
                      self.contentID == expectedContentID,
                      self.isActivePage,
                      self.scrollView === scrollView
                else {
                    self.reconcileDoubleTapState()
                    return
                }
                let animated = !UIAccessibility.isReduceMotionEnabled
                self.hasAppliedProgrammaticZoom = true
                self.isApplyingProgrammaticZoom = true
                defer { self.isApplyingProgrammaticZoom = false }
                switch target {
                case let .fit(scale):
                    scrollView.setZoomScale(scale, animated: animated)
                case let .zoom(rect):
                    scrollView.zoom(to: rect, animated: animated)
                }
                if self.doubleTapActionGeneration == generation,
                   self.programmaticZoomTarget == target,
                   self.hasReached(target, in: scrollView) {
                    self.programmaticZoomTarget = nil
                    self.hasAppliedProgrammaticZoom = false
                }
            }
        }

        private func cancelPendingDoubleTap(reconcilesZoomState: Bool = true) {
            let hadProgrammaticZoom = hasScheduledDoubleTap || programmaticZoomTarget != nil
            doubleTapActionGeneration &+= 1
            hasScheduledDoubleTap = false
            programmaticZoomTarget = nil
            hasAppliedProgrammaticZoom = false
            if reconcilesZoomState, hadProgrammaticZoom {
                reconcileDoubleTapState()
            }
        }

        private func finishInformationFit(in scrollView: UIScrollView) {
            guard let pendingInformationFit,
                  pendingInformationFit.generation == informationFitGeneration,
                  pendingInformationFit.contentID == contentID,
                  isActivePage,
                  self.scrollView === scrollView,
                  !isZoomed(scrollView)
            else {
                cancelInformationFit(reconcilesZoomState: true)
                return
            }

            self.pendingInformationFit = nil
            informationFitGeneration &+= 1
            scrollView.contentOffset = .zero
            scrollView.panGestureRecognizer.isEnabled = false
            doubleTapTargetZoomed = false
            lastReportedZoomed = false
            onZoomPresentationChanged(false)
            onZoomChanged(false)
            pendingInformationFit.completion(true)
        }

        @discardableResult
        private func cancelInformationFit(
            reconcilesZoomState: Bool
        ) -> Bool {
            guard let pendingInformationFit else { return false }
            self.pendingInformationFit = nil
            informationFitGeneration &+= 1

            if reconcilesZoomState, let scrollView {
                let isZoomed = isZoomed(scrollView)
                doubleTapTargetZoomed = isZoomed
                lastReportedZoomed = isZoomed
                if isActivePage { onZoomPresentationChanged(isZoomed) }
                onZoomChanged(isZoomed)
            }
            pendingInformationFit.completion(false)
            return true
        }

        private func reconcileDoubleTapState() {
            guard let scrollView else { return }
            let isZoomed = isZoomed(scrollView)
            programmaticZoomTarget = nil
            hasAppliedProgrammaticZoom = false
            doubleTapTargetZoomed = isZoomed
            if isActivePage { onDoubleTapZoomChanged(isZoomed) }
            onZoomChanged(isZoomed)
        }

        private func isZoomed(_ scrollView: UIScrollView) -> Bool {
            scrollView.zoomScale
                > scrollView.minimumZoomScale + AssetViewerDoubleTapZoom.fitTolerance
        }

        private func hasReached(
            _ target: AssetViewerDoubleTapZoom.Target,
            in scrollView: UIScrollView
        ) -> Bool {
            let targetScale: CGFloat
            switch target {
            case let .fit(scale):
                targetScale = scale
            case let .zoom(rect):
                guard rect.width > 0, rect.height > 0 else { return true }
                targetScale = min(
                    scrollView.bounds.width / rect.width,
                    scrollView.bounds.height / rect.height
                )
            }
            return abs(scrollView.zoomScale - targetScale)
                <= AssetViewerDoubleTapZoom.fitTolerance
        }

    }
}
