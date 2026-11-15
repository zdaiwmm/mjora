import Foundation
@preconcurrency import Photos
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import UIKit

nonisolated struct LocalPhotoEditRecipe: Codable, Equatable, Sendable {
    static let formatIdentifier = "com.vexcited.imora.photo-editor"
    let version: Int
    let edits: [AssetEdit]
    let originalWidth: Int
    let originalHeight: Int

    init(edits: [AssetEdit], originalWidth: Int, originalHeight: Int) {
        version = 1; self.edits = edits; self.originalWidth = originalWidth; self.originalHeight = originalHeight
    }

    func adjustmentData() throws -> PHAdjustmentData {
        PHAdjustmentData(formatIdentifier: Self.formatIdentifier, formatVersion: "1", data: try JSONEncoder().encode(self))
    }
    static func decode(_ data: PHAdjustmentData) throws -> Self {
        guard data.formatIdentifier == formatIdentifier, data.formatVersion == "1" else { throw LocalPhotoEditorError.unsupportedRecipe }
        let recipe = try JSONDecoder().decode(Self.self, from: data.data)
        guard recipe.version == 1, recipe.originalWidth > 0, recipe.originalHeight > 0 else { throw LocalPhotoEditorError.unsupportedRecipe }
        guard recipe.edits.filter(\.isPhotoAdjustment).count <= 1 else { throw LocalPhotoEditorError.unsupportedRecipe }
        for edit in recipe.edits {
            switch edit {
            case .crop(let x, let y, let width, let height):
                guard x >= 0, y >= 0, width > 0, height > 0,
                      width <= recipe.originalWidth, height <= recipe.originalHeight,
                      x <= recipe.originalWidth - width, y <= recipe.originalHeight - height
                else { throw LocalPhotoEditorError.unsupportedRecipe }
            case .mirror(let axis):
                guard axis == "horizontal" || axis == "vertical" else { throw LocalPhotoEditorError.unsupportedRecipe }
            case .rotate(let angle):
                guard angle.isFinite, angle.truncatingRemainder(dividingBy: 90) == 0 else { throw LocalPhotoEditorError.unsupportedRecipe }
            case .other:
                guard edit.isPhotoAdjustment else { throw LocalPhotoEditorError.unsupportedRecipe }
                _ = try edit.photoAdjust()
            }
        }
        return recipe
    }
    static func canHandle(_ data: PHAdjustmentData) -> Bool { (try? decode(data)) != nil }
}

nonisolated enum LocalPhotoEditorError: LocalizedError {
    case unavailable, unsupportedMedia, unsupportedRecipe, noInput, rendering, changed
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "This photo is no longer accessible. Check Photos access in Settings.")
        case .unsupportedMedia: String(localized: "Local editing currently supports still photos. Live Photos and videos are not supported.")
        case .unsupportedRecipe: String(localized: "This photo has edits from another editor or a newer version. Revert those edits in Photos before editing here.")
        case .noInput: String(localized: "The original photo couldn't be loaded for editing.")
        case .rendering: String(localized: "The edited photo couldn't be rendered. Your changes are still here.")
        case .changed: String(localized: "This photo changed while you were editing. Close and reopen the editor to load its latest version.")
        }
    }
}

/// Owns PhotoKit's original input for one editing session. It never uploads,
/// replaces an original resource, or touches backup verification receipts.
@MainActor
final class LocalPhotoEditor {
    let localIdentifier: String
    let preview: UIImage
    let originalWidth: Int
    let originalHeight: Int
    let recipe: LocalPhotoEditRecipe
    private let input: PHContentEditingInput
    private let sourceURL: URL
    private let orientation: Int32
    private let modificationDate: Date?

    private init(id: String, input: PHContentEditingInput, url: URL, preview: UIImage, width: Int, height: Int,
                 recipe: LocalPhotoEditRecipe, modificationDate: Date?) {
        localIdentifier = id; self.input = input; sourceURL = url; orientation = input.fullSizeImageOrientation
        self.preview = preview; originalWidth = width; originalHeight = height
        self.recipe = recipe; self.modificationDate = modificationDate
    }

    private static func accessibleAsset(_ id: String) throws -> PHAsset {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              asset.canPerform(.content) else { throw LocalPhotoEditorError.unavailable }
        guard asset.mediaType == .image, !asset.mediaSubtypes.contains(.photoLive) else { throw LocalPhotoEditorError.unsupportedMedia }
        return asset
    }

    static func open(localIdentifier id: String) async throws -> LocalPhotoEditor {
        let asset = try accessibleAsset(id)
        guard asset.adjustmentFormatIdentifier == nil || asset.adjustmentFormatIdentifier == LocalPhotoEditRecipe.formatIdentifier else {
            throw LocalPhotoEditorError.unsupportedRecipe
        }
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = { @Sendable adjustment in LocalPhotoEditRecipe.canHandle(adjustment) }
        let input: PHContentEditingInput = try await withCheckedThrowingContinuation { continuation in
            asset.requestContentEditingInput(with: options) { @Sendable input, info in
                if let input { continuation.resume(returning: input) }
                else { continuation.resume(throwing: (info[PHContentEditingInputErrorKey] as? Error) ?? LocalPhotoEditorError.noInput) }
            }
        }
        guard let url = input.fullSizeImageURL else { throw LocalPhotoEditorError.noInput }
        let loaded = try await loadImage(url: url, orientation: input.fullSizeImageOrientation, maxPixelSize: 2048)
        let recipe: LocalPhotoEditRecipe
        if let adjustmentData = input.adjustmentData {
            recipe = try LocalPhotoEditRecipe.decode(adjustmentData)
        } else {
            guard asset.adjustmentFormatIdentifier == nil else { throw LocalPhotoEditorError.unsupportedRecipe }
            recipe = LocalPhotoEditRecipe(edits: [], originalWidth: loaded.width, originalHeight: loaded.height)
        }
        guard recipe.originalWidth == loaded.width, recipe.originalHeight == loaded.height else { throw LocalPhotoEditorError.changed }
        return LocalPhotoEditor(id: id, input: input, url: url, preview: loaded.image, width: loaded.width,
                                height: loaded.height, recipe: recipe, modificationDate: asset.modificationDate)
    }

    func save(edits: [AssetEdit]) async throws {
        let recipe = LocalPhotoEditRecipe(edits: edits, originalWidth: originalWidth, originalHeight: originalHeight)
        let adjustmentData = try recipe.adjustmentData()
        _ = try LocalPhotoEditRecipe.decode(adjustmentData)
        let output: PHContentEditingOutput?
        if edits.isEmpty {
            output = nil
        } else {
            let prepared = PHContentEditingOutput(contentEditingInput: input)
            prepared.adjustmentData = adjustmentData
            let destination = try prepared.renderedContentURL(for: .jpeg)
            try await Self.writeRendered(sourceURL: sourceURL, orientation: orientation, edits: edits,
                                         originalWidth: originalWidth, originalHeight: originalHeight, destination: destination)
            output = prepared
        }
        // Re-fetch after rendering/downloads so revoked limited access or a
        // concurrent Photos edit cannot silently authorize an old session.
        let asset = try Self.accessibleAsset(localIdentifier)
        guard asset.modificationDate == modificationDate else { throw LocalPhotoEditorError.changed }
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let request = PHAssetChangeRequest(for: asset)
            if let output { request.contentEditingOutput = output }
            else { request.revertAssetContentToOriginal() }
        }
    }

    private nonisolated struct LoadedImage: @unchecked Sendable {
        let image: UIImage
        let width: Int
        let height: Int
    }

    @concurrent
    private static func loadImage(url: URL, orientation: Int32, maxPixelSize: Int?) async throws -> LoadedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int else { throw LocalPhotoEditorError.noInput }
        guard CGImageSourceGetCount(source) == 1 else { throw LocalPhotoEditorError.unsupportedMedia }
        let cgImage: CGImage?
        if let maxPixelSize {
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: false,
            ] as CFDictionary)
        } else { cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) }
        guard let cgImage else { throw LocalPhotoEditorError.noInput }
        let oriented = CIImage(cgImage: cgImage).oriented(forExifOrientation: orientation)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let upright = context.createCGImage(oriented, from: oriented.extent) else { throw LocalPhotoEditorError.noInput }
        let swapsAxes = (5...8).contains(orientation)
        return LoadedImage(image: UIImage(cgImage: upright), width: swapsAxes ? rawHeight : rawWidth, height: swapsAxes ? rawWidth : rawHeight)
    }

    @concurrent
    private static func writeRendered(sourceURL: URL, orientation: Int32, edits: [AssetEdit],
                                      originalWidth: Int, originalHeight: Int, destination: URL) async throws {
        let loaded = try await loadImage(url: sourceURL, orientation: orientation, maxPixelSize: nil)
        let state = EditTransform.state(from: edits, originalWidth: originalWidth, originalHeight: originalHeight)
        let photo = try edits.compactMap { try $0.photoAdjust() }.last ?? .neutral
        guard let bytes = await AssetEditPreviewRenderer.projection(loaded.image, state: state, photo: photo),
              let cgImage = UIImage(data: bytes)?.cgImage,
              let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw LocalPhotoEditorError.rendering }
        var metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        metadata[kCGImagePropertyOrientation] = 1
        metadata[kCGImagePropertyPixelWidth] = cgImage.width
        metadata[kCGImagePropertyPixelHeight] = cgImage.height
        metadata.removeValue(forKey: kCGImagePropertyProfileName)
        metadata.removeValue(forKey: kCGImagePropertyColorModel)
        metadata.removeValue(forKey: kCGImagePropertyDepth)
        var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = 1
        metadata[kCGImagePropertyTIFFDictionary] = tiff
        var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension] = cgImage.width
        exif[kCGImagePropertyExifPixelYDimension] = cgImage.height
        metadata[kCGImagePropertyExifDictionary] = exif
        metadata[kCGImageDestinationLossyCompressionQuality] = 0.95
        CGImageDestinationAddImage(writer, cgImage, metadata as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw LocalPhotoEditorError.rendering }
    }
}
