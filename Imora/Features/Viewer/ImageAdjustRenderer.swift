import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// the server's `applyImageAdjust` on device: the css filters saturate,
/// invert, brightness and contrast, in that order, on the encoded srgb
/// values, each clamped before the next. the working space is the
/// nonlinear srgb one so the color matrices see those same values.
nonisolated enum ImageAdjustRenderer {
    private static let context: CIContext = {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb, .cacheIntermediates: false])
    }()

    static func apply(_ adjust: ImageAdjust, to input: CIImage) -> CIImage {
        var image = input
        let s = 1 + adjust.saturation / 100
        if s != 1 {
            // https://www.w3.org/TR/filter-effects-1/#saturateEquivalent
            image = matrix(
                image,
                r: (0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s),
                g: (0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s),
                b: (0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s),
                bias: 0
            )
        }
        // invert keeps values in range, so it folds into the brightness matrix.
        let brightness = 1 + adjust.exposure / 100
        if adjust.invert || brightness != 1 {
            let scale = adjust.invert ? -brightness : brightness
            image = matrix(
                image,
                r: (scale, 0, 0),
                g: (0, scale, 0),
                b: (0, 0, scale),
                bias: adjust.invert ? brightness : 0
            )
        }
        let contrast = 1 + adjust.contrast / 100
        if contrast != 1 {
            image = matrix(
                image,
                r: (contrast, 0, 0),
                g: (0, contrast, 0),
                b: (0, 0, contrast),
                bias: 0.5 * (1 - contrast)
            )
        }
        return image
    }

    /// the picture with the adjustment applied, at the same size and scale.
    static func render(_ image: UIImage, adjust: ImageAdjust) -> UIImage? {
        guard !adjust.isNeutral else { return image }
        guard let source = upright(image) else { return nil }
        let input = CIImage(cgImage: source)
        guard let output = context.createCGImage(apply(adjust, to: input), from: input.extent) else { return nil }
        return UIImage(cgImage: output, scale: image.scale, orientation: .up)
    }

    /// the same render off the main actor, for the live preview.
    @concurrent
    static func preview(_ source: CGImage, scale: CGFloat, adjust: ImageAdjust) async -> UIImage? {
        let input = CIImage(cgImage: source)
        guard let output = context.createCGImage(apply(adjust, to: input), from: input.extent) else { return nil }
        return UIImage(cgImage: output, scale: scale, orientation: .up)
    }

    /// pixels drawn the way the picture is shown, so the render never has
    /// to carry an orientation.
    static func upright(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cgImage = image.cgImage { return cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
        }.cgImage
    }

    private static func matrix(
        _ image: CIImage,
        r: (CGFloat, CGFloat, CGFloat),
        g: (CGFloat, CGFloat, CGFloat),
        b: (CGFloat, CGFloat, CGFloat),
        bias: CGFloat
    ) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: r.0, y: r.1, z: r.2, w: 0)
        filter.gVector = CIVector(x: g.0, y: g.1, z: g.2, w: 0)
        filter.bVector = CIVector(x: b.0, y: b.1, z: b.2, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = filter.outputImage ?? image
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage ?? image
    }
}
