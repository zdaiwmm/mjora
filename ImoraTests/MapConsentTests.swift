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
}
