import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// The existing editor's unedited preview, held independently of the display
/// cache. This proxy cannot grant original-backup or cleanup eligibility.
struct PhotoEditInput {
    let image: UIImage
    private let file: ControlledMediaFile

    var isCurrent: Bool { (try? file.url) != nil }

    private nonisolated struct Decoded: @unchecked Sendable { let image: UIImage }

    static func load(detail: AssetDetail, client: ImoraClient, requiresElevation: Bool = false) async throws -> Self {
        guard detail.type == .image else { throw PhotoLibraryError.resourceMissing }
        let url = client.thumbnailURL(assetID: detail.id, size: "preview", edited: false, cacheKey: detail.checksum)
        let file = try await client.localMediaFile(url, role: .editInput,
            contentRevision: detail.checksum, requiresElevation: requiresElevation || detail.visibility == .locked)
        let decoded = try await decode(url: file.url)
        try Task.checkCancellation()
        _ = try file.url
        return .init(image: decoded.image, file: file)
    }

    @concurrent private static func decode(url: URL) async throws -> Decoded {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(source),
              UTType(identifier as String)?.conforms(to: .image) == true,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw PhotoLibraryError.resourceMissing }
        return .init(image: UIImage(cgImage: image))
    }
}
