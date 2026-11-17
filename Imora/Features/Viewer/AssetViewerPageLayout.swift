import CoreGraphics

/// One immutable sample of the compact viewer's vertical presentation. Keeping
/// these values together prevents chrome, dismissal, and media positioning
/// from observing different scroll frames during a gesture.
nonisolated struct AssetViewerScrollPresentation: Equatable, Sendable {
    let scrollOffset: CGFloat
    let informationProgress: CGFloat
    let isMediaAtTop: Bool
    let isShowingInformation: Bool
}

/// Where one page draws its media for a scroll sample, in the page's own
/// coordinates. The image is the page's fitted render scaled and moved; the
/// window, when set, is the frame it is cropped to.
nonisolated struct AssetViewerMediaGeometry: Equatable, Sendable {
    let scale: CGFloat
    let offset: CGSize
    let window: CGRect?
    /// photos fades the information with this same layout progress.
    let progress: CGFloat
}

/// Resolves viewer chrome from semantic state in one place. The transport bar
/// has a separate reservation flag so loading, hiding chrome, or opening
/// information never changes a playable asset's vertical viewport mid-
/// transition. Live controls live above the media instead.
nonisolated struct AssetViewerChromePresentation: Equatable, Sendable {
    let mountsTopToolbarItems: Bool
    let showsNavigationBar: Bool
    let showsViewerBottomBar: Bool
    let reservesTransportControls: Bool
    let showsTransportControls: Bool
    let showsCarousel: Bool
    let usesChromeMediaFrame: Bool

    init(
        isCompact: Bool,
        isAtMedia: Bool,
        isInformationPresented: Bool,
        isChromeVisible: Bool,
        isContextPreview: Bool,
        isPlayable: Bool,
        isPlayerReady: Bool,
        isLivePhoto: Bool = false,
        isMediaZoomed: Bool
    ) {
        let canShowChrome = isChromeVisible && !isContextPreview
        let mediaIsUnobstructed = isCompact ? isAtMedia : !isInformationPresented

        // chrome toggles fade the top items in place: the bar stays mounted
        // whenever it structurally could show, and hiding chrome unmounts the
        // items instead of sliding the whole bar away.
        // photos clears the top the moment the media starts leaving, not
        // once the information has settled.
        mountsTopToolbarItems = isChromeVisible && !isContextPreview && mediaIsUnobstructed
        showsNavigationBar = !isContextPreview && (isCompact || !isInformationPresented)
        showsViewerBottomBar = canShowChrome && (isCompact || !isInformationPresented)
        reservesTransportControls = isPlayable && !isLivePhoto && !isContextPreview
        showsTransportControls = reservesTransportControls
            && canShowChrome
            && mediaIsUnobstructed
        showsCarousel = !isContextPreview
            && canShowChrome
            && mediaIsUnobstructed
        usesChromeMediaFrame = canShowChrome && !isMediaZoomed
    }
}

/// Geometry for the compact viewer's single vertical surface. The media page
/// and information content share one scroll offset, so revealing metadata can
/// never leave the asset pinned in a separate strip.
nonisolated struct AssetViewerPageLayout: Equatable, Sendable {
    /// SwiftUI measures fractional sheet detents inside the maximum-detent
    /// region rather than the whole display. Used by the regular-width
    /// floating sheet only.
    static let informationSheetFraction: CGFloat = 0.88

    /// the shortest travel between the media and the information stop, for
    /// media already sitting above the square.
    private static let minimumRevealOffset: CGFloat = 44

    static let topChromeReservation: CGFloat = 72
    /// photos' chrome content guide past the safe area, `contentGuideInsetsForViewSize:`
    /// read live from the one-up chrome on iOS 27.2: under the top bar and
    /// over the thumbnails with the bars, a margin around the home
    /// indicator without them.
    private static func contentGuide(isPortrait: Bool, showsChrome: Bool) -> (top: CGFloat, bottom: CGFloat) {
        guard showsChrome else { return (8, 56) }
        return isPortrait ? (62, 108) : (86, 48)
    }
    static let scrollCommandTolerance: CGFloat = 0.001
    private static let endpointTolerance: CGFloat = 1

    let viewport: CGSize
    let bottomSafeAreaInset: CGFloat
    /// the current asset's resting media frame, which places the information:
    /// photos attaches it under the media and stops when the media has become
    /// the square. nil lays out as if the media filled the page.
    let restingMediaFrame: CGRect?

    init(
        viewport: CGSize,
        bottomSafeAreaInset: CGFloat = 0,
        restingMediaFrame: CGRect? = nil
    ) {
        self.viewport = CGSize(
            width: max(0, viewport.width),
            height: max(0, viewport.height)
        )
        self.bottomSafeAreaInset = max(0, bottomSafeAreaInset)
        self.restingMediaFrame = restingMediaFrame
    }

    var mediaHeight: CGFloat { viewport.height }

    var isPortrait: Bool { viewport.height > viewport.width }

    /// a phone wider than 1.5:1 puts the information beside the media,
    /// `-[PUOneUpViewController _shouldUseSideBySideLayoutForAccessoryView]`.
    var usesSideBySideInformation: Bool {
        viewport.height > 0 && viewport.width / viewport.height > 1.5
    }

    /// the square the media becomes above the information: the full width,
    /// capped to half the height (`squareImageCapToHalfHeight`).
    var squareSide: CGFloat {
        min(viewport.width, viewport.height * 0.5)
    }

    /// side by side, the media keeps the page height and a width of
    /// W - H, or H once the page is wider than 2:1.
    var sideBySideMediaWidth: CGFloat {
        guard viewport.height > 0 else { return viewport.width }
        return viewport.width / viewport.height <= 2
            ? viewport.width - viewport.height
            : viewport.height
    }

    /// page y where the information starts: right under the resting media,
    /// or under the whole page beside it.
    var informationTop: CGFloat {
        if usesSideBySideInformation { return viewport.height }
        return min(viewport.height, restingMediaFrame?.maxY ?? viewport.height)
    }

    var informationRevealOffset: CGFloat {
        if usesSideBySideInformation { return viewport.height }
        return max(Self.minimumRevealOffset, informationTop - squareSide)
    }

    /// Keeps short or loading information states tall enough to reach the
    /// stop without synthesizing a second, nested scroll surface.
    var informationMinimumHeight: CGFloat {
        viewport.height - (informationTop - informationRevealOffset)
    }

    func fittedMediaFrame(aspectRatio sourceAspectRatio: Double) -> CGRect {
        fittedMediaFrame(
            aspectRatio: sourceAspectRatio,
            in: CGRect(origin: .zero, size: viewport)
        )
    }

    /// `-[PUOneUpViewController layout:insetsWhenScaledToFitForItemAtIndexPath:inViewportSize:]`.
    /// media fits the whole page, under the bars. screenshots and screen
    /// recordings fit the chrome's content guide instead, centred in it,
    /// `_scaleToChromeInsetsForAsset:`, with or without the bars.
    func presentationMediaFrame(
        aspectRatio: Double,
        showsChrome: Bool,
        topSafeAreaInset: CGFloat,
        bottomSafeAreaInset: CGFloat,
        isScreenCapture: Bool
    ) -> CGRect {
        let fullFrame = fittedMediaFrame(aspectRatio: aspectRatio)
        guard isScreenCapture else { return fullFrame }
        let guide = Self.contentGuide(isPortrait: isPortrait, showsChrome: showsChrome)
        let minY = max(0, topSafeAreaInset) + guide.top
        let maxY = viewport.height - max(0, bottomSafeAreaInset) - guide.bottom
        guard maxY > minY else { return fullFrame }
        return fittedMediaFrame(
            aspectRatio: aspectRatio,
            in: CGRect(x: 0, y: minY, width: viewport.width, height: maxY - minY)
        )
    }

    /// `PUOneUpTilingLayout _shouldApplyInsetStylingToContentWithRect:indexPath:`:
    /// rounded corners and a hairline once the media no longer reaches the
    /// page's edges.
    func insetsMediaFrame(_ frame: CGRect) -> Bool {
        frame.minX > 0.5 && frame.maxX < viewport.width - 0.5
            && frame.minY > 0.5 && frame.maxY < viewport.height - 0.5
    }

    /// `OneUpScreenshotInsetUtilities.cornerRadius(forAspectRatio:isToolbarVisible:)`,
    /// a device's corners for a screen capture. the phone shows its toolbar
    /// upright only.
    func screenCaptureCornerRadius(aspectRatio: Double) -> CGFloat {
        guard aspectRatio > 0 else { return 0 }
        if isPortrait { return aspectRatio < 1 ? 24 : 0 }
        return aspectRatio < 1 ? 12 : 20
    }

    private func fittedMediaFrame(
        aspectRatio sourceAspectRatio: Double,
        in bounds: CGRect
    ) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let finiteRatio = sourceAspectRatio.isFinite && sourceAspectRatio > 0
            ? CGFloat(sourceAspectRatio)
            : 1
        let aspectRatio = min(100, max(0.01, finiteRatio))
        let boundsRatio = bounds.width / bounds.height
        let size: CGSize
        if aspectRatio >= boundsRatio {
            size = CGSize(width: bounds.width, height: bounds.width / aspectRatio)
        } else {
            size = CGSize(width: bounds.height * aspectRatio, height: bounds.height)
        }
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    func informationProgress(scrollOffset: CGFloat) -> CGFloat {
        guard informationRevealOffset > 0 else { return 0 }
        return min(1, max(0, scrollOffset / informationRevealOffset))
    }

    /// Photos' `_getLayoutRect:...forContentOfItemAtIndexPath:` for one page.
    /// The media frame lerps from its resting fit to the square at the top,
    /// or to the left region side by side, while its bottom follows the
    /// scroll 1:1. The image fills that frame, cropped around the best square
    /// center and clamped inside the image, like `rectForFittingToTarget`.
    func mediaGeometry(
        scrollOffset: CGFloat,
        aspectRatio: Double,
        restingFrame: CGRect,
        bestSquareCenter: CGPoint = CGPoint(x: 0.5, y: 0.5),
        topGuide: CGFloat = 0
    ) -> AssetViewerMediaGeometry {
        let fullFrame = fittedMediaFrame(aspectRatio: aspectRatio)
        let page = CGRect(origin: .zero, size: viewport)
        guard fullFrame.width > 0, fullFrame.height > 0,
              restingFrame.width > 0, restingFrame.height > 0
        else { return AssetViewerMediaGeometry(scale: 1, offset: .zero, window: nil, progress: 0) }
        let s = scrollOffset.isFinite ? scrollOffset : 0
        let resting = restingFrame

        func image(in frame: CGRect, crop: Bool) -> (CGFloat, CGSize) {
            let fill = crop
                ? max(frame.width / resting.width, frame.height / resting.height)
                : frame.width / resting.width
            let size = CGSize(width: resting.width * fill, height: resting.height * fill)
            let unit = CGSize(
                width: min(1, frame.width / size.width),
                height: min(1, frame.height / size.height)
            )
            let origin = CGPoint(
                x: min(1 - unit.width, max(0, bestSquareCenter.x - unit.width / 2)),
                y: min(1 - unit.height, max(0, bestSquareCenter.y - unit.height / 2))
            )
            let rect = CGRect(
                x: frame.minX - origin.x * size.width,
                y: frame.minY - origin.y * size.height,
                width: size.width,
                height: size.height
            )
            return (
                size.width / fullFrame.width,
                CGSize(width: rect.midX - page.midX, height: rect.midY - page.midY)
            )
        }

        // at rest or pulled down, the media sits in its resting fit and
        // rides the scroll with its page.
        guard s > 0 else {
            let (scale, offset) = image(in: resting, crop: false)
            return AssetViewerMediaGeometry(scale: scale, offset: offset, window: nil, progress: 0)
        }

        if usesSideBySideInformation {
            let travel = max(1, resting.maxY - topGuide)
            let progress = min(1, s / travel)
            let regionWidth = sideBySideMediaWidth
            let width = resting.width + (regionWidth - resting.width) * progress
            let height = resting.height + (viewport.height - resting.height) * progress
            let maxX = resting.maxX + (regionWidth - resting.maxX) * progress
            let maxY = resting.maxY + (viewport.height - resting.maxY) * progress
            // the viewer pins the stage while the information scrolls up
            // beside it, so the frame needs no scroll compensation.
            let frame = CGRect(x: maxX - width, y: maxY - height, width: width, height: height)
            let (scale, offset) = image(in: frame, crop: true)
            return AssetViewerMediaGeometry(scale: scale, offset: offset, window: frame, progress: progress)
        }

        let reveal = informationRevealOffset
        let progress = min(1, s / reveal)
        let side = squareSide
        let width = resting.width + (viewport.width - resting.width) * progress
        let height = resting.height + (side - resting.height) * progress
        // the bottom is pinned to the resting bottom in page coordinates,
        // which on screen is the scroll carrying it up 1:1.
        let frame = CGRect(
            x: page.midX - width / 2,
            y: resting.maxY - height,
            width: width,
            height: height
        )
        let (scale, offset) = image(in: frame, crop: true)
        return AssetViewerMediaGeometry(scale: scale, offset: offset, window: frame, progress: progress)
    }

    /// Endpoint state for one scroll sample. The exact endpoints are tolerant
    /// of sub-pixel settling.
    func presentation(scrollOffset: CGFloat) -> AssetViewerScrollPresentation {
        let offset = scrollOffset.isFinite ? max(0, scrollOffset) : 0
        return AssetViewerScrollPresentation(
            scrollOffset: offset,
            informationProgress: informationProgress(scrollOffset: offset),
            isMediaAtTop: offset <= Self.endpointTolerance,
            isShowingInformation: informationRevealOffset > 0
                && offset >= informationRevealOffset - Self.endpointTolerance
        )
    }

    func canonicalEndpointOffset(scrollOffset: CGFloat) -> CGFloat? {
        guard scrollOffset.isFinite else { return nil }
        let offset = max(0, scrollOffset)
        if offset <= Self.endpointTolerance { return 0 }
        if abs(offset - informationRevealOffset) <= Self.endpointTolerance {
            return informationRevealOffset
        }
        return nil
    }

    /// photos hands a drag to its information's own scroll view instead of
    /// the open and close pan when the information is deeper than its stop,
    /// or at the stop with the finger moving up. that scroll view stops,
    /// rubber bands and bounces at the stop, so one fling can never also
    /// close.
    func startsInsideInformation(_ startOffset: CGFloat) -> Bool {
        informationRevealOffset > 0
            && startOffset > informationRevealOffset + Self.endpointTolerance
    }

    func startsAtInformationStop(_ startOffset: CGFloat) -> Bool {
        informationRevealOffset > 0
            && abs(startOffset - informationRevealOffset) <= Self.endpointTolerance
    }

    /// release speed, in points per second, past which a fling too fast for
    /// any drag sample names the direction alone.
    private static let flingVelocity: CGFloat = 50

    /// where photos' open and close pan rests once released: the stop for
    /// a finger last moving up, the media for one last moving down, never
    /// in between. without a direction it keeps whichever side the drag is
    /// on, as `-[PUAccessoryVisibilityInteractionController
    /// _handlePanGestureRecognizer:]` does.
    func landingOffset(
        direction: Int,
        offset: CGFloat,
        velocity: CGFloat
    ) -> CGFloat {
        let reveal = informationRevealOffset
        guard reveal > 0 else { return 0 }
        if direction != 0 { return direction > 0 ? reveal : 0 }
        if abs(velocity) >= Self.flingVelocity { return velocity > 0 ? reveal : 0 }
        return offset > Self.endpointTolerance ? reveal : 0
    }
}
