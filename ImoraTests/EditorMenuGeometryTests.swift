import SwiftUI
import UIKit
import XCTest
@testable import Imora

/// Glass can publish a shared accessibility rectangle for separate controls.
/// Real layout and native hit testing must remain independent of that metadata.
@MainActor
final class EditorMenuGeometryTests: XCTestCase {
    func testSharedGlassKeepsNativeMenuBoundsAndHitAreaSeparateFromAspectGlyph() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let measured = XCTestExpectation(description: "Aspect glyph is laid out in the visible hosting window")
        let geometry = EditorMenuGeometryMeasurement(measured: measured)
        let hosting = UIHostingController(rootView: EditorMenuGeometryFixture(geometry: geometry))
        window.rootViewController = hosting
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalKeyWindow?.makeKey()
        }
        window.makeKeyAndVisible()
        hosting.loadViewIfNeeded()
        window.layoutIfNeeded()
        hosting.view.layoutIfNeeded()
        let result = await XCTWaiter.fulfillment(of: [measured], timeout: 3)
        XCTAssertEqual(result, .completed)
        window.layoutIfNeeded()
        hosting.view.layoutIfNeeded()

        let button = try XCTUnwrap(nativeMenuButton(in: hosting.view))
        XCTAssertTrue(button.window === window)
        XCTAssertEqual(button.bounds.width, 40, accuracy: 0.01)
        XCTAssertEqual(button.bounds.height, 44, accuracy: 0.01)
        XCTAssertEqual(geometry.aspectFrame.width, 40, accuracy: 0.01)
        let physicalFrame = button.convert(button.bounds, to: window)
        XCTAssertGreaterThanOrEqual(physicalFrame.minX, geometry.aspectFrame.maxX + 1)
        let aspectCenter = CGPoint(x: geometry.aspectFrame.midX, y: geometry.aspectFrame.midY)
        let aspectInButton = button.convert(aspectCenter, from: window)
        XCTAssertFalse(button.point(inside: aspectInButton, with: nil), "More must not intercept a touch at the aspect glyph.")
        XCTAssertTrue(button.point(inside: CGPoint(x: button.bounds.midX, y: button.bounds.midY), with: nil))
        XCTAssertTrue(button.showsMenuAsPrimaryAction)
        XCTAssertNotNil(button.menu)

        // Record the platform's AX projection separately. It may be the whole
        // glass capsule even when the native bounds and touch target are not.
        XCTContext.runActivity(named: "Native layout and platform accessibility projection") { activity in
            let attachment = XCTAttachment(string: "Aspect layout: \(geometry.aspectFrame)\nNative button window frame: \(physicalFrame)\nNative button screen bounds: \(UIAccessibility.convertToScreenCoordinates(button.bounds, in: button))\nPublished AX frame: \(button.accessibilityFrame)")
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    private func nativeMenuButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == "edit-more" { return button }
        for child in view.subviews {
            if let button = nativeMenuButton(in: child) { return button }
        }
        return nil
    }
}

@MainActor
private final class EditorMenuGeometryMeasurement {
    let measured: XCTestExpectation
    var aspectFrame = CGRect.zero
    private var reported = false
    init(measured: XCTestExpectation) { self.measured = measured }
    func record(_ frame: CGRect) {
        aspectFrame = frame
        if frame.width > 0, !reported { reported = true; measured.fulfill() }
    }
}

@MainActor
private struct EditorMenuGeometryFixture: View {
    let geometry: EditorMenuGeometryMeasurement
    var body: some View {
        VStack {
            HStack {
                Spacer()
                EditorGlassGroup {
                    EditorGlassGlyph(systemImage: "aspectratio", label: "Aspect Ratio", action: {})
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { geometry.record($0) }
                    EditorMenuButton(systemImage: "ellipsis", label: "More", accessibilityIdentifier: "edit-more", actions: [
                        EditorMenuAction(identifier: "geometry-action", title: "Undo", systemImage: "arrow.uturn.backward", action: {}),
                    ])
                    .frame(width: 40, height: 44)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Spacer()
        }
        .transaction { $0.animation = nil }
    }
}
