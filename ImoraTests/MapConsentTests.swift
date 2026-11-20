import XCTest
import SwiftUI
import UIKit
import Synchronization
@testable import Imora

final class MapConsentTests: XCTestCase {
    func testMapServicesStartOffAndPersistOnlyExplicitChoice() {
        let name = "imora.maps.fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(MapServiceConsent.isEnabled(in: defaults))
        MapServiceConsent.setEnabled(true, in: defaults)
        XCTAssertTrue(MapServiceConsent.isEnabled(in: UserDefaults(suiteName: name)!))
        MapServiceConsent.setEnabled(false, in: defaults)
        XCTAssertFalse(MapServiceConsent.isEnabled(in: defaults))
    }

    @MainActor
    func testMapContentIsNotConstructedBeforeConsent() {
        let name = "imora.maps.fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let calls = Mutex(0)
        let gate = AppleMapConsentGate(defaults: defaults) {
            calls.withLock { $0 += 1 }
            return Text("fixture map content")
        }
        let blocked = ImageRenderer(content: gate.frame(width: 390, height: 844))
        XCTAssertNotNil(blocked.uiImage)
        XCTAssertEqual(calls.withLock { $0 }, 0)
        MapServiceConsent.setEnabled(true, in: defaults)
        let enabled = AppleMapConsentGate(defaults: defaults) {
            calls.withLock { $0 += 1 }
            return Text("fixture map content")
        }
        let rendered = ImageRenderer(content: enabled.frame(width: 390, height: 844))
        XCTAssertNotNil(rendered.uiImage)
        XCTAssertGreaterThan(calls.withLock { $0 }, 0)
    }

    @MainActor
    func testConsentLabelContrastsWithButtonInLightAndDarkAppearance() throws {
        for scheme in [ColorScheme.light, .dark] {
            let view = AppleMapsConsentButton {}
                .tint(.primary)
                .environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .frame(width: 240, height: 44)
            let renderer = ImageRenderer(content: view)
            let traits = UITraitCollection(userInterfaceStyle: scheme == .light ? .light : .dark)
            var image: CGImage?
            traits.performAsCurrent { image = renderer.uiImage?.cgImage }

            let cropped = try XCTUnwrap(image?.cropping(to: CGRect(x: 90, y: 10, width: 60, height: 24)))
            let context = try XCTUnwrap(CGContext(data: nil, width: cropped.width, height: cropped.height,
                bitsPerComponent: 8, bytesPerRow: cropped.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
            let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            var highContrastLabelPixels = 0
            var buttonBackgroundPixels = 0
            for offset in stride(from: 0, to: context.bytesPerRow * context.height, by: 4) where pixels[offset + 3] == 255 {
                let brightness = scheme == .light ? pixels[offset] : 255 - pixels[offset]
                if brightness > 220 { highContrastLabelPixels += 1 }
                if brightness < 35 { buttonBackgroundPixels += 1 }
            }
            XCTAssertGreaterThan(highContrastLabelPixels, 10, "Missing visible label in \(scheme) appearance")
            XCTAssertGreaterThan(buttonBackgroundPixels, cropped.width * cropped.height / 2,
                "Missing contrasting button background in \(scheme) appearance")
        }
    }
}
