import SwiftUI
import UIKit
import XCTest
@testable import Imora

@MainActor
final class BackupProgressPresentationTests: XCTestCase {
    func testCurrentFilesPresentationWithMeasuredSpeed() throws {
        var transfers = ActiveBackupTransfers()
        let preparing = transfers.begin(localIdentifier: "synthetic-preparing")
        transfers.apply(.init(sequence: 1, filename: "Synthetic large original.mov", stage: .preparing, fraction: nil),
            localIdentifier: "synthetic-preparing", attempt: preparing)
        let uploading = transfers.begin(localIdentifier: "synthetic-uploading")
        let taskID = UUID()
        let now = ProcessInfo.processInfo.systemUptime
        var meter = UploadTransferMeter()
        meter.record(.init(transferID: taskID, bytesSent: 1_000, totalBytesSent: 1_000,
            totalBytesExpectedToSend: 1_000_000, timestamp: now - 2))
        meter.record(.init(transferID: taskID, bytesSent: 256_000, totalBytesSent: 257_000,
            totalBytesExpectedToSend: 1_000_000, timestamp: now - 1))
        transfers.apply(.init(sequence: 1, filename: "示例视频 — Synthetic clip.mp4", stage: .uploading,
            fraction: 0.42, meter: meter), localIdentifier: "synthetic-uploading", attempt: uploading)
        let verifying = transfers.begin(localIdentifier: "synthetic-verifying")
        transfers.apply(.init(sequence: 1, filename: "Synthetic Live Photo.HEIC", stage: .verifying, fraction: nil),
            localIdentifier: "synthetic-verifying", attempt: verifying)
        let controller = UIHostingController(rootView: List {
            Section { ActiveBackupTransfersView(transfers: transfers) }
        }.listStyle(.insetGrouped))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 820))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds)
        let screenshot = renderer.image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(screenshot.size.width, 393)
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "current-files-progress-and-speed"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
