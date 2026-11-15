import Foundation
import SwiftUI

// MARK: - aspect presets

/// photos' crop aspect ratios, `PUCropAspect`: original, freeform, square,
/// wallpaper, then ratios that a portrait toggle turns upright.
nonisolated enum EditAspect: Hashable, Identifiable {
    case original
    case freeform
    case square
    case wallpaper
    case ratio(Int, Int)

    static let presets: [EditAspect] = [
        .original, .freeform, .square, .wallpaper,
        .ratio(16, 9), .ratio(10, 8), .ratio(7, 5), .ratio(4, 3), .ratio(5, 3), .ratio(3, 2),
    ]

    var id: String { title(isPortrait: false) }

    func title(isPortrait: Bool) -> String {
        switch self {
        case .original: String(localized: "ORIGINAL")
        case .freeform: String(localized: "FREEFORM")
        case .square: String(localized: "SQUARE")
        case .wallpaper: String(localized: "WALLPAPER")
        case .ratio(let long, let short): isPortrait ? "\(short):\(long)" : "\(long):\(short)"
        }
    }

    /// whether the portrait toggle applies.
    var isOrientable: Bool {
        switch self {
        case .freeform, .square: false
        default: true
        }
    }

    /// visual width over height; freeform is nil.
    func ratio(originalAspect: CGFloat, screenAspect: CGFloat, isPortrait: Bool) -> CGFloat? {
        let landscape: CGFloat
        switch self {
        case .freeform: return nil
        case .square: return 1
        case .original: landscape = max(originalAspect, 1 / max(originalAspect, 0.0001))
        case .wallpaper: landscape = max(screenAspect, 1 / max(screenAspect, 0.0001))
        case .ratio(let long, let short): landscape = CGFloat(long) / CGFloat(short)
        }
        return isPortrait ? 1 / landscape : landscape
    }
}

// MARK: - transform composition

/// folds an arbitrary rotate and mirror sequence into the canonical
/// rotation-outermost, vertical-mirror-innermost form the official editor
/// uses, so any stored edit list round-trips into ui state.
nonisolated enum EditTransform {
    struct State: Equatable {
        var rotation = 0.0
        var flipH = false
        var flipV = false
        var crop = CGRect(x: 0, y: 0, width: 1, height: 1)

        var normalizedRotation: Double {
            (rotation.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        }

        var isIdentity: Bool {
            normalizedRotation == 0 && !flipH && !flipV && crop == CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    static func state(from edits: [AssetEdit], originalWidth: Int, originalHeight: Int) -> State {
        var state = State()
        // 2x2 row-major matrix (a b; c d) accumulating rotates and mirrors.
        var a = 1.0, b = 0.0, c = 0.0, d = 1.0

        for edit in edits {
            switch edit {
            case .crop(let x, let y, let width, let height):
                guard originalWidth > 0, originalHeight > 0 else { break }
                state.crop = CGRect(
                    x: Double(x) / Double(originalWidth),
                    y: Double(y) / Double(originalHeight),
                    width: Double(width) / Double(originalWidth),
                    height: Double(height) / Double(originalHeight)
                )
            case .rotate(let angle):
                let radians = angle * .pi / 180
                multiplyLeft(cos(radians), -sin(radians), sin(radians), cos(radians), into: &a, &b, &c, &d)
            case .mirror(let axis):
                if axis == "horizontal" {
                    multiplyLeft(-1, 0, 0, 1, into: &a, &b, &c, &d)
                } else {
                    multiplyLeft(1, 0, 0, -1, into: &a, &b, &c, &d)
                }
            case .other:
                break
            }
        }

        // both canonical forms - r(θ) and r(θ)·mirrorV - carry a = cos θ and
        // c = sin θ, so one atan2 recovers the angle with its sign. acos or
        // asin alone would fold 190° back to 170° and mirror a straighten
        // made in another client.
        let epsilon = 1e-6
        let rotation = atan2(c, a) * 180 / .pi
        state.rotation = rotation < 0 ? 360 + rotation : rotation
        state.flipV = abs(a) < epsilon ? abs(b - c) < epsilon : abs(a + d) < epsilon
        return state
    }

    /// canonical wire order: crop, mirror horizontal, mirror vertical, rotate.
    /// a non-positive original size means the true pixel dimensions are
    /// unknown, and a crop expressed in the wrong space would cut the picture
    /// somewhere else entirely - emit the orientation edits only.
    static func edits(from state: State, originalWidth: Int, originalHeight: Int) -> [AssetEdit] {
        var edits: [AssetEdit] = []

        if originalWidth > 0, originalHeight > 0 {
            // both edges are clamped first and the size derived from them, so
            // a rect that drifted outside the unit square shrinks instead of
            // keeping a width its clamped origin can no longer support.
            let x = clampPixel(state.crop.minX, span: originalWidth)
            let y = clampPixel(state.crop.minY, span: originalHeight)
            let width = clampPixel(state.crop.maxX, span: originalWidth) - x
            let height = clampPixel(state.crop.maxY, span: originalHeight) - y
            if width > 0, height > 0, width != originalWidth || height != originalHeight {
                edits.append(.crop(x: x, y: y, width: width, height: height))
            }
        }

        if state.flipH { edits.append(.mirror(axis: "horizontal")) }
        if state.flipV { edits.append(.mirror(axis: "vertical")) }

        let rotation = state.normalizedRotation
        if rotation != 0 { edits.append(.rotate(angle: rotation)) }

        return edits
    }

    private static func clampPixel(_ fraction: CGFloat, span: Int) -> Int {
        max(0, min(Int((fraction * CGFloat(span)).rounded(.towardZero)), span))
    }

    /// left-multiplies the accumulator: total = edit x total.
    private static func multiplyLeft(
        _ ea: Double, _ eb: Double, _ ec: Double, _ ed: Double,
        into a: inout Double, _ b: inout Double, _ c: inout Double, _ d: inout Double
    ) {
        let na = ea * a + eb * c
        let nb = ea * b + eb * d
        let nc = ec * a + ed * c
        let nd = ec * b + ed * d
        a = na; b = nb; c = nc; d = nd
    }
}

// MARK: - editor screen

/// how the editor closed. a save whose follow-up refresh failed still counts
/// as saved - it only lacks the new thumbhash.
nonisolated enum AssetEditOutcome {
    case cancelled
    case saved(AssetDetail?)
}

/// A local render that lets the viewer show the accepted edit intent while
/// the server replaces its derivative files.
nonisolated struct AssetEditProjection: Equatable, Sendable {
    let operationID: UUID
    let assetID: String
    let imageData: Data
}

nonisolated enum AssetEditPreviewRenderer {
    @concurrent
    static func projection(_ image: UIImage, state: EditTransform.State, adjust: ImageAdjust) async -> Data? {
        guard let adjusted = ImageAdjustRenderer.render(image, adjust: adjust) else { return nil }
        return render(adjusted, state: state)
    }
    @concurrent
    static func preview(_ image: UIImage, state: EditTransform.State, photo: PhotoAdjust) async -> UIImage? {
        guard let geometry = renderImage(image, state: state) else { return nil }
        return ImageAdjustRenderer.render(geometry, photo: photo)
    }
    @concurrent
    static func projection(_ image: UIImage, state: EditTransform.State, photo: PhotoAdjust) async -> Data? {
        await preview(image, state: state, photo: photo)?.pngData()
    }
    static func render(_ image: UIImage, state: EditTransform.State) -> Data? {
        renderImage(image, state: state)?.pngData()
    }
    static func renderImage(_ image: UIImage, state: EditTransform.State) -> UIImage? {
        if state.isIdentity && image.imageOrientation == .up { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let uprightSize = CGSize(
            width: max(image.size.width * image.scale, 1),
            height: max(image.size.height * image.scale, 1)
        )
        let upright = UIGraphicsImageRenderer(size: uprightSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: uprightSize))
        }
        guard let source = upright.cgImage else { return nil }

        let crop = state.crop.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let x0 = floor(crop.minX * CGFloat(source.width) + 0.000_000_1)
        let y0 = floor(crop.minY * CGFloat(source.height) + 0.000_000_1)
        let x1 = floor(crop.maxX * CGFloat(source.width) + 0.000_000_1)
        let y1 = floor(crop.maxY * CGFloat(source.height) + 0.000_000_1)
        let pixelCrop = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        guard pixelCrop.width > 0, pixelCrop.height > 0,
              let cropped = source.cropping(to: pixelCrop)
        else { return nil }

        let input = UIImage(cgImage: cropped)
        let radians = CGFloat(state.normalizedRotation * .pi / 180)
        let rawCosine = abs(cos(radians))
        let rawSine = abs(sin(radians))
        let cosine: CGFloat = rawCosine < 0.000_001 ? 0 : rawCosine
        let sine: CGFloat = rawSine < 0.000_001 ? 0 : rawSine
        let outputSize = CGSize(
            width: max(input.size.width * cosine + input.size.height * sine, 1),
            height: max(input.size.width * sine + input.size.height * cosine, 1)
        )
        let rendered = UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: outputSize.width / 2, y: outputSize.height / 2)
            cg.rotate(by: radians)
            cg.scaleBy(x: state.flipH ? -1 : 1, y: state.flipV ? -1 : 1)
            input.draw(in: CGRect(
                x: -input.size.width / 2,
                y: -input.size.height / 2,
                width: input.size.width,
                height: input.size.height
            ))
        }
        return rendered
    }
}

/// the photo editor's tabs, `PUAdjustmentsToolController` and
/// `PUCropToolController`. adjust only shows where the server serves it.
private enum EditTool: Hashable {
    case adjust
    case crop
}

/// photos' adjustments the servers can store: gallery's exposure, contrast
/// and saturation, each -100...100, and its invert, a toggle like photos'
/// auto that has no slider.
private enum AdjustTool: CaseIterable, Hashable {
    case exposure
    case contrast
    case saturation
    case invert
    case highlights, shadows, brightness, blackPoint, warmth, tint

    var title: String {
        switch self {
        case .exposure: String(localized: "Exposure")
        case .contrast: String(localized: "Contrast")
        case .saturation: String(localized: "Saturation")
        case .invert: String(localized: "Invert")
        case .highlights: String(localized: "Highlights")
        case .shadows: String(localized: "Shadows")
        case .brightness: String(localized: "Brightness")
        case .blackPoint: String(localized: "Black Point")
        case .warmth: String(localized: "Warmth")
        case .tint: String(localized: "Tint")
        }
    }

    var systemImage: String {
        switch self {
        case .exposure: "plusminus.circle"
        case .contrast: "circle.lefthalf.filled"
        case .saturation: "drop.halffull"
        case .invert: "circle.righthalf.filled.inverse"
        case .highlights: "sun.max"
        case .shadows: "moon"
        case .brightness: "sun.min"
        case .blackPoint: "circle.fill"
        case .warmth: "thermometer.medium"
        case .tint: "drop"
        }
    }

    var hasSlider: Bool { self != .invert }

    /// the slider's -1...1 over the stored -100...100.
    func value(in adjust: PhotoAdjust) -> Double {
        switch self {
        case .exposure: adjust.exposure / 100
        case .contrast: adjust.contrast / 100
        case .saturation: adjust.saturation / 100
        case .invert: adjust.invert ? 1 : 0
        case .highlights: adjust.highlights / 100
        case .shadows: adjust.shadows / 100
        case .brightness: adjust.brightness / 100
        case .blackPoint: adjust.blackPoint / 100
        case .warmth: adjust.warmth / 100
        case .tint: adjust.tint / 100
        }
    }

    func set(_ value: Double, in adjust: inout PhotoAdjust) {
        let amount = (value * 100).rounded()
        switch self {
        case .exposure: adjust.exposure = amount
        case .contrast: adjust.contrast = amount
        case .saturation: adjust.saturation = amount
        case .invert: adjust.invert = value != 0
        case .highlights: adjust.highlights = amount
        case .shadows: adjust.shadows = amount
        case .brightness: adjust.brightness = amount
        case .blackPoint: adjust.blackPoint = amount
        case .warmth: adjust.warmth = amount
        case .tint: adjust.tint = amount
        }
    }
}

/// everything undo and redo step through.
private struct EditSnapshot: Equatable {
    var state: EditTransform.State
    var adjust: PhotoAdjust
    var disabledTools: Set<AdjustTool>
    var aspect: EditAspect
    var isPortrait: Bool
    var removesPreservedEdits: Bool
}

/// One editing surface for PhotoKit still images and remote full-list edits.
/// Local originals stay in PhotoKit; remote originals stay on the server.
struct AssetEditScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let asset: Asset
    let localAssetIdentifier: String?
    let onLocalSaved: (String) -> Void
    let onRemoteSaveUnconfirmed: (String) -> Void
    let onProjected: (AssetEditProjection) -> Void
    let onReverted: (UUID) -> Void
    let onCommitted: (UUID, AssetDetail?) -> Void
    let onFinished: (AssetEditOutcome) -> Void

    init(
        asset: Asset,
        localAssetIdentifier: String? = nil,
        onLocalSaved: @escaping (String) -> Void = { _ in },
        onRemoteSaveUnconfirmed: @escaping (String) -> Void = { _ in },
        onProjected: @escaping (AssetEditProjection) -> Void = { _ in },
        onReverted: @escaping (UUID) -> Void = { _ in },
        onCommitted: @escaping (UUID, AssetDetail?) -> Void = { _, _ in },
        onFinished: @escaping (AssetEditOutcome) -> Void
    ) {
        self.asset = asset
        self.localAssetIdentifier = localAssetIdentifier
        self.onLocalSaved = onLocalSaved
        self.onRemoteSaveUnconfirmed = onRemoteSaveUnconfirmed
        self.onProjected = onProjected
        self.onReverted = onReverted
        self.onCommitted = onCommitted
        self.onFinished = onFinished
    }

    private enum LoadState {
        case loading
        case failed(String)
        case ready
    }

    @State private var loadState = LoadState.loading
    @State private var image: UIImage?
    @State private var originalWidth = 0
    @State private var originalHeight = 0
    @State private var state = EditTransform.State()
    @State private var initialState = EditTransform.State()
    @State private var hadServerEdits = false
    /// edits the editor has no tool for, sent back as they came.
    @State private var preservedEdits: [AssetEdit] = []
    @State private var aspect = EditAspect.freeform
    @State private var isPortrait = false
    @State private var isSaving = false
    @State private var showsAspectRatios = false
    @State private var showsRevertConfirmation = false
    @State private var removesPreservedEdits = false
    @Namespace private var canvasTransition
    @State private var tool = EditTool.crop
    @State private var adjustTool = AdjustTool.exposure
    /// tools tapped off, which keep their amount but stop applying it.
    @State private var disabledTools: Set<AdjustTool> = []
    @State private var isScrubbing = false
    /// held down on the picture to see it unadjusted.
    @State private var showsOriginal = false
    @GestureState private var holdsOriginal = false
    /// whether this photo can take an adjustment on this server.
    @State private var canAdjust = false
    @State private var adjust = PhotoAdjust.neutral
    @State private var initialAdjust = PhotoAdjust.neutral
    /// the loaded picture with `effectiveAdjust` applied, nil while neutral.
    @State private var adjustedImage: UIImage?
    @State private var cropPreview: UIImage?
    @State private var renderedCropAdjust: PhotoAdjust?
    @State private var localEditor: LocalPhotoEditor?
    @State private var canUseUnifiedEditor = false
    @State private var geometryTool = PhotoGeometryTool.crop
    @State private var saveError: String?
    @State private var legacyRecovery = LegacyPhotoEditRecovery()
    @State private var adjustSource: CGImage?
    @State private var isRenderingAdjust = false
    @State private var undoStack: [EditSnapshot] = []
    @State private var redoStack: [EditSnapshot] = []
    @State private var committed: EditSnapshot?
    @State private var recordTask: Task<Void, Never>?
    @State private var toolFeedback = UISelectionFeedbackGenerator()

    /// what saving applies: the adjustment with switched off tools at zero.
    private var effectiveAdjust: PhotoAdjust {
        var result = adjust
        for tool in disabledTools { tool.set(0, in: &result) }
        return result
    }

    private var hasChanges: Bool {
        legacyRecovery.needsSave(draftChanged: state != initialState || effectiveAdjust != initialAdjust || removesPreservedEdits)
    }
    private var editAnimation: Animation? { reduceMotion ? nil : .smooth(duration: 0.28) }
    private var canUndo: Bool { !undoStack.isEmpty || committed.map { $0 != snapshot } == true }

    private var snapshot: EditSnapshot {
        EditSnapshot(state: state, adjust: adjust, disabledTools: disabledTools, aspect: aspect,
                     isPortrait: isPortrait, removesPreservedEdits: removesPreservedEdits)
    }

    var body: some View {
        if asset.isVideo && localAssetIdentifier == nil {
            VideoTrimEditor(asset: asset, onFinished: onFinished)
        } else {
            photoEditor
        }
    }

    private var photoEditor: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            switch loadState {
            case .loading:
                ProgressView()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Photo", systemImage: "exclamationmark.circle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            case .ready:
                if let image {
                    editorBody(image)
                }
            }

            primaryBar
        }
        .statusBarHidden()
        .interactiveDismissDisabled(hasChanges || isSaving)
        .task { await load() }
        .onChange(of: snapshot) { scheduleRecord() }
        .alert("Couldn't Save Edits", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("Keep Editing", role: .cancel) {}
            Button("Try Again") { beginSave() }
        } message: { Text(saveError ?? "") }
        .onDisappear { recordTask?.cancel() }
        .onChange(of: geometryTool) { showsOriginal = false }
        .onChange(of: tool) { _, _ in
            showsOriginal = false
            showsAspectRatios = false
            isScrubbing = false
            recordCurrentEdit()
        }
    }

    // MARK: - bars

    private var primaryBar: some View {
        EditorPrimaryBar(
            hasChanges: hasChanges,
            isSaving: isSaving,
            onCancel: { finish(.cancelled) },
            onDone: beginSave
        )
    }

    /// undo and redo, or crop's flip and rotate, a title, then crop's aspect
    /// and the more menu.
    private var secondaryBar: some View {
        HStack {
            EditorGlassGroup {
                if tool == .crop {
                    EditorGlassGlyph(systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right", label: String(localized: "Flip"), isEnabled: canCrop) {
                        flip()
                    }
                    EditorGlassGlyph(systemImage: "rotate.left", label: String(localized: "Rotate Left"), isEnabled: canCrop) {
                        rotateLeft()
                    }
                } else {
                    EditorGlassGlyph(systemImage: "arrow.uturn.backward", label: String(localized: "Undo"), isEnabled: canUndo) {
                        undo()
                    }
                    EditorGlassGlyph(systemImage: "arrow.uturn.forward", label: String(localized: "Redo"), isEnabled: !redoStack.isEmpty) {
                        redo()
                    }
                }
            }

            Spacer()

            EditorGlassGroup {
                if tool == .crop {
                    EditorGlassGlyph(systemImage: "aspectratio", label: String(localized: "Aspect Ratio"), isEnabled: canCrop) {
                        withAnimation(editAnimation) { showsAspectRatios.toggle() }
                    }
                    .tint(showsAspectRatios ? EditorAppearance.accent : .primary)
                    .accessibilityIdentifier("edit-aspect-ratio")
                    .accessibilityAddTraits(showsAspectRatios ? .isSelected : [])
                }
                moreMenu
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        // a nav bar title, centred on the screen whatever the groups' widths.
        .overlay { centerTitle }
    }

    @ViewBuilder private var centerTitle: some View {
        switch tool {
        case .adjust:
            EditorBarTitle(text: String(localized: "Adjust"))
        case .crop:
            // photos' auto straighten turns into reset once the crop moves.
            // the servers only rotate by quarter turns, so only reset stays.
            Button {
                recordCurrentEdit()
                withAnimation(editAnimation) {
                    state = EditTransform.State()
                    adjust.straighten = 0; adjust.horizontalPerspective = 0; adjust.verticalPerspective = 0
                    aspect = .freeform
                }
                recordCurrentEdit()
            } label: {
                EditorToolLabel(text: String(localized: "Reset"))
            }
            .buttonStyle(.plain)
            .opacity(state.isIdentity && !adjust.hasWarp && aspect == .freeform ? 0 : 1)
            .disabled(state.isIdentity && !adjust.hasWarp && aspect == .freeform)
            .accessibilityIdentifier("edit-reset")
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Undo", systemImage: "arrow.uturn.backward", action: undo)
                .disabled(!canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward", action: redo)
                .disabled(redoStack.isEmpty)
            Button(showsOriginal ? String(localized: "Show Edits") : String(localized: "Show Original"), systemImage: "photo") {
                showsOriginal.toggle()
            }
            .accessibilityIdentifier("edit-compare-original")
            Button("Revert to Original", systemImage: "arrow.uturn.backward.circle") {
                showsRevertConfirmation = true
            }
            .disabled(!hadServerEdits && initialAdjust.isNeutral && !hasChanges)
        } label: {
            EditorGlassGlyphLabel(systemImage: "ellipsis")
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("More")
        .accessibilityIdentifier("edit-more")
        .confirmationDialog("Revert to Original", isPresented: $showsRevertConfirmation, titleVisibility: .visible) {
            Button("Revert to Original", role: .destructive) {
                recordCurrentEdit()
                withAnimation(editAnimation) {
                    state = EditTransform.State()
                    aspect = .freeform
                    adjust = .neutral
                    disabledTools = []
                    removesPreservedEdits = !preservedEdits.isEmpty
                    showsOriginal = false
                }
                recordCurrentEdit()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - layout

    /// photos' rows on an iphone 15 pro: the glass row fills the top of a
    /// 54pt nav bar under the safe area, the picture fits between that bar
    /// and a 141pt tool container, and the 62pt tab capsule ends 4pt into the
    /// bottom safe area. the tools sit on `EditorToolShadow`.
    private func editorBody(_ image: UIImage) -> some View {
        ZStack {
            if tool == .adjust {
                EditorToolShadow()
                    .transition(.opacity)
            }
            VStack(spacing: 0) {
                secondaryBar
                canvas(image)
                    .padding(.top, 10)
                toolPane
                    .frame(height: 141, alignment: .top)
                EditorTabBar(items: tabItems, selection: $tool)
            }
            .padding(.bottom, -4)
            .editorPrimaryBarRoom()
        }
        .allowsHitTesting(!isSaving)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: tool)
        .onChange(of: effectiveAdjust) { showsOriginal = false; renderAdjust() }
        .onChange(of: state) { if canUseUnifiedEditor { showsOriginal = false; renderAdjust() } }
    }

    private var tabItems: [EditorTabBar<EditTool>.Item] {
        [
            .init(tab: .adjust, title: String(localized: "Adjust"), systemImage: "dial.low", isEnabled: canAdjust),
            .init(tab: .crop, title: String(localized: "Crop"), systemImage: "crop.rotate"),
        ]
    }

    private func canvas(_ image: UIImage) -> some View {
        GeometryReader { proxy in
            let comparingOriginal = showsOriginal || holdsOriginal
            let rendersCompletePreview = comparingOriginal || (canUseUnifiedEditor && (tool == .adjust || geometryTool != .crop))
            let displayedState = comparingOriginal ? EditTransform.State() : state
            let rotated = displayedState.normalizedRotation.truncatingRemainder(dividingBy: 180) != 0
            let available = CGSize(
                width: max(proxy.size.width - 20, 1),
                height: max(proxy.size.height, 1)
            )
            let fitBox = rotated
                ? CGSize(width: available.height, height: available.width)
                : available
            let shown = comparingOriginal ? image : (adjustedImage ?? image)

            Group {
                if rendersCompletePreview {
                    Image(uiImage: comparingOriginal ? image : (adjustedImage ?? image))
                        .resizable()
                        .scaledToFit()
                        .frame(width: available.width, height: available.height)
                        .matchedGeometryEffect(id: "photo", in: canvasTransition)
                } else if tool == .crop {
                    let canvasSize = Self.aspectFit(image.size, into: fitBox)
                    CropCanvas(
                        image: canUseUnifiedEditor ? (cropPreview ?? image) : shown,
                        crop: $state.crop,
                        lockedAspect: canvasAspectRatio,
                        isEnabled: canCrop && !isSaving
                    )
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .matchedGeometryEffect(id: "photo", in: canvasTransition)
                    .transition(.opacity)
                } else {
                    // outside the crop tool photos shows the crop as the
                    // picture itself.
                    let crop = displayedState.crop
                    let cropSize = CGSize(
                        width: image.size.width * crop.width,
                        height: image.size.height * crop.height
                    )
                    let size = Self.aspectFit(cropSize, into: fitBox)
                    let full = CGSize(
                        width: size.width / max(crop.width, 0.0001),
                        height: size.height / max(crop.height, 0.0001)
                    )
                    Image(uiImage: shown)
                        .resizable()
                        .frame(width: full.width, height: full.height)
                        .offset(x: -crop.minX * full.width, y: -crop.minY * full.height)
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .clipped()
                        .matchedGeometryEffect(id: "photo", in: canvasTransition)
                        .transition(.opacity)
                }
            }
            .scaleEffect(x: rendersCompletePreview ? 1 : (displayedState.flipH ? -1 : 1),
                         y: rendersCompletePreview ? 1 : (displayedState.flipV ? -1 : 1))
            .rotationEffect(.degrees(rendersCompletePreview ? 0 : displayedState.rotation))
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .simultaneousGesture(originalComparisonGesture, isEnabled: tool == .adjust || (canUseUnifiedEditor && geometryTool != .crop))
            .overlay(alignment: .top) {
                if comparingOriginal {
                    EditorToolLabel(text: String(localized: "ORIGINAL"))
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var originalComparisonGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.15, maximumDistance: 20)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .exclusively(before: TapGesture())
            .updating($holdsOriginal) { value, held, _ in
                if case .first(.second(true, _)) = value { held = true }
            }
            .onEnded { value in
                if case .second = value { showsOriginal.toggle() }
            }
    }

    @ViewBuilder private var toolPane: some View {
        switch tool {
        case .adjust:
            adjustPane
        case .crop:
            cropPane
        }
    }

    // MARK: - adjust

    /// `PUAdjustmentsViewController` in the 141pt container: the badge hangs
    /// 24pt above it over the picture, the 51pt cells start 28pt down, and
    /// the slider's ticks 10pt under them.
    private var adjustPane: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 20) {
                        ForEach(canUseUnifiedEditor ? AdjustTool.allCases : [.exposure, .contrast, .saturation, .invert], id: \.self) { item in
                            Button {
                                tapTool(item)
                            } label: {
                                EditorToolButton(
                                    systemImage: item.systemImage,
                                    value: item.hasSlider ? item.value(in: adjust) : nil,
                                    isActive: item == .invert && adjust.invert && !disabledTools.contains(item),
                                    isEnabled: !disabledTools.contains(item),
                                    isSelected: item == adjustTool,
                                    showsValue: isScrubbing && item == adjustTool
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.title)
                            .accessibilityAddTraits(item == adjustTool ? .isSelected : [])
                            .id(item)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, max(0, (proxy.size.width - EditorToolButton.size) / 2), for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: Binding(
                    get: { adjustTool },
                    set: { if let next = $0, next != adjustTool { adjustTool = next; toolFeedback.selectionChanged() } }
                ), anchor: .center)
            }
            .frame(height: EditorToolButton.size)
            .padding(.top, 28)

            EditorRuler(
                value: Binding(
                    get: { adjustTool.value(in: adjust) },
                    set: { value in
                        disabledTools.remove(adjustTool)
                        adjustTool.set(value, in: &adjust)
                    }
                ),
                isDimmed: disabledTools.contains(adjustTool)
            ) {
                isScrubbing = $0
                if !$0 { recordCurrentEdit() }
            }
            .padding(.horizontal, 15.5)
            .padding(.top, 10)
            .opacity(adjustTool.hasSlider ? 1 : 0)
            .allowsHitTesting(adjustTool.hasSlider)
            .accessibilityLabel(adjustTool.title)
            .accessibilityIdentifier("edit-adjust-ruler")
            .id(adjustTool)
            .transition(.opacity)
        }
        .overlay(alignment: .top) {
            EditorToolLabel(text: adjustTool.title)
                .id(adjustTool)
                .transition(.opacity)
                .offset(y: -24.33)
                .allowsHitTesting(false)
        }
    }

    /// another tool centres itself. the centred one switches off and on
    /// again, keeping its amount, as `-[PUAdjustmentsViewController didToggleCell:]`
    /// does. invert has no slider, so a tap flips it.
    private func tapTool(_ item: AdjustTool) {
        showsOriginal = false
        guard item == adjustTool else {
            withAnimation(editAnimation) { adjustTool = item }
            return
        }
        recordCurrentEdit()
        if item == .invert {
            disabledTools.remove(item)
            adjust.invert.toggle()
        } else if item.value(in: adjust) != 0 {
            if disabledTools.contains(item) {
                disabledTools.remove(item)
            } else {
                disabledTools.insert(item)
            }
        }
        toolFeedback.selectionChanged()
        recordCurrentEdit()
    }

    // MARK: - crop

    /// photos shows its aspect ratios where the straighten dials sit. the
    /// servers only rotate by quarter turns, so the ratios stay.
    private var cropPane: some View {
        Group {
            if showsAspectRatios {
                aspectRatioPane
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if canUseUnifiedEditor {
                PhotoGeometryControls(selection: $geometryTool, photo: $adjust, onEditingChanged: {
                    isScrubbing = $0
                    if !$0 { recordCurrentEdit() }
                })
                .padding(.top, 12)
            } else {
                // Only tools the server can persist are offered. The aspect
                // tray is revealed by its top-bar control, as in Photos.
                HStack(spacing: 28) {
                    cropAction("rotate.left", title: String(localized: "Rotate Left"), action: rotateLeft)
                    cropAction("arrow.left.and.right.righttriangle.left.righttriangle.right", title: String(localized: "Flip"), action: flip)
                }
                .padding(.top, 28)
                .transition(.opacity)
            }
        }
    }

    private func cropAction(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                EditorToolButton(systemImage: symbol, value: 0)
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canCrop)
        .accessibilityLabel(title)
    }

    private var aspectRatioPane: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                orientationButton(portrait: true)
                orientationButton(portrait: false)
            }
            .opacity(aspect.isOrientable ? 1 : 0.3)
            .disabled(!aspect.isOrientable || !canCrop)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(EditAspect.presets) { choice in
                        Button {
                            selectAspect(choice)
                        } label: {
                            Text(choice.title(isPortrait: isPortrait && choice.isOrientable))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(aspect == choice ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(aspect == choice ? AnyShapeStyle(Color(uiColor: .tertiarySystemFill)) : AnyShapeStyle(.clear), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canCrop)
                        .accessibilityIdentifier("edit-aspect-\(choice.id)")
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.top, 20)
    }

    private func orientationButton(portrait: Bool) -> some View {
        let selected = isPortrait == portrait
        return Button {
            guard isPortrait != portrait else { return }
            recordCurrentEdit()
            withAnimation(editAnimation) {
                isPortrait = portrait
                applyAspect(aspect)
            }
            recordCurrentEdit()
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary), lineWidth: 1.5)
                .frame(width: portrait ? 16 : 24, height: portrait ? 24 : 16)
                .frame(width: 54, height: 34)
                .background(selected ? AnyShapeStyle(Color(uiColor: .tertiarySystemFill)) : AnyShapeStyle(Color(uiColor: .quaternarySystemFill)), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(portrait ? "Portrait" : "Landscape")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func selectAspect(_ choice: EditAspect) {
        recordCurrentEdit()
        if aspect != choice {
            // photos starts a ratio in the photo's own orientation.
            if choice == .wallpaper {
                isPortrait = true
            } else if let image {
                isPortrait = image.size.height > image.size.width
            }
        }
        aspect = choice
        applyAspect(choice)
        recordCurrentEdit()
    }

    private func flip() {
        recordCurrentEdit()
        withAnimation(editAnimation) {
            if state.normalizedRotation.truncatingRemainder(dividingBy: 180) == 0 {
                state.flipH.toggle()
            } else {
                state.flipV.toggle()
            }
        }
        recordCurrentEdit()
    }

    private func rotateLeft() {
        recordCurrentEdit()
        withAnimation(editAnimation) {
            state.rotation -= 90
            isPortrait.toggle()
            reapplyAspect()
        }
        recordCurrentEdit()
    }

    /// aspect the crop must keep in canvas space: the visual pick, inverted
    /// while the canvas is rotated sideways.
    private var canvasAspectRatio: CGFloat? { canvasAspectRatio(for: aspect) }

    private func canvasAspectRatio(for choice: EditAspect) -> CGFloat? {
        guard let image else { return nil }
        let originalAspect = image.size.width / max(image.size.height, 1)
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.size
            ?? CGSize(width: 9, height: 19.5)
        let screenAspect = screen.width / max(screen.height, 1)
        guard let visual = choice.ratio(originalAspect: originalAspect, screenAspect: screenAspect, isPortrait: isPortrait)
        else { return nil }
        let rotated = state.normalizedRotation.truncatingRemainder(dividingBy: 180) != 0
        return rotated ? 1 / visual : visual
    }

    /// largest centered crop with the chosen ratio.
    private func applyAspect(_ choice: EditAspect) {
        guard let ratio = canvasAspectRatio(for: choice), let image else {
            return
        }
        let imageAspect = image.size.width / max(image.size.height, 1)
        var width: CGFloat = 1
        var height: CGFloat = 1
        // normalized space is stretched by the image aspect: a crop with
        // visual ratio r spans w/h = r/imageaspect in normalized units.
        let normalizedRatio = ratio / imageAspect
        if normalizedRatio >= 1 {
            height = 1 / normalizedRatio
        } else {
            width = normalizedRatio
        }
        withAnimation(editAnimation) {
            state.crop = CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
        }
    }

    private func reapplyAspect() {
        guard aspect != .freeform else { return }
        applyAspect(aspect)
    }

    // MARK: - undo

    /// a change lands in the history once it has settled, so a drag is one
    /// step rather than one per frame.
    private func scheduleRecord() {
        recordTask?.cancel()
        if committed.map({ $0 != snapshot }) == true { redoStack.removeAll() }
        recordTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            recordCurrentEdit()
        }
    }

    private func recordCurrentEdit() {
        recordTask?.cancel()
        let current = snapshot
        guard let previous = committed else { committed = current; return }
        guard current != previous else { return }
        undoStack.append(previous)
        redoStack.removeAll()
        committed = current
    }

    private func undo() {
        recordCurrentEdit()
        guard let previous = undoStack.popLast() else { return }
        recordTask?.cancel()
        redoStack.append(snapshot)
        apply(previous)
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        recordTask?.cancel()
        undoStack.append(snapshot)
        apply(next)
    }

    private func apply(_ snapshot: EditSnapshot) {
        committed = snapshot
        withAnimation(editAnimation) {
            state = snapshot.state
            aspect = snapshot.aspect
            isPortrait = snapshot.isPortrait
            adjust = snapshot.adjust
            disabledTools = snapshot.disabledTools
            removesPreservedEdits = snapshot.removesPreservedEdits
        }
    }

    // MARK: - loading and saving

    private func load() async {
        if let id = localAssetIdentifier { await loadLocal(id); return }
        guard let client = session.client else { return }
        loadState = .loading
        do {
            // the editor always starts from the unedited picture and replays
            // stored edits as ui state, like the official clients.
            let url = client.thumbnailURL(assetID: asset.id, size: "preview", edited: false)
            async let imageTask = ImageLoader.shared.image(for: url, targetPixelSize: 2048)
            async let detailTask = client.assetDetail(id: asset.id)
            async let editsTask = client.assetEdits(id: asset.id)
            let unified = session.capabilities.supportsPhotoEditsV1 && asset.livePhotoVideoId == nil
            let offersAdjust = session.capabilities.supportsAdjust && asset.livePhotoVideoId == nil
            async let adjustTask = offersAdjust ? (try? await client.imageAdjust(id: asset.id)) : nil

            let image = try await imageTask
            let detail = try await detailTask
            // saving replaces the whole edit list, so an unreadable one must
            // not be mistaken for an empty one: that would silently drop a
            // crop the asset already carries.
            let edits: [AssetEdit]
            do {
                edits = try await editsTask
            } catch {
                guard detail.isEdited != true else {
                    loadState = .failed(String(localized: "This photo's existing edits could not be loaded."))
                    return
                }
                edits = []
            }

            let (width, height) = Self.resolveOriginalSize(detail: detail, image: image)
            // an existing crop that cannot be placed would be seeded as the
            // full frame and then written back as none, quietly undoing it.
            let hasCrop = edits.contains { if case .crop = $0 { true } else { false } }
            guard width > 0 || !hasCrop else {
                loadState = .failed(String(localized: "This photo's original dimensions are unknown, so its crop can't be edited."))
                return
            }

            self.image = image
            (originalWidth, originalHeight) = (width, height)
            let seeded = EditTransform.state(from: edits, originalWidth: originalWidth, originalHeight: originalHeight)
            state = seeded
            initialState = seeded
            hadServerEdits = !edits.isEmpty
            preservedEdits = edits.filter { $0.isOther && (!unified || !$0.isPhotoAdjustment) }
            let storedPhoto = unified ? try edits.compactMap { try $0.photoAdjust() }.last : nil
            canUseUnifiedEditor = unified && Self.isAdjustable(detail)
            // an adjustment that could not be read stays out of reach rather
            // than being shown, and then saved, as neutral.
            let loadedAdjust = await adjustTask
            canAdjust = canUseUnifiedEditor || (offersAdjust && loadedAdjust != nil && Self.isAdjustable(detail))
            if canAdjust {
                adjustSource = ImageAdjustRenderer.upright(image)
                let seededPhoto = storedPhoto ?? PhotoAdjust(legacy: loadedAdjust ?? .neutral)
                adjust = seededPhoto
                initialAdjust = seededPhoto
                tool = .adjust
                renderAdjust()
            }
            if let image = self.image {
                isPortrait = image.size.height > image.size.width
            }
            committed = snapshot
            loadState = .ready
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    /// crop parameters are pixels in the upright original, so exif is the
    /// source of truth: the asset's own width and height already describe the
    /// EDITED output, and normalizing a stored crop against those would place
    /// it in a space that no longer exists. the asset dims are only a safe
    /// fallback while nothing is applied on top. the exif pair can be
    /// pre-rotation, so trust whichever orientation matches the upright
    /// render. zeros mean unknown - the preview is downsampled, so its own
    /// size would put crops in the wrong space entirely.
    private static func resolveOriginalSize(detail: AssetDetail, image: UIImage) -> (Int, Int) {
        var width = Int(detail.exifInfo?.exifImageWidth ?? 0)
        var height = Int(detail.exifInfo?.exifImageHeight ?? 0)
        if width <= 0 || height <= 0, detail.isEdited != true {
            width = detail.width ?? 0
            height = detail.height ?? 0
        }
        guard width > 0, height > 0 else { return (0, 0) }
        let imageAspect = Double(image.size.width / max(image.size.height, 1))
        let straight = Double(width) / Double(height)
        let swapped = Double(height) / Double(width)
        if abs(imageAspect - swapped) < abs(imageAspect - straight) {
            swap(&width, &height)
        }
        return (width, height)
    }

    /// the server refuses to adjust live photos, panoramas, gifs and svgs.
    private static func isAdjustable(_ detail: AssetDetail) -> Bool {
        guard detail.type == .image, detail.livePhotoVideoId == nil else { return false }
        let name = detail.originalFileName.lowercased()
        let mime = detail.originalMimeType?.lowercased() ?? ""
        return !name.hasSuffix(".insp") && !name.hasSuffix(".gif") && !name.hasSuffix(".svg")
            && mime != "image/gif" && !mime.hasPrefix("image/svg")
    }

    /// one render at a time. sliders move faster than frames land, so the
    /// loop keeps going until the last value it drew is the current one.
    private func loadLocal(_ id: String) async {
        loadState = .loading
        do {
            let editor = try await LocalPhotoEditor.open(localIdentifier: id)
            localEditor = editor; image = editor.preview
            originalWidth = editor.originalWidth; originalHeight = editor.originalHeight
            state = EditTransform.state(from: editor.recipe.edits, originalWidth: originalWidth, originalHeight: originalHeight)
            initialState = state; hadServerEdits = !editor.recipe.edits.isEmpty
            adjust = try editor.recipe.edits.compactMap { try $0.photoAdjust() }.last ?? .neutral
            initialAdjust = adjust
            canUseUnifiedEditor = true; canAdjust = true; tool = .adjust
            adjustSource = ImageAdjustRenderer.upright(editor.preview)
            isPortrait = editor.preview.size.height > editor.preview.size.width
            committed = snapshot; loadState = .ready
            renderAdjust()
        } catch { loadState = .failed(error.localizedDescription) }
    }

    private func renderAdjust() {
        guard !isRenderingAdjust, let source = adjustSource, let image else { return }
        isRenderingAdjust = true
        Task {
            var drawnPhoto: PhotoAdjust?
            var drawnState: EditTransform.State?
            while drawnPhoto != effectiveAdjust || (canUseUnifiedEditor && drawnState != state) {
                let target = effectiveAdjust, targetState = state
                if canUseUnifiedEditor {
                    adjustedImage = await AssetEditPreviewRenderer.preview(image, state: targetState, photo: target)
                    var color = target
                    color.straighten = 0; color.horizontalPerspective = 0; color.verticalPerspective = 0
                    if renderedCropAdjust != color {
                        cropPreview = await AssetEditPreviewRenderer.preview(image, state: EditTransform.State(), photo: color)
                        renderedCropAdjust = color
                    }
                } else {
                    adjustedImage = target.isNeutral ? nil : await ImageAdjustRenderer.preview(source, scale: image.scale, adjust: target.legacy)
                }
                drawnPhoto = target; drawnState = targetState
            }
            isRenderingAdjust = false
        }
    }

    private var canCrop: Bool { originalWidth > 0 && originalHeight > 0 }

    private func beginSave() {
        guard !isSaving, hasChanges, let image else { return }
        guard localEditor != nil || session.client != nil else { return }
        isSaving = true
        let savedState = state, savedAdjust = effectiveAdjust
        var edits = EditTransform.edits(from: savedState, originalWidth: originalWidth, originalHeight: originalHeight)
            + (removesPreservedEdits ? [] : preservedEdits)
        do {
            if canUseUnifiedEditor && !savedAdjust.isNeutral { edits.append(try .photo(savedAdjust)) }
        } catch { isSaving = false; saveError = error.localizedDescription; return }
        let intent = edits
        let renderedState = EditTransform.state(from: intent, originalWidth: originalWidth, originalHeight: originalHeight)
        let unified = canUseUnifiedEditor
        let legacyIntent = legacyRecovery.intent(adjust: savedAdjust.legacy, initialAdjust: initialAdjust.legacy, edits: intent,
            geometryChanged: state != initialState || removesPreservedEdits, hadServerEdits: hadServerEdits, supportsAdjust: canAdjust)
        let operationID = UUID()
        Task {
            var derivativeReady: Task<Void, Never>?
            defer { derivativeReady?.cancel() }
            do {
                if let localEditor {
                    try await localEditor.save(edits: intent)
                    onLocalSaved(localEditor.localIdentifier)
                    isSaving = false
                    finish(.saved(nil))
                    return
                }
                guard let client = session.client else { throw ImoraError.unreachable }
                let rendered: Data?
                if unified { rendered = await AssetEditPreviewRenderer.projection(image, state: renderedState, photo: savedAdjust) }
                else { rendered = await AssetEditPreviewRenderer.projection(image, state: renderedState, adjust: savedAdjust.legacy) }
                guard let preview = rendered else { throw LocalPhotoEditorError.rendering }
                let realtime = session.realtime, assetID = asset.id
                func observeDerivative() -> Task<Void, Never> {
                    Task {
                        _ = await realtime?.waitForAssetEvent(named: ["AssetEditReadyV2", "AssetEditReadyV1"],
                                                              assetID: assetID, timeout: .seconds(10))
                    }
                }
                if unified {
                    derivativeReady = observeDerivative()
                    try await client.savePhotoEdits(id: asset.id, edits: intent)
                } else {
                    try await PhotoEditPersistence.saveLegacy(
                        adjust: legacyIntent.adjust,
                        edits: legacyIntent.edits,
                        writeAdjust: { value in
                            derivativeReady = observeDerivative()
                            if value.isNeutral { try await client.removeImageAdjust(id: assetID) }
                            else { try await client.setImageAdjust(id: assetID, value) }
                            await derivativeReady?.value
                        }, writeEdits: { value in
                            derivativeReady = observeDerivative()
                            if value.isEmpty { try await client.clearEdits(id: assetID) }
                            else { try await client.applyEdits(id: assetID, edits: value) }
                        }, readAdjust: { try await client.imageAdjust(id: assetID) },
                        readEdits: { try await client.assetEdits(id: assetID) })
                }
                // A projection is published only after durable acceptance.
                onProjected(AssetEditProjection(operationID: operationID, assetID: asset.id, imageData: preview))
                await derivativeReady?.value
                let detail = try? await client.assetDetail(id: asset.id)
                onCommitted(operationID, detail)
                legacyRecovery.recordConfirmed()
                isSaving = false
                finish(.saved(detail))
            } catch {
                // No rollback claim: a legacy first write, or a response-lost
                // write, may already be accepted. Preserve every draft field.
                isSaving = false
                if localEditor == nil {
                    if !unified { legacyRecovery.recordUnconfirmed() }
                    onRemoteSaveUnconfirmed(asset.id)
                }
                saveError = error.localizedDescription
            }
        }
    }

    private func finish(_ outcome: AssetEditOutcome) {
        onFinished(outcome)
        dismiss()
    }

    static func aspectFit(_ size: CGSize, into box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

// MARK: - crop canvas

/// fitted image with a draggable crop frame: corner and edge handles, thirds
/// grid, dimmed outside, optional locked aspect. crop is normalized 0...1.
struct CropCanvas: View {
    let image: UIImage
    @Binding var crop: CGRect
    var lockedAspect: CGFloat?
    var isEnabled = true

    private enum DragMode: Equatable {
        case move
        case corner(horizontal: Bool, vertical: Bool)
        case edge(Edge)
    }

    @State private var dragMode: DragMode?
    @State private var dragStartCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// smallest crop side in normalized units.
    private static let minSide: CGFloat = 0.1

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let frame = CGRect(
                x: crop.minX * size.width,
                y: crop.minY * size.height,
                width: crop.width * size.width,
                height: crop.height * size.height
            )

            ZStack {
                Image(uiImage: image)
                    .resizable()

                // `PUCropMaskView`s veil the surround in the background
                // colour at half.
                Rectangle()
                    .fill(Color(uiColor: .systemBackground).opacity(0.5))
                    .mask {
                        Rectangle()
                            .overlay(alignment: .topLeading) {
                                Rectangle()
                                    .frame(width: frame.width, height: frame.height)
                                    .offset(x: frame.minX, y: frame.minY)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                    }

                if isEnabled {
                    cropFrame(frame)
                }
            }
            .contentShape(.rect)
            .gesture(cropGesture(size: size), isEnabled: isEnabled)
        }
    }

    private func cropFrame(_ frame: CGRect) -> some View {
        AnimatedCropFrame(frame: frame, isDragging: dragMode != nil)
    }

    // MARK: - gesture

    private func cropGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragMode == nil {
                    dragStartCrop = crop
                    dragMode = Self.mode(
                        at: value.startLocation,
                        frame: CGRect(
                            x: crop.minX * size.width,
                            y: crop.minY * size.height,
                            width: crop.width * size.width,
                            height: crop.height * size.height
                        )
                    )
                }
                guard let mode = dragMode else { return }
                let delta = CGSize(
                    width: value.translation.width / size.width,
                    height: value.translation.height / size.height
                )
                crop = Self.apply(
                    mode: mode,
                    delta: delta,
                    start: dragStartCrop,
                    aspect: lockedAspect.map { $0 * size.height / size.width }
                )
            }
            .onEnded { _ in
                dragMode = nil
            }
    }

    /// hit zones: corners beat edges beat inside; outside the frame pans
    /// nothing.
    private static func mode(at point: CGPoint, frame: CGRect) -> DragMode? {
        let grip: CGFloat = 28
        let nearLeft = abs(point.x - frame.minX) < grip
        let nearRight = abs(point.x - frame.maxX) < grip
        let nearTop = abs(point.y - frame.minY) < grip
        let nearBottom = abs(point.y - frame.maxY) < grip
        let insideX = point.x > frame.minX - grip && point.x < frame.maxX + grip
        let insideY = point.y > frame.minY - grip && point.y < frame.maxY + grip

        if nearLeft, nearTop { return .corner(horizontal: false, vertical: false) }
        if nearRight, nearTop { return .corner(horizontal: true, vertical: false) }
        if nearLeft, nearBottom { return .corner(horizontal: false, vertical: true) }
        if nearRight, nearBottom { return .corner(horizontal: true, vertical: true) }
        if nearLeft, insideY { return .edge(.leading) }
        if nearRight, insideY { return .edge(.trailing) }
        if nearTop, insideX { return .edge(.top) }
        if nearBottom, insideX { return .edge(.bottom) }
        if frame.contains(point) { return .move }
        return nil
    }

    /// aspect here is normalized-space width over height.
    private static func apply(mode: DragMode, delta: CGSize, start: CGRect, aspect: CGFloat?) -> CGRect {
        var rect = start

        switch mode {
        case .move:
            rect.origin.x = min(max(0, start.minX + delta.width), 1 - start.width)
            rect.origin.y = min(max(0, start.minY + delta.height), 1 - start.height)
            return rect

        case .corner(let isRight, let isBottom):
            var newWidth = start.width + (isRight ? delta.width : -delta.width)
            var newHeight = start.height + (isBottom ? delta.height : -delta.height)
            newWidth = max(minSide, newWidth)
            newHeight = max(minSide, newHeight)

            if let aspect {
                // let the dominant axis lead, derive the other.
                if abs(delta.width) >= abs(delta.height) {
                    newHeight = newWidth / aspect
                } else {
                    newWidth = newHeight * aspect
                }
                if newHeight < minSide {
                    newHeight = minSide
                    newWidth = newHeight * aspect
                }
                if newWidth < minSide {
                    newWidth = minSide
                    newHeight = newWidth / aspect
                }
            }

            // anchor the opposite corner.
            let anchorX = isRight ? start.minX : start.maxX
            let anchorY = isBottom ? start.minY : start.maxY
            var minX = isRight ? anchorX : anchorX - newWidth
            var minY = isBottom ? anchorY : anchorY - newHeight

            // clamp inside the unit square, shrinking if the anchor pins us.
            if minX < 0 { newWidth += minX; minX = 0 }
            if minY < 0 { newHeight += minY; minY = 0 }
            if minX + newWidth > 1 { newWidth = 1 - minX }
            if minY + newHeight > 1 { newHeight = 1 - minY }
            if let aspect {
                let fromWidth = newWidth / aspect
                if fromWidth <= newHeight {
                    newHeight = fromWidth
                } else {
                    newWidth = newHeight * aspect
                }
                if !isRight { minX = anchorX - newWidth }
                if !isBottom { minY = anchorY - newHeight }
            }
            return sanitize(CGRect(x: minX, y: minY, width: newWidth, height: newHeight), aspect: aspect)

        case .edge(let edge):
            switch edge {
            // the far edge is the anchor, so it also caps how far this one can
            // travel. max(0,) keeps that cap valid when the anchor itself sits
            // closer to the origin than the minimum side.
            case .leading:
                let newMinX = min(max(0, start.minX + delta.width), max(0, start.maxX - minSide))
                rect.origin.x = newMinX
                rect.size.width = start.maxX - newMinX
            case .trailing:
                rect.size.width = min(max(minSide, start.width + delta.width), 1 - start.minX)
            case .top:
                let newMinY = min(max(0, start.minY + delta.height), max(0, start.maxY - minSide))
                rect.origin.y = newMinY
                rect.size.height = start.maxY - newMinY
            case .bottom:
                rect.size.height = min(max(minSide, start.height + delta.height), 1 - start.minY)
            }

            if let aspect {
                // edges keep the perpendicular dimension centered.
                switch edge {
                case .leading, .trailing:
                    let newHeight = min(rect.width / aspect, 1)
                    let centerY = start.midY
                    rect.origin.y = min(max(0, centerY - newHeight / 2), max(0, 1 - newHeight))
                    rect.size.height = newHeight
                    rect.size.width = newHeight * aspect
                    if edge == .leading { rect.origin.x = start.maxX - rect.width }
                case .top, .bottom:
                    let newWidth = min(rect.height * aspect, 1)
                    let centerX = start.midX
                    rect.origin.x = min(max(0, centerX - newWidth / 2), max(0, 1 - newWidth))
                    rect.size.width = newWidth
                    rect.size.height = newWidth / aspect
                    if edge == .top { rect.origin.y = start.maxY - rect.height }
                }
            }
            return sanitize(rect, aspect: aspect)
        }
    }

    /// last line of defence for the resize branches: the crop must stay inside
    /// the unit square with usable sides, because the saved pixel rect is
    /// derived from it and a rect poking outside would cut a region the user
    /// never framed.
    private static func sanitize(_ rect: CGRect, aspect: CGFloat?) -> CGRect {
        var width = min(max(rect.width, minSide), 1)
        var height = min(max(rect.height, minSide), 1)

        if let aspect, aspect > 0 {
            // grow the short side back to the locked ratio, then shrink both
            // if that pushed past the unit square.
            height = width / aspect
            if height < minSide {
                height = minSide
                width = height * aspect
            }
            if width > 1 {
                width = 1
                height = width / aspect
            }
            if height > 1 {
                height = 1
                width = height * aspect
            }
            width = min(width, 1)
            height = min(height, 1)
        }

        return CGRect(
            x: min(max(0, rect.minX), 1 - width),
            y: min(max(0, rect.minY), 1 - height),
            width: width,
            height: height
        )
    }
}

/// Paths do not interpolate when an inline Path closure is replaced.
/// Animate the crop rectangle itself so border, grips and grid travel together.
private struct AnimatedCropFrame: View, Animatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var frame: CGRect
    var isDragging: Bool

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(frame.minX, frame.minY), AnimatablePair(frame.width, frame.height)) }
        set { frame = CGRect(x: newValue.first.first, y: newValue.first.second,
                             width: newValue.second.first, height: newValue.second.second) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // photos shows the thirds grid only while the crop moves.
            Path { path in
                for step in 1..<3 {
                    let x = frame.minX + frame.width * CGFloat(step) / 3
                    path.move(to: CGPoint(x: x, y: frame.minY))
                    path.addLine(to: CGPoint(x: x, y: frame.maxY))
                    let y = frame.minY + frame.height * CGFloat(step) / 3
                    path.move(to: CGPoint(x: frame.minX, y: y))
                    path.addLine(to: CGPoint(x: frame.maxX, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.5)
            .opacity(isDragging ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isDragging)

            // `PUCropHandleView`s in the label colour, all outside the
            // crop: a 1pt edge, 20x3 corners from 3pt past it and 25x3
            // bars across the middle of each side.
            Path { path in
                path.addRect(frame.insetBy(dx: -0.5, dy: -0.5))
            }
            .stroke(Color.primary, lineWidth: 1)

            Path { path in
                let out: CGFloat = 3
                for isRight in [false, true] {
                    for isBottom in [false, true] {
                        let x = isRight ? frame.maxX + out - 20 : frame.minX - out
                        let y = isBottom ? frame.maxY : frame.minY - out
                        path.addRect(CGRect(x: x, y: y, width: 20, height: out))
                        let vx = isRight ? frame.maxX : frame.minX - out
                        let vy = isBottom ? frame.maxY + out - 20 : frame.minY - out
                        path.addRect(CGRect(x: vx, y: vy, width: out, height: 20))
                    }
                }
                path.addRect(CGRect(x: frame.midX - 12.5, y: frame.minY - out, width: 25, height: out))
                path.addRect(CGRect(x: frame.midX - 12.5, y: frame.maxY, width: 25, height: out))
                path.addRect(CGRect(x: frame.minX - out, y: frame.midY - 12.5, width: out, height: 25))
                path.addRect(CGRect(x: frame.maxX, y: frame.midY - 12.5, width: out, height: 25))
            }
            .fill(Color.primary)
        }
        .allowsHitTesting(false)
    }

}

// MARK: - profile picture crop

/// square crop over the rendered picture, uploaded as the account's profile
/// image.
struct ProfilePictureCropScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session

    let asset: Asset
    let onDone: (String) -> Void

    @State private var image: UIImage?
    /// seeded from the image aspect once it loads: normalized space is
    /// stretched, so a literal square rect here would not be a square crop.
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let image {
                    GeometryReader { proxy in
                        let available = CGSize(width: max(proxy.size.width - 24, 1), height: max(proxy.size.height - 24, 1))
                        let canvasSize = AssetEditScreen.aspectFit(image.size, into: available)
                        CropCanvas(image: image, crop: $crop, lockedAspect: 1)
                            .frame(width: canvasSize.width, height: canvasSize.height)
                            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    }
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .navigationTitle("Profile Picture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Button("Save") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(image == nil || session.isProfileImageMutationInFlight)
                            .accessibilityIdentifier("profile-crop-save")
                    }
                }
            }
            .alert(error ?? "", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) {}
            }
        }
        // scoped to this subtree: preferredColorScheme is a window preference
        // and would leave the whole app dark after the cover is dismissed.
        .environment(\.colorScheme, .dark)
        .task { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        let url = client.thumbnailURL(assetID: asset.id, size: "preview")
        let loaded = try? await ImageLoader.shared.image(for: url, targetPixelSize: 2048)
        guard let loaded else {
            error = String(localized: "Could not load the photo.")
            return
        }
        image = loaded
        // largest centered square: a visual 1:1 spans 1/imageAspect wide in
        // normalized units, so the picture's own proportions decide which
        // side is the full one.
        let imageAspect = loaded.size.width / max(loaded.size.height, 1)
        var width: CGFloat = 1
        var height: CGFloat = 1
        let normalized = 1 / imageAspect
        if normalized >= 1 {
            height = 1 / normalized
        } else {
            width = normalized
        }
        crop = CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    private func save() async {
        guard let client = session.client, let image, let cgImage = image.cgImage else { return }
        isSaving = true
        defer { isSaving = false }

        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        let cropped = cgImage.cropping(to: CGRect(
            x: crop.minX * pixelWidth,
            y: crop.minY * pixelHeight,
            width: crop.width * pixelWidth,
            height: crop.height * pixelHeight
        ).integral) ?? cgImage

        guard let data = UIImage(cgImage: cropped).pngData() else {
            ErrorToastCenter.shared.show(String(localized: "Couldn't prepare the profile picture."))
            return
        }

        guard let projection = session.beginProfileImageMutation(data: data) else { return }
        dismiss()
        do {
            try await client.setProfileImage(data: data, filename: "profile-picture.png", mimeType: "image/png")
            await session.refreshUser()
            let cacheKey = UUID().uuidString
            guard session.acceptProfileImageMutation(projection, cacheKey: cacheKey) else { return }
            var canonicalImageIsCached = false
            if let user = session.user {
                let url = client.profileImageURL(userID: user.id)
                    .appending(queryItems: [URLQueryItem(name: "c", value: cacheKey)])
                canonicalImageIsCached = (try? await ImageLoader.shared.image(
                    for: url,
                    targetPixelSize: 120
                )) != nil
            }
            session.finishProfileImageMutation(
                projection,
                canonicalImageIsCached: canonicalImageIsCached
            )
            onDone(String(localized: "Profile picture updated"))
        } catch {
            session.rollbackProfileImageMutation(projection)
            ErrorToastCenter.shared.show(String(localized: "Couldn't set the profile picture"), error: error)
        }
    }
}
