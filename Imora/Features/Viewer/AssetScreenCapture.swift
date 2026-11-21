import Foundation
import Photos

/// photos fits screenshots and screen recordings between its bars,
/// `-[PUOneUpViewController _insetModeForAsset:]` on `mediaSubtypes & 0x80004`.
@MainActor
enum AssetScreenCapture {
    private static var known: [String: Bool] = [:]

    /// gallery's screenshot names, plus the name ios gives screen recordings.
    private static let namePattern = try? NSRegularExpression(
        pattern: "screen ?shot|screen ?recording|rpreplay|bildschirmfoto|capture d.écran|schermafbeelding|captura de pantalla|截屏|スクリーンショット",
        options: [.caseInsensitive]
    )

    /// Synchronous reads are metadata-only. The viewer body calls this
    /// repeatedly, so no lookup may wait on Photos.sqlite.
    static func value(for asset: Asset) -> Bool? {
        if let value = known[asset.id] { return value }
        return asset.isScreenshot == true ? true : nil
    }

    /// Resolve the remaining subtype off the main actor. Keeping this out of
    /// `value(for:)` prevents large-library or backup contention from blocking
    /// SwiftUI layout long enough for the scene-update watchdog.
    static func load(for asset: Asset, localIdentifier: String?) async -> Bool? {
        if let value = value(for: asset) { return value }
        guard let localIdentifier, canReadLibrary else { return asset.isScreenshot }
        let value = await localValue(localIdentifier)
        known[asset.id] = value
        return value
    }

    @concurrent
    private static func localValue(_ localIdentifier: String) async -> Bool {
        let library = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        return library?.mediaSubtypes.isDisjoint(with: [.photoScreenshot, .videoScreenRecording]) == false
    }

    /// a server asset off this device has no subtypes, so its name, or a png
    /// no camera took, stands in for them.
    @discardableResult
    static func record(_ detail: AssetDetail) -> Bool {
        let name = detail.originalFileName
        let range = NSRange(name.startIndex..., in: name)
        let named = namePattern?.firstMatch(in: name, range: range) != nil
        let camera = [detail.exifInfo?.make, detail.exifInfo?.model]
            .contains { !($0 ?? "").isEmpty }
        let png = detail.originalMimeType == "image/png" || name.lowercased().hasSuffix(".png")
        let value = named || (detail.type == .image && png && !camera)
        known[detail.id] = value
        return value
    }

    private static var canReadLibrary: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }
}
