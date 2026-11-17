import Foundation
import CoreMotion
import ImageIO
import SwiftUI
import UIKit

/// gallery's depth.dart: the depth map read for the shader, with the plane
/// that stays still and the near edges grown so the background never smears
/// a sliver of the subject.
nonisolated enum SpatialSceneDepth {
    /// pixels the near edges grow by.
    static let dilateRadius = 3

    /// the mean depth of the foreground, split from the background with otsu's
    /// threshold as the server computes it. keeping the subject still moves the
    /// stretching at its edges into the background, where it shows least. 0...1.
    static func subjectDepth(_ depth: [UInt8]) -> Double {
        var histogram = [Double](repeating: 0, count: 256)
        for value in depth { histogram[Int(value)] += 1 }
        let total = Double(depth.count)
        guard total > 0 else { return 0.5 }
        var sum = 0.0
        for i in 0..<256 { sum += Double(i) * histogram[i] }

        var best = 0.0
        var threshold = 127
        var backgroundCount = 0.0
        var backgroundSum = 0.0
        for i in 0..<256 {
            backgroundCount += histogram[i]
            backgroundSum += Double(i) * histogram[i]
            let foregroundCount = total - backgroundCount
            guard backgroundCount > 0, foregroundCount > 0 else { continue }
            let gap = backgroundSum / backgroundCount - (sum - backgroundSum) / foregroundCount
            let between = backgroundCount * foregroundCount * gap * gap
            guard between > best else { continue }
            best = between
            threshold = i
        }

        var count = 0.0
        var foreground = 0.0
        for i in (threshold + 1)..<256 {
            count += histogram[i]
            foreground += Double(i) * histogram[i]
        }
        return count > 0 ? foreground / count / 255 : sum / total / 255
    }

    /// separable max filter: near, bright edges grow outwards by `radius` pixels.
    static func dilate(_ depth: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        guard radius > 0, width > 0, height > 0 else { return depth }
        var rows = [UInt8](repeating: 0, count: depth.count)
        var out = [UInt8](repeating: 0, count: depth.count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var peak: UInt8 = 0
                for k in max(0, x - radius)...min(width - 1, x + radius) { peak = max(peak, depth[row + k]) }
                rows[row + x] = peak
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                var peak: UInt8 = 0
                for k in max(0, y - radius)...min(height - 1, y + radius) { peak = max(peak, rows[k * width + x]) }
                out[y * width + x] = peak
            }
        }
        return out
    }

    /// the png decoded to grey, its focus, and the dilated map as an opaque
    /// srgb image, the layout the shader samples.
    @concurrent
    static func prepare(png: Data) async throws -> (image: CGImage, focus: Double) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ImoraError.decoding(String(localized: "depth map")) }
        let width = decoded.width
        let height = decoded.height
        var grey = [UInt8](repeating: 0, count: width * height)
        let drawn = grey.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ImoraError.decoding(String(localized: "depth map")) }

        let focus = subjectDepth(grey)
        let dilated = dilate(grey, width: width, height: height, radius: dilateRadius)
        var rgba = [UInt8](repeating: 255, count: dilated.count * 4)
        for (index, value) in dilated.enumerated() {
            rgba[index * 4] = value
            rgba[index * 4 + 1] = value
            rgba[index * 4 + 2] = value
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else { throw ImoraError.decoding(String(localized: "depth map")) }
        return (image, focus)
    }
}

/// a damped spring stepped by `dt` seconds, slightly underdamped so the scene
/// eases after the tilt like a physical object.
nonisolated struct SpatialSceneSpring {
    var position = 0.0
    var velocity = 0.0

    mutating func step(to target: Double, dt: Double, stiffness: Double = 60, dampingRatio: Double = 0.9) {
        let damping = 2 * stiffness.squareRoot() * dampingRatio
        velocity += ((target - position) * stiffness - velocity * damping) * dt
        position += velocity * dt
    }
}

/// photos' `GyroCameraAnimator`: where the scene looks, in radians on the
/// screen's axes, horizontal then vertical. the phone's attitude at 100 Hz,
/// relative to the pose it was anchored at, turns the scene's camera 1:1.
/// read once a frame rather than through a handler, so nothing crosses
/// threads. without motion, a finger or a slow sway stands in.
@MainActor
final class SpatialSceneMotion {
    /// `SpatialPhoto.CameraParameters.defaultMaxViewAngle`: past this tilt
    /// from the anchor, the scene anchors again to the phone's pose.
    static let maxViewAngle = 0.3
    /// the old view then fades out linearly over a second, as it does after
    /// an interface rotation.
    private static let fadeDuration = 1.0
    /// seconds without a drag before the scene sways on its own, without motion.
    private static let idleAfter = 2.5

    private let manager = CMMotionManager()
    private var orientation = UIInterfaceOrientation.portrait
    private var anchor: CMAttitude?
    private var needsAnchor = true
    private var fading: (angles: SIMD2<Double>, start: TimeInterval)?
    private var output = SIMD2<Double>.zero
    private var lastInput: TimeInterval?
    private var previous: TimeInterval?
    private var x = SpatialSceneSpring()
    private var y = SpatialSceneSpring()
    /// set while a finger drives the scene, -1...1 on each axis.
    var drag: SIMD2<Double>?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        recenter()
        guard isAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 0.01
        manager.startDeviceMotionUpdates()
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        anchor = nil
        fading = nil
        output = .zero
        previous = nil
    }

    /// the next reading becomes the anchor, after a rotation too.
    func recenter() {
        needsAnchor = true
        orientation = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.effectiveGeometry.interfaceOrientation }
            .first ?? .portrait
    }

    func step(at time: TimeInterval, sways: Bool) -> SIMD2<Double> {
        let dt = min(0.05, previous.map { time - $0 } ?? 0)
        if previous == nil { lastInput = time }
        previous = time
        if drag == nil, let attitude = manager.deviceMotion?.attitude {
            output = follow(attitude, at: time)
            return output
        }
        var target = SIMD2<Double>.zero
        // a finger carries the scene along, so it turns the camera against it.
        if let drag {
            target = -drag * Self.maxViewAngle
            lastInput = time
        }
        if sways, drag == nil, time - (lastInput ?? -.infinity) > Self.idleAfter {
            target = SIMD2(sin(time * 0.55) * 0.75, sin(time * 0.8 + 1.2) * 0.35) * Self.maxViewAngle
        }
        x.step(to: target.x, dt: dt)
        y.step(to: target.y, dt: dt)
        output = SIMD2(x.position, y.position)
        return output
    }

    private func follow(_ attitude: CMAttitude, at time: TimeInterval) -> SIMD2<Double> {
        if needsAnchor || anchor == nil {
            if anchor != nil { fading = (output, time) }
            anchor = attitude.copy() as? CMAttitude
            needsAnchor = false
        }
        guard let anchor, let relative = attitude.copy() as? CMAttitude else { return output }
        relative.multiply(byInverseOf: anchor)
        var angles = screenAngles(pitch: relative.pitch, roll: relative.roll)
        if (relative.pitch * relative.pitch + relative.roll * relative.roll).squareRoot() > Self.maxViewAngle {
            fading = (output, time)
            self.anchor = attitude.copy() as? CMAttitude
            angles = .zero
        }
        if let fading {
            let progress = (time - fading.start) / Self.fadeDuration
            if progress < 1 {
                angles += fading.angles * (1 - progress)
            } else {
                self.fading = nil
            }
        }
        return angles
    }

    /// turns about the device's x and y axes, seen from the screen as it is
    /// held: about its vertical axis, then its horizontal one.
    private func screenAngles(pitch: Double, roll: Double) -> SIMD2<Double> {
        switch orientation {
        case .portraitUpsideDown: SIMD2(-roll, -pitch)
        case .landscapeLeft: SIMD2(-pitch, roll)
        case .landscapeRight: SIMD2(pitch, -roll)
        default: SIMD2(roll, pitch)
        }
    }
}

private struct SpatialSceneTextures {
    let preview: UIImage
    let depth: Image
    let focus: Double
}

/// the photo drawn again with its depth map, moved by tilting the phone. a
/// finger drives it where there is no motion or reduce motion is on, which
/// also leaves it still between drags.
struct SpatialSceneOverlay: View {
    /// `SpatialPhoto.CameraParameters.defaultDepthMin` and `defaultDepthMax`:
    /// the scene spans these shares of the camera's distance.
    private static let nearDistance = 0.95
    private static let farDistance = 1.12
    /// `SpatialPhoto.CameraController.defaultZoomInPercentage`, which keeps
    /// the shifted edges inside the frame.
    private static let zoom = 1.133
    /// an iphone's 26mm equivalent wide camera, its focal length over the
    /// frame's diagonal.
    private static let focalOverDiagonal = 26 / (36.0 * 36 + 24 * 24).squareRoot()

    /// the share of the frame each depth slides by per radian the camera
    /// turns around the subject: the focal length over the side, times how
    /// far the nearest and farthest depths part around it.
    static func parallax(size: CGSize, focus: Double) -> SIMD2<Double> {
        guard size.width > 0, size.height > 0 else { return .zero }
        let pivot = farDistance - focus * (farDistance - nearDistance)
        let spread = pivot * (1 / nearDistance - 1 / farDistance)
        let focal = focalOverDiagonal * (size.width * size.width + size.height * size.height).squareRoot()
        return SIMD2(focal / size.width * spread, focal / size.height * spread)
    }

    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let assetID: String
    let cacheKey: String?
    let aspectRatio: Double
    let onTap: () -> Void
    let onFailure: () -> Void

    @State private var textures: SpatialSceneTextures?
    @State private var motion = SpatialSceneMotion()
    @State private var size = CGSize.zero
    @State private var isVisible = false
    /// the viewer lives in its own hosting controller, where swiftui's scene
    /// phase never leaves background, so the app's own state tells instead.
    @State private var appIsActive = UIApplication.shared.applicationState == .active
    /// where a drag left the scene while it does not animate.
    @State private var still = SIMD2<Double>.zero

    private var animates: Bool { !reduceMotion }
    private var followsFinger: Bool { reduceMotion || !motion.isAvailable }
    private var isRunning: Bool { isVisible && appIsActive && textures != nil }

    var body: some View {
        ZStack {
            if let textures {
                Color.black
                    .allowsHitTesting(false)
                AssetViewerFittedMedia(aspectRatio: aspectRatio) {
                    scene(textures)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
                            size = newSize
                            motion.recenter()
                        }
                        .contentShape(.rect)
                        .gesture(dragGesture, isEnabled: followsFinger)
                        .onTapGesture(perform: onTap)
                        .allowsHitTesting(followsFinger)
                        .accessibilityElement()
                        .accessibilityLabel("Spatial Scene")
                        .accessibilityAddTraits(.isImage)
                }
                .transition(.opacity)
            } else {
                ProgressView()
                    .tint(.white)
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : PhotosMotion.controls, value: textures == nil)
        .task(id: assetID) { await load() }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            appIsActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            appIsActive = false
        }
        .onChange(of: isRunning && animates, initial: true) { _, running in
            if running { motion.start() } else { motion.stop() }
        }
    }

    @ViewBuilder private func scene(_ textures: SpatialSceneTextures) -> some View {
        if animates {
            TimelineView(.animation(paused: !isRunning)) { context in
                let position = motion.step(at: context.date.timeIntervalSinceReferenceDate, sways: true)
                shaded(textures, at: position)
            }
        } else {
            shaded(textures, at: -still * SpatialSceneMotion.maxViewAngle)
        }
    }

    /// the camera turned by `angles` orbits the subject, so whatever is
    /// nearer slides against the turn and whatever is farther with it.
    private func shaded(_ textures: SpatialSceneTextures, at angles: SIMD2<Double>) -> some View {
        let focus = textures.focus
        let parallax = Self.parallax(size: size, focus: focus)
        let shader = ShaderLibrary.spatialScene(
            .float2(size),
            .float2(-angles.x * parallax.x, -angles.y * parallax.y),
            .float(focus),
            .float(Self.zoom),
            .image(textures.depth)
        )
        return Image(uiImage: textures.preview)
            .resizable()
            .layerEffect(shader, maxSampleOffset: CGSize(width: size.width / 4, height: size.height / 4),
                         isEnabled: size.width > 0 && size.height > 0)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let half = SIMD2(max(1, size.width / 2), max(1, size.height / 2))
                let start = animates ? SIMD2<Double>.zero : still
                let moved = SIMD2(value.translation.width, value.translation.height) / half
                let position = (start + moved).clamped(lowerBound: SIMD2(repeating: -1), upperBound: SIMD2(repeating: 1))
                if animates { motion.drag = position } else { still = position }
            }
            .onEnded { _ in
                motion.drag = nil
            }
    }

    private func load() async {
        textures = nil
        guard let client = session.client else { return }
        let url = client.thumbnailURL(assetID: assetID, size: "preview", cacheKey: cacheKey)
        do {
            async let preview = ImageLoader.shared.image(for: url, targetPixelSize: pagePixelSize)
            async let png = client.depthMap(assetID: assetID)
            let depth = try await SpatialSceneDepth.prepare(png: try await png)
            let image = try await preview
            guard !Task.isCancelled else { return }
            textures = SpatialSceneTextures(
                preview: image,
                depth: Image(decorative: depth.image, scale: 1),
                focus: depth.focus
            )
        } catch {
            guard !Task.isCancelled else { return }
            onFailure()
        }
    }
}
