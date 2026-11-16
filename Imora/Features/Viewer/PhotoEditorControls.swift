import Foundation
import SwiftUI
import UIKit

enum EditorAppearance {
    static let accent = Color.yellow
}

/// photos' edit slider, `CEKSlider` as `+[PUPhotoEditSupport createEditSlider]`
/// sets it up: 41 ticks 9pt apart span the whole range, a main tick every
/// tenth, scrolling under a fixed centre indicator. the value runs -1...1.
/// ticks are 2x14 rounded bars at 0.4 and 0.7, the indicator 2x28. over the
/// adjust tool's dark shadow they stay white in both appearances.
struct EditorRuler: View {
    @Binding var value: Double
    var isDimmed = false
    var tickColor = Color.white
    var onEditingChanged: (Bool) -> Void = { _ in }

    static let height: CGFloat = 28

    private static let spacing: CGFloat = 9
    private static let tickCount = 41
    private static let mainInterval = 10
    private static let tickHeight: CGFloat = 14
    private static let tickWidth: CGFloat = 2
    /// points of drag around zero that stick to it, like the slider's
    /// snapping target on the default value.
    private static let snapDistance: CGFloat = 4

    @State private var dragStart: Double?
    @State private var lastTick: Int?
    @State private var isSnapped = false
    @State private var feedback = UISelectionFeedbackGenerator()

    /// points the whole -1...1 range scrolls across.
    private static var span: CGFloat { spacing * CGFloat(tickCount - 1) }

    var body: some View {
        Canvas { context, size in
            let center = size.width / 2
            let half = Self.tickCount / 2
            let shift = CGFloat(value) * Self.span / 2
            for index in 0..<Self.tickCount {
                let x = center + CGFloat(index - half) * Self.spacing - shift
                guard x > -Self.tickWidth, x < size.width + Self.tickWidth else { continue }
                let isMain = (index - half) % Self.mainInterval == 0
                let tick = CGRect(
                    x: x - Self.tickWidth / 2,
                    y: size.height - Self.tickHeight,
                    width: Self.tickWidth,
                    height: Self.tickHeight
                )
                context.fill(
                    Path(roundedRect: tick, cornerRadius: 1),
                    with: .color(tickColor.opacity(isMain ? 0.7 : 0.4))
                )
            }
            let indicator = CGRect(x: center - 1, y: 0, width: 2, height: Self.height)
            context.fill(Path(roundedRect: indicator, cornerRadius: 1), with: .color(EditorAppearance.accent))
        }
        .frame(height: Self.height)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.1),
                    .init(color: .black, location: 0.9),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .opacity(isDimmed ? 0.33 : 1)
        .contentShape(.rect)
        .gesture(drag)
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded()))")
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            switch direction {
            case .increment: value = min(1, value + step)
            case .decrement: value = max(-1, value - step)
            @unknown default: break
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if dragStart == nil {
                    dragStart = value
                    lastTick = Self.tick(for: value)
                    isSnapped = value == 0
                    feedback.prepare()
                    onEditingChanged(true)
                }
                let raw = (dragStart ?? 0) - Double(gesture.translation.width / (Self.span / 2))
                var next = min(1, max(-1, raw))
                let snaps = abs(next) * Self.span / 2 < Self.snapDistance
                if snaps {
                    next = 0
                    if !isSnapped { feedback.selectionChanged() }
                }
                isSnapped = snaps
                let tick = Self.tick(for: next)
                if tick != lastTick, !snaps {
                    feedback.selectionChanged()
                }
                lastTick = tick
                value = next
            }
            .onEnded { _ in
                dragStart = nil
                onEditingChanged(false)
            }
    }

    private static func tick(for value: Double) -> Int {
        Int((value * Double(tickCount - 1) / 2).rounded())
    }
}

/// `PUPhotoEditAdjustmentControl` in its cell: a 51pt ultra thin material
/// circle. `PUPhotoEditCircularIndicatorView` strokes a 2pt track in the
/// label colour at 30%, then the value in 1.5pt from twelve o'clock,
/// clockwise in the highlight colour when positive, anticlockwise in the
/// label colour when negative. toggles have no ring and fill at 10% while
/// on. the number replaces the glyph only while its slider moves, and a
/// tool switched off fades to 30%.
struct EditorToolButton: View {
    static let size: CGFloat = 51

    let systemImage: String
    /// -1...1 for a slider tool, nil for a toggle.
    var value: Double?
    var isActive = false
    var isEnabled = true
    var isSelected = false
    var showsValue = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
            if value == nil, isActive {
                Circle().fill(Color.primary.opacity(0.1))
            }
            if let value {
                Circle()
                    .inset(by: 1.25)
                    .stroke(Color.primary.opacity(0.3), lineWidth: 2)
                if value != 0 {
                    Circle()
                        .inset(by: 1.25)
                        .trim(from: 0, to: min(1, abs(value)))
                        .stroke(value > 0 ? EditorAppearance.accent : Color.primary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .scaleEffect(x: value > 0 ? 1 : -1)
                }
            }
            if showsValue, let value {
                Text("\(Int((value * 100).rounded()))")
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(value > 0 ? EditorAppearance.accent : Color.primary)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(isSelected ? EditorAppearance.accent : Color.primary)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .opacity(isEnabled ? 1 : 0.3)
        .contentShape(.circle)
    }
}

/// `PUEditBadgeLabel`, the tool's name above its strip: 15pt regular caps in
/// the secondary label colour on a tertiary fill, 26pt tall, radius 6.
struct EditorToolLabel: View {
    static let height: CGFloat = 26.33

    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: Self.height)
            .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 6))
    }
}

/// photos' tool switcher, `PhotoEditToolbarController`: a 62pt glass capsule
/// of 47pt items, a glyph over a 10pt medium label. the current one is in
/// the label colour, the others in the secondary one, and a 5pt triangle
/// marks it 4pt below the capsule's top.
struct EditorTabBar<Tab: Hashable>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionAnimation
    static var height: CGFloat { 62 }

    struct Item: Identifiable {
        let tab: Tab
        let title: String
        let systemImage: String
        var isEnabled = true
        var id: Tab { tab }
    }

    let items: [Item]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let isSelected = item.tab == selection
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                        selection = item.tab
                    }
                } label: {
                    VStack(spacing: 0) {
                        ZStack {
                            if isSelected {
                                EditorTabMarker()
                                    .fill(EditorAppearance.accent)
                                    .matchedGeometryEffect(id: "selection", in: selectionAnimation)
                            }
                        }
                        .frame(width: 5, height: 4.33)
                        .padding(.top, 4)
                        Image(systemName: item.systemImage)
                            .font(.system(size: 19, weight: .regular))
                            .frame(height: 22)
                            .padding(.top, 3)
                        Text(item.title)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.top, 4.3)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(width: 47, height: Self.height)
                    .opacity(item.isEnabled ? 1 : 0.3)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!item.isEnabled)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 13)
        .glassEffect(.regular, in: .capsule)
    }
}

/// the downward triangle above the current tab.
private nonisolated struct EditorTabMarker: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// glyph buttons sharing one 44pt glass capsule, like the bar items photos
/// groups in its nav bar: 40pt items 16pt apart, a lone one in a circle.
struct EditorGlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 16) {
            content
        }
        .frame(minWidth: 44, minHeight: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// a glyph inside an `EditorGlassGroup`: photos' `PUPhotoEditToolbarButton`,
/// 21pt regular in the label colour, tertiary while disabled.
struct EditorGlassGlyph: View {
    let systemImage: String
    let label: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            EditorGlassGlyphLabel(systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(Color(uiColor: .tertiaryLabel)))
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}

/// the glyph and hit area of an `EditorGlassGlyph`, for menus too.
struct EditorGlassGlyphLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 21, weight: .regular))
            .frame(width: 40, height: 44)
            .contentShape(.rect)
    }
}

@MainActor
struct EditorMenuAction {
    let identifier: String
    let title: String
    let systemImage: String
    var isEnabled = true
    let action: () -> Void
}

/// A real button owns the menu's accessibility bounds. SwiftUI Menu can
/// otherwise adopt the whole shared glass capsule, including sibling glyphs.
@MainActor
struct EditorMenuButton: UIViewRepresentable {
    let systemImage: String
    let label: String
    let accessibilityIdentifier: String
    let actions: [EditorMenuAction]

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = .label
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 21, weight: .regular)
        button.configuration = configuration
        button.tintColor = .label
        button.showsMenuAsPrimaryAction = true
        button.isAccessibilityElement = true
        button.accessibilityTraits = .button
        updateUIView(button, context: context)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.configuration?.image = UIImage(systemName: systemImage)
        button.accessibilityIdentifier = accessibilityIdentifier
        button.accessibilityLabel = label
        button.menu = UIMenu(children: actions.map { item in
            UIAction(title: item.title, image: UIImage(systemName: item.systemImage),
                     identifier: UIAction.Identifier(rawValue: item.identifier),
                     attributes: item.isEnabled ? [] : [.disabled]) { _ in item.action() }
        })
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: 40, height: 44)
    }
}

/// the tool's name in the middle of the glass row, as photos titles its nav
/// bar: 14pt semibold caps in the secondary label colour.
struct EditorBarTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// `PUPhotoEditShadowView` behind the tools: a thin dark material, masked
/// from opaque at the bottom to clear at the top. it reads as a grey fade
/// over the light background and barely shows over the dark one.
struct EditorToolShadow: View {
    static let height: CGFloat = 274

    var body: some View {
        Rectangle()
            .fill(.thinMaterial)
            .environment(\.colorScheme, .dark)
            .mask {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            }
            .frame(height: Self.height)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// photos' per-model frames for cancel and done, from `+[PUPhotoEditLayoutSupport
/// currentDeviceButtonSize:offset:zoomedSize:zoomedOffset:normalScreenWidth:]`
/// in ios 27.0.1. photos keys the table by `MGGetProductType` hashes. each
/// firmware's devicetree `/product/product-id` picks a row of mobilegestalt's
/// device map, which names the hash, so the keys here are the matching model
/// identifiers. the zoomed frames apply below `normalScreenWidth`, with
/// display zoom on.
nonisolated struct EditorNotchButtonMetrics: Equatable, Sendable {
    var size: CGSize
    var offset: CGPoint
    var zoomedSize: CGSize
    var zoomedOffset: CGPoint
    var normalScreenWidth: CGFloat

    private init(
        _ size: CGSize,
        _ offset: CGPoint,
        zoomed zoomedSize: CGSize,
        _ zoomedOffset: CGPoint,
        normalWidth: CGFloat
    ) {
        self.size = size
        self.offset = offset
        self.zoomedSize = zoomedSize
        self.zoomedOffset = zoomedOffset
        self.normalScreenWidth = normalWidth
    }

    func frame(screenWidth: CGFloat) -> (size: CGSize, offset: CGPoint) {
        screenWidth > 0 && screenWidth < normalScreenWidth
            ? (zoomedSize, zoomedOffset)
            : (size, offset)
    }

    private static let table: [String: EditorNotchButtonMetrics] = {
        let rows: [([String], EditorNotchButtonMetrics)] = [
            (
                ["iPhone15,2", "iPhone15,4", "iPhone16,1", "iPhone17,1", "iPhone17,3", "iPhone18,1", "iPhone18,3", "iPhone19,2"],
                .init(CGSize(width: 66, height: 28), CGPoint(x: 44, y: 18), zoomed: CGSize(width: 66, height: 28), CGPoint(x: 30, y: 13), normalWidth: 390)
            ),
            (
                ["iPhone15,3", "iPhone15,5", "iPhone16,2", "iPhone17,2", "iPhone17,4", "iPhone18,2", "iPhone19,3", "iPhone19,7"],
                .init(CGSize(width: 68, height: 28), CGPoint(x: 48, y: 16), zoomed: CGSize(width: 68, height: 27), CGPoint(x: 44, y: 12), normalWidth: 428)
            ),
            (
                ["iPhone14,2", "iPhone14,5", "iPhone14,7", "iPhone17,5"],
                .init(CGSize(width: 60, height: 26), CGPoint(x: 34, y: 10), zoomed: CGSize(width: 60, height: 26), CGPoint(x: 26, y: 8), normalWidth: 390)
            ),
            (
                ["iPhone13,2", "iPhone13,3", "iPhone14,8"],
                .init(CGSize(width: 60, height: 26), CGPoint(x: 20, y: 14), zoomed: CGSize(width: 60, height: 26), CGPoint(x: 13, y: 8), normalWidth: 390)
            ),
            (
                ["iPhone12,8", "iPhone14,6"],
                .init(CGSize(width: 60, height: 26), CGPoint(x: 10, y: 6), zoomed: CGSize(width: 60, height: 26), CGPoint(x: 10, y: 6), normalWidth: 375)
            ),
            (
                ["iPhone12,3"],
                .init(CGSize(width: 60, height: 26), CGPoint(x: 16, y: 10), zoomed: CGSize(width: 60, height: 26), CGPoint(x: 10, y: 8), normalWidth: 375)
            ),
            (
                ["iPhone12,5"],
                .init(CGSize(width: 60, height: 26), CGPoint(x: 28, y: 10), zoomed: CGSize(width: 60, height: 26), CGPoint(x: 22, y: 8), normalWidth: 414)
            ),
            (
                ["iPhone13,1"],
                .init(CGSize(width: 58, height: 26), CGPoint(x: 14, y: 17), zoomed: CGSize(width: 52, height: 26), CGPoint(x: 10, y: 10), normalWidth: 375)
            ),
            (
                ["iPhone13,4"],
                .init(CGSize(width: 66, height: 28), CGPoint(x: 30, y: 12), zoomed: CGSize(width: 66, height: 26), CGPoint(x: 22, y: 10), normalWidth: 428)
            ),
            (
                ["iPhone14,3"],
                .init(CGSize(width: 68, height: 28), CGPoint(x: 48, y: 10), zoomed: CGSize(width: 68, height: 28), CGPoint(x: 32, y: 8), normalWidth: 428)
            ),
            (
                ["iPhone14,4"],
                .init(CGSize(width: 64, height: 26), CGPoint(x: 25, y: 13), zoomed: CGSize(width: 60, height: 26), CGPoint(x: 16, y: 10), normalWidth: 375)
            ),
            (
                ["iPhone18,4"],
                .init(CGSize(width: 68, height: 28), CGPoint(x: 48, y: 24), zoomed: CGSize(width: 68, height: 27), CGPoint(x: 44, y: 22), normalWidth: 420)
            ),
        ]
        var table: [String: EditorNotchButtonMetrics] = [:]
        for (models, metrics) in rows {
            for model in models {
                table[model] = metrics
            }
        }
        return table
    }()

    /// photos' answer for models missing from the table, which never zooms.
    private static let unknownPhone = EditorNotchButtonMetrics(
        CGSize(width: 58, height: 26), CGPoint(x: 14, y: 19),
        zoomed: .zero, .zero, normalWidth: 1
    )

    private static let unknownDevice = EditorNotchButtonMetrics(
        CGSize(width: 68, height: 28), CGPoint(x: 16, y: 22),
        zoomed: .zero, .zero, normalWidth: 1
    )

    static let modelIdentifier: String = {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }()

    static let isPhone = modelIdentifier.hasPrefix("iPhone")

    /// `+[PUPhotoEditLayoutSupport isNotchedPhone]`: any phone but the two
    /// home button ones photos checks for, the 2nd and 3rd gen se.
    static let isNotchedPhone = isPhone && !["iPhone12,8", "iPhone14,6"].contains(modelIdentifier)

    static let current = table[modelIdentifier] ?? (isPhone ? unknownPhone : unknownDevice)
}

/// where cancel and done go. photos sets them in the camera housing's strip
/// only on a notched phone in portrait, and lowers the glass row there by
/// `topToolbarVerticalOffsetForLayoutOrientation:view:`, which is 59 minus
/// the top safe area, kept within 0 to 12. anywhere else, in landscape or on
/// a phone with a home button, they take a row of their own above the glass
/// row.
nonisolated struct EditorPrimaryBarLayout: Equatable, Sendable {
    private static let rowSpacing: CGFloat = 8

    var size: CGSize = .zero
    var safeArea = EdgeInsets()

    private var metrics: (size: CGSize, offset: CGPoint) {
        EditorNotchButtonMetrics.current.frame(screenWidth: size.width + safeArea.leading + safeArea.trailing)
    }

    var inHousing: Bool {
        EditorNotchButtonMetrics.isNotchedPhone && size.height > size.width
    }

    var buttonSize: CGSize { metrics.size }

    var leadingInset: CGFloat {
        inHousing ? metrics.offset.x : safeArea.leading + 16
    }

    var trailingInset: CGFloat {
        inHousing ? metrics.offset.x : safeArea.trailing + 16
    }

    var top: CGFloat {
        inHousing ? metrics.offset.y : safeArea.top + Self.rowSpacing
    }

    /// what the glass row moves down by.
    var glassRowOffset: CGFloat {
        inHousing
            ? min(max(59 - safeArea.top, 0), 12)
            : buttonSize.height + Self.rowSpacing * 2
    }
}

/// photos' cancel and done, `PUPhotoEditNotchButton`s, placed and sized by
/// `EditorPrimaryBarLayout`: capsules with a 14pt bold title. cancel
/// is plain glass in the label colour. done is plain glass in the tertiary
/// label colour until there's a change, then prominent glass in the
/// highlight colour with black text. a cancel with changes asks before
/// discarding them.
struct EditorPrimaryBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let hasChanges: Bool
    let isSaving: Bool
    var cancelIdentifier = "edit-cancel"
    var doneIdentifier = "edit-done"
    let onCancel: () -> Void
    let onDone: () -> Void
    var onKeepDraft: (() -> Void)? = nil
    var canSave = true
    var hasDraft = false

    @State private var showDiscard = false

    var body: some View {
        GeometryReader { proxy in
            let layout = EditorPrimaryBarLayout(size: proxy.size, safeArea: proxy.safeAreaInsets)
            buttons(size: layout.buttonSize)
                .padding(.leading, layout.leadingInset)
                .padding(.trailing, layout.trailingInset)
                .padding(.top, layout.top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
        }
    }

    private func buttons(size: CGSize) -> some View {
        HStack {
            Button {
                guard !isSaving else { return }
                if hasChanges || hasDraft {
                    showDiscard = true
                } else {
                    onCancel()
                }
            } label: {
                title(String(localized: "Cancel"), size: size)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .disabled(isSaving)
            .accessibilityIdentifier(cancelIdentifier)
            // ios 26 morphs the dialog out of its source control, so it
            // belongs on Cancel - from the screen root it anchors to the
            // window and floats detached.
            .confirmationDialog(
                "Discard Edits?",
                isPresented: $showDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard Changes", role: .destructive) {
                    guard !isSaving else { return }
                    onCancel()
                }
                if let onKeepDraft {
                    Button("Save Draft and Close") { onKeepDraft() }
                        .accessibilityIdentifier("edit-keep-draft")
                }
                Button("Keep Editing", role: .cancel) {}
            }

            Spacer()

            if isSaving {
                ProgressView()
                    .frame(width: size.width, height: size.height)
            } else {
                Button {
                    showDiscard = false
                    onDone()
                } label: {
                    title(String(localized: "Done"), size: size)
                        .foregroundStyle(hasChanges ? AnyShapeStyle(Color.black) : AnyShapeStyle(Color(uiColor: .tertiaryLabel)))
                }
                .buttonStyle(.plain)
                .glassEffect(
                    hasChanges ? .regular.tint(EditorAppearance.accent).interactive() : .regular,
                    in: .capsule
                )
                .disabled(!hasChanges || !canSave)
                .accessibilityIdentifier(doneIdentifier)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: hasChanges)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isSaving)
    }

    private func title(_ text: String, size: CGSize) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: size.width, height: size.height)
            .contentShape(.capsule)
    }
}

extension View {
    /// The system fade keeps editing in the same visual context rather than
    /// presenting it as a sheet sliding up over the photo. Earlier systems
    /// retain their native presentation transition.
    @ViewBuilder
    func editorPresentationTransition() -> some View {
        #if os(iOS) || os(visionOS)
        if #available(iOS 27.0, visionOS 27.0, *) {
            navigationTransition(.crossFade)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// lowers the glass row under cancel and done, by photos' offset beside
    /// the camera housing or by their own row elsewhere.
    func editorPrimaryBarRoom() -> some View {
        modifier(EditorPrimaryBarRoom())
    }
}

private struct EditorPrimaryBarRoom: ViewModifier {
    @State private var layout = EditorPrimaryBarLayout()

    func body(content: Content) -> some View {
        content
            .padding(.top, layout.glassRowOffset)
            .onGeometryChange(for: EditorPrimaryBarLayout.self) { proxy in
                EditorPrimaryBarLayout(size: proxy.size, safeArea: proxy.safeAreaInsets)
            } action: { layout = $0 }
    }
}

nonisolated enum PhotoGeometryTool: String, CaseIterable, Identifiable {
    case crop, straighten, horizontalPerspective, verticalPerspective
    var id: Self { self }
    var title: String {
        switch self {
        case .crop: String(localized: "Crop")
        case .straighten: String(localized: "Straighten")
        case .horizontalPerspective: String(localized: "Horizontal Perspective")
        case .verticalPerspective: String(localized: "Vertical Perspective")
        }
    }
    var symbol: String {
        switch self {
        case .crop: "crop"
        case .straighten: "dial.low"
        case .horizontalPerspective: "perspective"
        case .verticalPerspective: "trapezoid.and.line.vertical"
        }
    }
    func value(_ photo: PhotoAdjust) -> Double {
        switch self {
        case .crop: 0
        case .straighten: photo.straighten / 45
        case .horizontalPerspective: photo.horizontalPerspective
        case .verticalPerspective: photo.verticalPerspective
        }
    }
    func set(_ amount: Double, photo: inout PhotoAdjust) {
        let value = min(1, max(-1, amount))
        switch self {
        case .crop: break
        case .straighten: photo.straighten = (value * 450).rounded() / 10
        case .horizontalPerspective: photo.horizontalPerspective = (value * 100).rounded() / 100
        case .verticalPerspective: photo.verticalPerspective = (value * 100).rounded() / 100
        }
    }
}

struct PhotoGeometryControls: View {
    @Binding var selection: PhotoGeometryTool
    @Binding var photo: PhotoAdjust
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 24) {
                ForEach(PhotoGeometryTool.allCases) { item in
                    Button { selection = item } label: {
                        EditorToolButton(systemImage: item.symbol, value: item.value(photo), isSelected: item == selection)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                    .accessibilityIdentifier("edit-geometry-\(item.rawValue)")
                    .accessibilityAddTraits(item == selection ? .isSelected : [])
                }
            }
            if selection != .crop {
                EditorRuler(value: Binding(get: { selection.value(photo) }, set: { selection.set($0, photo: &photo) }), onEditingChanged: onEditingChanged)
                    .accessibilityLabel(selection.title)
                    .accessibilityIdentifier("edit-geometry-ruler")
            } else {
                Text("Drag the frame to crop").font(.caption).foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .top) {
            EditorToolLabel(text: selection.title).offset(y: -24.33).allowsHitTesting(false)
        }
    }
}
