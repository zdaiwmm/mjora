import XCTest
import UIKit
import Photos
import Synchronization
import CoreImage
@testable import Imora

@MainActor
final class UnifiedPhotoEditorTests: XCTestCase {
    func testPhotoParametersDecodeMissingMembersAndRejectUnsupportedOrOutOfRange() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(PhotoAdjust.self, from: Data("{\"version\":1}".utf8)), .neutral)
        for json in ["{\"version\":2}", "{\"version\":1,\"warmth\":null}", "{\"version\":1,\"warmth\":101}", "{\"version\":1,\"straighten\":46}", "{\"version\":1,\"horizontalPerspective\":1.1}"] {
            XCTAssertThrowsError(try decoder.decode(PhotoAdjust.self, from: Data(json.utf8)))
        }
    }

    func testCompleteEditIntentRoundTripsAndPreservesUnknownActions() throws {
        var photo = PhotoAdjust.neutral
        photo.exposure = -10; photo.contrast = 14; photo.saturation = -19; photo.invert = true
        photo.highlights = 23; photo.shadows = -27
        photo.brightness = 31; photo.blackPoint = 9; photo.warmth = -15; photo.tint = 18
        photo.straighten = 12; photo.horizontalPerspective = 0.4; photo.verticalPerspective = -0.2
        let unknown = AssetEdit.other(action: "future", parameters: .object(["value": .number(7)]))
        let edits: [AssetEdit] = [.crop(x: 1, y: 2, width: 3, height: 4), unknown, try .photo(photo)]
        let decoded = try JSONDecoder().decode([AssetEdit].self, from: JSONEncoder().encode(edits))
        XCTAssertEqual(decoded, edits)
        XCTAssertEqual(try decoded.last?.photoAdjust(), photo)
        XCTAssertEqual(decoded.filter { !$0.isPhotoAdjustment }, Array(edits.dropLast()))
    }

    func testColorFixtureAppliesEveryStageInTheSharedOrder() {
        var photo = PhotoAdjust.neutral
        photo.saturation = 20; photo.invert = true; photo.exposure = -10
        photo.highlights = 25; photo.shadows = -30; photo.brightness = 10
        photo.blackPoint = 15; photo.warmth = -20; photo.tint = 30; photo.contrast = 12
        let rgb = PhotoAdjustMath.color(red: 0.2, green: 0.4, blue: 0.8, adjust: photo)
        XCTAssertEqual(rgb.0, 0.8294362548830418, accuracy: 0.0000001)
        XCTAssertEqual(rgb.1, 0.5259011197479067, accuracy: 0.0000001)
        XCTAssertEqual(rgb.2, 0.11203084947763631, accuracy: 0.0000001)
    }

    func testWarpKeepsAllCornersInsideSourceAndNeutralIsIdentity() {
        XCTAssertEqual(PhotoAdjustMath.inverseSample(u: 0.3, v: -0.7, adjust: .neutral).x, 0.3, accuracy: 1e-12)
        for degrees in [-45.0, -12, 0, 19, 45] {
            var photo = PhotoAdjust.neutral
            photo.straighten = degrees; photo.horizontalPerspective = 1; photo.verticalPerspective = -1
            for u in [-1.0, 1] { for v in [-1.0, 1] {
                let p = PhotoAdjustMath.inverseSample(u: u, v: v, adjust: photo)
                XCTAssertLessThanOrEqual(abs(p.x), 1.0000001)
                XCTAssertLessThanOrEqual(abs(p.y), 1.0000001)
            } }
        }
    }

    func testGPUColorMatchesTheSharedNumericalFixtureAndWarpNeverAddsTransparentCorners() throws {
        let bytes = Data([51, 102, 204, 255])
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = CIImage(bitmapData: bytes, bytesPerRow: 4, size: CGSize(width: 1, height: 1), format: .RGBA8, colorSpace: srgb)
        var photo = PhotoAdjust.neutral
        photo.saturation = 20; photo.invert = true; photo.exposure = -10
        photo.highlights = 25; photo.shadows = -30; photo.brightness = 10
        photo.blackPoint = 15; photo.warmth = -20; photo.tint = 30; photo.contrast = 12
        let result = try XCTUnwrap(ImageAdjustRenderer.apply(photo, to: image))
        let context = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(result, toBitmap: &pixel, rowBytes: 4, bounds: image.extent, format: .RGBA8, colorSpace: srgb)
        for (actual, expected) in zip(pixel, [212, 134, 29, 255]) {
            XCTAssertLessThanOrEqual(abs(Int(actual) - expected), 1)
        }
        let opaque = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 9, height: 7))
        photo.straighten = 45; photo.horizontalPerspective = 1; photo.verticalPerspective = -1
        let warped = try XCTUnwrap(ImageAdjustRenderer.apply(photo, to: opaque))
        var pixels = [UInt8](repeating: 0, count: 9 * 7 * 4)
        context.render(warped, toBitmap: &pixels, rowBytes: 9 * 4, bounds: opaque.extent, format: .RGBA8, colorSpace: srgb)
        for index in stride(from: 3, to: pixels.count, by: 4) { XCTAssertEqual(pixels[index], 255) }
    }

    func testUnknownAtomicResponseIsReadBackWithoutASecondWrite() async throws {
        var stored: [AssetEdit] = []
        var writes = 0
        let intent: [AssetEdit] = [.rotate(angle: 90), try .photo(.neutral)]
        try await PhotoEditPersistence.saveAtomic(intent: intent, write: {
            writes += 1; stored = $0
            throw URLError(.networkConnectionLost)
        }, read: { stored })
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(stored, intent)
    }

    func testWarpInterpolatesPremultipliedAlphaWithoutHiddenColorBleeding() throws {
        // A transparent red neighbor must not tint the visible blue edge.
        let data = Data([255, 0, 0, 0, 0, 0, 255, 255])
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let cgImage = try XCTUnwrap(CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        var photo = PhotoAdjust.neutral; photo.horizontalPerspective = 1
        let rendered = try XCTUnwrap(ImageAdjustRenderer.render(UIImage(cgImage: cgImage), photo: photo))
        let warped = CIImage(cgImage: try XCTUnwrap(rendered.cgImage))
        let context = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb, .outputPremultiplied: false])
        var pixels = [Float](repeating: 0, count: 8)
        context.render(warped, toBitmap: &pixels, rowBytes: 2 * 4 * MemoryLayout<Float>.size,
                       bounds: warped.extent, format: .RGBAf, colorSpace: srgb)
        // Right output inverse-samples source x=.8. Premultiplied color and
        // alpha are both .8 blue, so straight output stays pure blue.
        XCTAssertEqual(pixels[4], 0, accuracy: 0.002)
        XCTAssertEqual(pixels[6], 1, accuracy: 0.002)
        XCTAssertEqual(pixels[7], 0.8, accuracy: 0.002)
    }

    func testUnknownAtomicResponseWithDifferentReadBackRetainsFailure() async throws {
        do {
            try await PhotoEditPersistence.saveAtomic(intent: [.rotate(angle: 90)], write: { _ in
                throw URLError(.timedOut)
            }, read: { [] })
            XCTFail("A different stored intent must not count as saved")
        } catch { XCTAssertTrue(error is PhotoEditPersistence.SaveError) }
    }

    func testLegacySecondWriteFailureReportsPartialCommitRatherThanRollback() async throws {
        var storedAdjust = ImageAdjust.neutral
        var desired = ImageAdjust.neutral; desired.exposure = 50
        do {
            try await PhotoEditPersistence.saveLegacy(adjust: desired, edits: [.rotate(angle: 90)],
                writeAdjust: { storedAdjust = $0 }, writeEdits: { _ in throw URLError(.timedOut) },
                readAdjust: { storedAdjust }, readEdits: { [] })
            XCTFail("Partial legacy save must stay in the editor")
        } catch let error as PhotoEditPersistence.SaveError {
            XCTAssertEqual(error, .partialOrUnconfirmed)
        }
        XCTAssertEqual(storedAdjust, desired)
    }

    func testLegacyLostResponseAcceptsOnlyCompleteAuthoritativeState() async throws {
        var storedEdits: [AssetEdit] = []
        var desired = ImageAdjust.neutral; desired.exposure = 50
        try await PhotoEditPersistence.saveLegacy(adjust: desired, edits: [.rotate(angle: 90)],
            writeAdjust: { _ in }, writeEdits: { storedEdits = $0; throw URLError(.timedOut) },
            readAdjust: { desired }, readEdits: { storedEdits })
        XCTAssertEqual(storedEdits, [.rotate(angle: 90)])
    }

    func testEnhancedHTTPUsesOneCompletePutAndReadbackAfterUnknownServerOutcome() async throws {
        let stored = Mutex<[AssetEdit]>([])
        let server = try LocalHTTPServer { request in
            if request.path == "/api/server/version" {
                return .init(body: Data(#"{"major":5,"minor":7,"patch":0,"product":"imora","features":["adjust"]}"#.utf8))
            }
            if request.path == "/api/server/features" { return .init(body: Data(#"{"photoEditsV1":true}"#.utf8)) }
            if request.path == "/api/assets/synthetic/edits" {
                if request.method == "PUT" {
                    struct Envelope: Decodable { let edits: [AssetEdit] }
                    guard let decoded = try? JSONDecoder().decode(Envelope.self, from: request.body) else { return .init(status: 400) }
                    stored.withLock { $0 = decoded.edits }
                    // The transaction committed but the server failed to deliver
                    // its normal success response. The client must read back.
                    return .init(status: 503)
                }
                if request.method == "GET" {
                    return .init(body: try! JSONEncoder().encode(["edits": stored.withLock { $0 }]))
                }
            }
            return .init(status: 404)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-editor")
        defer { client.invalidate() }
        var photo = PhotoAdjust.neutral; photo.warmth = 16
        let intent: [AssetEdit] = [.crop(x: 2, y: 3, width: 12, height: 8), .mirror(axis: "horizontal"), .rotate(angle: 90), try .photo(photo)]
        try await client.savePhotoEdits(id: "synthetic", edits: intent)
        XCTAssertEqual(stored.withLock { $0 }, intent)
        let requests = server.received
        XCTAssertEqual(requests.filter { $0.method == "PUT" }.count, 1)
        XCTAssertEqual(requests.filter { $0.method == "GET" && $0.path == "/api/assets/synthetic/edits" }.count, 1)
        XCTAssertFalse(requests.contains { $0.path.hasSuffix("/adjust") })
    }

    func testVersionAloneNeverEnablesEnhancedHTTPMutation() async throws {
        let server = try LocalHTTPServer { request in
            if request.path == "/api/server/version" {
                return .init(body: Data(#"{"major":999,"minor":0,"patch":0,"product":"imora","features":["adjust"]}"#.utf8))
            }
            if request.path == "/api/server/features" { return .init(body: Data("{}".utf8)) }
            return .init(status: 404)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-editor")
        defer { client.invalidate() }
        do { try await client.savePhotoEdits(id: "synthetic", edits: [.rotate(angle: 90)]); XCTFail() }
        catch {}
        XCTAssertFalse(server.received.contains { $0.method == "PUT" || $0.method == "DELETE" })
    }

    func testLocalRecipeIsVersionedAndReopensEveryParameter() throws {
        var photo = PhotoAdjust.neutral; photo.tint = -23; photo.verticalPerspective = 0.6
        let recipe = LocalPhotoEditRecipe(edits: [.mirror(axis: "horizontal"), try .photo(photo)], originalWidth: 4000, originalHeight: 3000)
        let adjustment = try recipe.adjustmentData()
        XCTAssertTrue(LocalPhotoEditRecipe.canHandle(adjustment))
        XCTAssertEqual(try LocalPhotoEditRecipe.decode(adjustment), recipe)
        XCTAssertFalse(LocalPhotoEditRecipe.canHandle(PHAdjustmentData(formatIdentifier: "other", formatVersion: "1", data: adjustment.data)))
        XCTAssertFalse(LocalPhotoEditRecipe.canHandle(PHAdjustmentData(formatIdentifier: LocalPhotoEditRecipe.formatIdentifier, formatVersion: "2", data: adjustment.data)))
    }

    func testEnhancedRendererKeepsLegacyNeutralExtensionPixelsAndDimensions() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6), format: format).image { context in
            UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
        var adjust = ImageAdjust.neutral; adjust.exposure = 10; adjust.contrast = -20; adjust.saturation = -25; adjust.invert = true
        let legacy = try XCTUnwrap(ImageAdjustRenderer.render(image, adjust: adjust))
        let unified = try XCTUnwrap(ImageAdjustRenderer.render(image, photo: PhotoAdjust(legacy: adjust)))
        XCTAssertEqual(legacy.pngData(), unified.pngData())
        var photo = PhotoAdjust.neutral; photo.straighten = 18; photo.horizontalPerspective = 0.5
        let warped = try XCTUnwrap(ImageAdjustRenderer.render(image, photo: photo))
        XCTAssertEqual(warped.size, image.size)
    }
    func testPhotoKitSaveReopenAndRevertNeverChangeOriginalResourceBytes() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw XCTSkip("Grant Photos access on the dedicated simulator for the synthetic local editor test.")
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 14), format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 14))
        }
        let created = Mutex<String?>(nil)
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: jpeg, options: nil)
            created.withLock { $0 = request.placeholderForCreatedAsset?.localIdentifier }
        }
        let id = try XCTUnwrap(created.withLock { $0 })
        // PhotoKit can normalize metadata during initial ingestion. The
        // preservation boundary is its original resource before editing.
        let originalBeforeSave = try await originalBytes(id)
        let editor = try await LocalPhotoEditor.open(localIdentifier: id)
        var photo = PhotoAdjust.neutral; photo.exposure = -35; photo.tint = 16; photo.straighten = 8
        let edits: [AssetEdit] = [.crop(x: 2, y: 2, width: 12, height: 8), try .photo(photo)]
        try await editor.save(edits: edits)
        let reopened = try await LocalPhotoEditor.open(localIdentifier: id)
        XCTAssertEqual(reopened.recipe.edits, edits)
        XCTAssertEqual(reopened.originalWidth, 20)
        let savedAsset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
        XCTAssertEqual(savedAsset.pixelWidth, 12)
        XCTAssertEqual(savedAsset.pixelHeight, 8)
        let originalAfterSave = try await originalBytes(id)
        XCTAssertEqual(originalAfterSave, originalBeforeSave)
        try await reopened.save(edits: [])
        let reverted = try await LocalPhotoEditor.open(localIdentifier: id)
        XCTAssertEqual(reverted.recipe.edits, [])
        let originalAfterRevert = try await originalBytes(id)
        XCTAssertEqual(originalAfterRevert, originalBeforeSave)
        XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).count, 1)
    }

    private func originalBytes(_ id: String) async throws -> Data {
        let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
        let resource = try XCTUnwrap(PHAssetResource.assetResources(for: asset).first { $0.type == .photo })
        let bytes = Mutex<Data>(Data())
        return try await withCheckedThrowingContinuation { continuation in
            PHAssetResourceManager.default().requestData(for: resource, options: nil, dataReceivedHandler: { @Sendable chunk in
                bytes.withLock { $0.append(chunk) }
            }, completionHandler: { @Sendable error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: bytes.withLock { $0 }) }
            })
        }
    }

}
