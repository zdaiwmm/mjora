import Foundation
import Photos
import Synchronization
import UIKit
import XCTest
@testable import Imora

/// Run on the dedicated simulator with explicit Photos permission. Every byte
/// created here is synthetic; this test never deletes any existing library asset.
final class PhotoKitGateIntegrationTests: XCTestCase {
    func testRealPhotoKitZeroPartialAndDuplicateFetchNeverDeleteTheSyntheticPhoto() async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw XCTSkip("Grant full Photos access on the dedicated simulator for real PhotoKit gate checks.")
        }
        let jpeg = await MainActor.run { UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).jpegData(withCompressionQuality: 0.5) { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        } }
        let created = Mutex<String?>(nil)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: jpeg, options: nil)
            created.withLock { $0 = request.placeholderForCreatedAsset?.localIdentifier }
        }
        let id = try XCTUnwrap(created.withLock { $0 })
        let snapshot = await PhotoLibraryService.assetInfo(localIdentifier: id)
        let asset = try XCTUnwrap(snapshot)
        let missing = fixtureDevice(id: "missing-synthetic-\(UUID().uuidString)/L0/001")
        for expected in [[missing], [asset, missing], [asset, asset]] {
            do {
                _ = try await PhotoLibraryService.deleteVerified(expected, permitted: { true })
                XCTFail("A non-exact real PhotoKit fetch authorized deletion")
            } catch {}
            XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).count, 1)
        }
        // Leave this 16px fixture in the dedicated library for inspection.
        // No system confirmation was requested because no delete was submitted.
    }
}
