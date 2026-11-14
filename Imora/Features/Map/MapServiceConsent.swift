import Foundation
import SwiftUI

nonisolated enum MapServiceConsent {
    static let key = "imora.maps.appleServicesAllowed"
    static let notice = String(localized: "Using Apple Maps can send viewed map areas and place searches to Apple. Browsing your library and backing up photos work with Maps off.")
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key) }
    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) { defaults.set(enabled, forKey: key) }
}

/// Keep the closure lazy: merely navigating a library/info page must not
/// instantiate MapKit content before the user chooses to use Apple services.
struct AppleMapConsentGate<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage private var enabled: Bool
    private let content: () -> Content

    init(defaults: UserDefaults = .standard, @ViewBuilder content: @escaping () -> Content) {
        _enabled = AppStorage(wrappedValue: false, MapServiceConsent.key, store: defaults)
        self.content = content
    }

    var body: some View {
        if enabled { content() }
        else {
            VStack(spacing: 20) {
                Image(systemName: "map").font(.largeTitle).foregroundStyle(.secondary)
                Text("Use Apple Maps?").font(.title2.weight(.semibold))
                Text(MapServiceConsent.notice).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Enable Apple Maps") { enabled = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("apple-maps-enable")
                Button("Not Now", role: .cancel) { dismiss() }
                    .accessibilityIdentifier("apple-maps-later")
            }
            .padding(32)
            .frame(maxWidth: 460, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
            .navigationTitle("Map")
        }
    }
}

struct MapPreviewGate<Content: View>: View {
    @AppStorage(MapServiceConsent.key) private var enabled = false
    @ViewBuilder let content: () -> Content
    var body: some View {
        if enabled { content() }
        else {
            ZStack {
                Color.secondary.opacity(0.08)
                Label("Map Preview Is Off", systemImage: "map")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityLabel("Map preview is off. Open the map to enable Apple Maps.")
        }
    }
}
