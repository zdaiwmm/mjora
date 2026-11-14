import Foundation
import SwiftUI

/// privacy settings: what shared files carry beyond their pixels. the choice
/// is stored locally and applies at export time, when the share sheet
/// prepares its files.
struct PrivacyScreen: View {
    @AppStorage(MapServiceConsent.key) private var appleMapsEnabled = false
    @State private var policy = AssetShareMetadataPolicy.current

    var body: some View {
        List {
            Section {
                Toggle("Apple Maps", isOn: $appleMapsEnabled)
                    .accessibilityIdentifier("privacy-apple-maps")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(MapServiceConsent.notice)
                    Text("Photos stored in iCloud may still be downloaded from Apple when originals are needed for backup or cleanup.")
                }
            }
            Section {
                Picker("Shared Media", selection: Binding(
                    get: { policy },
                    set: { selected in
                        policy = selected
                        selected.options.persist()
                    }
                )) {
                    ForEach(AssetShareMetadataPolicy.allCases, id: \.self) { choice in
                        Text(choice.title)
                            .tag(choice)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Shared Media")
            } footer: {
                Text(policy.explanation)
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// the three way choice projected onto the stored option pair. the unused
/// fourth combination - metadata stripped but location kept - reads back as
/// removing all metadata.
nonisolated enum AssetShareMetadataPolicy: CaseIterable, Hashable {
    case everything
    case withoutLocation
    case withoutMetadata

    static var current: AssetShareMetadataPolicy {
        let options = AssetShareOptions.current
        if !options.includesAllMetadata { return .withoutMetadata }
        if !options.includesLocation { return .withoutLocation }
        return .everything
    }

    var options: AssetShareOptions {
        switch self {
        case .everything:
            AssetShareOptions(includesLocation: true, includesAllMetadata: true)
        case .withoutLocation:
            AssetShareOptions(includesLocation: false, includesAllMetadata: true)
        case .withoutMetadata:
            AssetShareOptions(includesLocation: false, includesAllMetadata: false)
        }
    }

    var title: String {
        switch self {
        case .everything: String(localized: "Keep Everything")
        case .withoutLocation: String(localized: "Remove Location")
        case .withoutMetadata: String(localized: "Remove All Metadata")
        }
    }

    var explanation: String {
        switch self {
        case .everything:
            String(localized: "Shared photos and videos keep all of their metadata, including location, capture date and camera information.")
        case .withoutLocation:
            String(localized: "Shared photos and videos are rewritten without their location. Everything else is kept.")
        case .withoutMetadata:
            String(localized: "Shared photos and videos are rewritten without any of their metadata, including location.")
        }
    }
}
