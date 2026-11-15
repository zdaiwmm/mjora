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

extension ImageAdjustRenderer {
    /// Runtime Core Image kernels execute in the same nonlinear sRGB space as
    /// the legacy matrices. Failure propagates; a missing kernel never silently
    /// drops an accepted parameter from the saved image.
    nonisolated private static let photoColorKernel = CIColorKernel(source: """
        kernel vec4 photoColor(__sample px, float sat, float inv, float exp,
            float hi, float sh, float bri, float black, float warm, float tint, float con) {
            vec3 c = px.a > 0.0 ? px.rgb/px.a : vec3(0.0);
            vec3 w = vec3(0.213, 0.715, 0.072);
            float l = dot(c,w);
            c = clamp(vec3(l) + sat*(c-vec3(l)), 0.0, 1.0);
            c = clamp(mix(c, 1.0-c, inv), 0.0, 1.0);
            c = clamp(c*exp, 0.0, 1.0);
            l = dot(c,w);
            c = clamp(c + hi*l*l, 0.0, 1.0);
            l = dot(c,w);
            c = clamp(c + sh*(1.0-l)*(1.0-l), 0.0, 1.0);
            c = clamp(c + bri, 0.0, 1.0);
            c = clamp((c-black)/(1.0-black), 0.0, 1.0);
            c = clamp(c + vec3(warm, 0.0, -warm), 0.0, 1.0);
            c = clamp(c + vec3(tint*0.5, -tint, tint*0.5), 0.0, 1.0);
            c = clamp((c-0.5)*con+0.5, 0.0, 1.0);
            return vec4(c*px.a, px.a);
        }
        """)

    nonisolated private static let photoWarpKernel = CIWarpKernel(source: """
        kernel vec2 photoWarp(float angle, float hp, float vp, float m, vec2 size) {
            vec2 p = destCoord()-vec2(0.5);
            float u = size.x > 1.0 ? p.x/(size.x-1.0)*2.0-1.0 : 0.0;
            float v = size.y > 1.0 ? 1.0-p.y/(size.y-1.0)*2.0 : 0.0;
            float d = 1.0+0.25*(hp*u+vp*v);
            vec2 q = vec2(cos(angle)*u+sin(angle)*v, -sin(angle)*u+cos(angle)*v)/d/m;
            return vec2((q.x+1.0)*0.5*(size.x-1.0), (1.0-q.y)*0.5*(size.y-1.0))+vec2(0.5);
        }
        """)

    nonisolated static func apply(_ photo: PhotoAdjust, to input: CIImage) -> CIImage? {
        guard (try? photo.validate()) != nil else { return nil }
        guard photo.hasWarp || photo.hasExtendedColor else { return apply(photo.legacy, to: input) }
        // Warp premultiplied RGBA so hidden colors under transparent pixels
        // cannot bleed into visible edges. Color stages use straight RGB.
        var image = input
        if photo.hasWarp {
            guard let kernel = photoWarpKernel,
                  let warped = kernel.apply(extent: input.extent, roiCallback: { _, _ in input.extent },
                    image: image.clampedToExtent(), arguments: [photo.straighten * .pi / 180,
                        photo.horizontalPerspective, photo.verticalPerspective, PhotoAdjustMath.cornerScale(photo),
                        CIVector(x: input.extent.width, y: input.extent.height)])
            else { return nil }
            image = warped
        }
        // Preserve the precise established legacy pipeline at zero extension.
        guard photo.hasExtendedColor else { return apply(photo.legacy, to: image.unpremultiplyingAlpha()).premultiplyingAlpha() }
        return photoColorKernel?.apply(extent: input.extent, arguments: [image,
            1 + photo.saturation / 100, photo.invert ? 1.0 : 0.0, 1 + photo.exposure / 100,
            0.5 * photo.highlights / 100, 0.5 * photo.shadows / 100, 0.5 * photo.brightness / 100,
            0.5 * photo.blackPoint / 100, 0.15 * photo.warmth / 100, 0.15 * photo.tint / 100,
            1 + photo.contrast / 100])
    }

    nonisolated static func render(_ image: UIImage, photo: PhotoAdjust) -> UIImage? {
        guard !photo.isNeutral else { return image }
        guard var source = upright(image) else { return nil }
        if (photo.hasWarp || photo.hasExtendedColor), source.alphaInfo == .first || source.alphaInfo == .last {
            // ImageIO may expose straight-alpha CGImages. Normalize those at
            // the boundary before a GPU sampler can interpolate hidden RGB.
            guard let normalized = premultiplied(source) else { return nil }
            source = normalized
        }
        guard let result = apply(photo, to: CIImage(cgImage: source)),
              let output = context.createCGImage(result, from: result.extent) else { return nil }
        return UIImage(cgImage: output, scale: image.scale, orientation: .up)
    }

    nonisolated private static func premultiplied(_ source: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
                bytesPerRow: source.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        bitmap.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return bitmap.makeImage()
    }
}
