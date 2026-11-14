import Foundation
import SwiftUI

/// Shared by Backup and Local Network so route status and actions agree.
struct ManualServerRouteSection: View {
    var showsConfigurationLink = true

    @State private var confirmation: Confirmation?
    @State private var selectionTask: Task<Void, Never>?
    @State private var failure: String?

    private var router: LocalServerRouter { .shared }

    private struct Confirmation {
        let url: URL
        let revision: UInt64
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Connected Through", value: statusText)
                    .accessibilityIdentifier("server-route-status")
                if let endpoint = router.activeEndpoint {
                    Text(endpoint.absoluteString)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("server-route-endpoint")
                }
            }

            Button {
                guard let url = router.config?.apiURL else { return }
                failure = nil
                confirmation = Confirmation(url: url, revision: router.selectionRevision)
            } label: {
                if router.isCheckingManualLocal {
                    HStack {
                        ProgressView()
                        Text("Checking Local Address...")
                    }
                } else {
                    Label("Use Local Now", systemImage: "wifi")
                }
            }
            .disabled(!router.canSelectManualLocal || router.isCheckingManualLocal || router.isManualLocal)
            .accessibilityIdentifier("server-route-use-local")

            Button {
                selectionTask?.cancel()
                router.useExternal()
                failure = nil
            } label: {
                Label("Use External Address", systemImage: "network")
            }
            .accessibilityIdentifier("server-route-use-external")

            if showsConfigurationLink, router.config?.isUsable != true {
                NavigationLink {
                    LocalNetworkScreen()
                } label: {
                    Label("Configure Local Address", systemImage: "gear")
                }
                .accessibilityIdentifier("server-route-configure-local")
            }
        } header: {
            Text("Current Connection")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let failure {
                    Text(failure)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("server-route-failure")
                }
                if router.config?.isUsable != true {
                    Text("Enable and save a local address to select it here.")
                } else if !router.canSelectManualLocal {
                    Text("Connect to Wi-Fi to select the local address.")
                }
                Text("Manual choices reset when the network, account, or local settings change, or when you return to the app. Manual local connections do not switch to the external address on failure.")
            }
        }
        .alert("Use This Local Address?", isPresented: Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        ), presenting: confirmation) { confirmed in
            Button("Use Local Now") {
                select(confirmed)
            }
            .accessibilityIdentifier("server-route-confirm-local")
            Button("Cancel", role: .cancel) {}
        } message: { confirmed in
            if confirmed.url.scheme?.lowercased() == "http" {
                Text("Use \(confirmed.url.absoluteString) on this Wi-Fi network? HTTP sends photos and account credentials without encryption. A ping checks reachability only and does not verify server identity.")
            } else {
                Text("Use \(confirmed.url.absoluteString) on this Wi-Fi network? A ping checks reachability only and does not verify server identity.")
            }
        }
        .onDisappear {
            selectionTask?.cancel()
            router.cancelManualSelection()
        }
    }

    private var statusText: String {
        switch router.status {
        case .off, .external: String(localized: "External Address")
        case .checking: String(localized: "Checking...")
        case .local:
            router.isManualLocal ? String(localized: "Local Address (Manual)") : String(localized: "Local Address")
        }
    }

    private func select(_ confirmed: Confirmation) {
        selectionTask?.cancel()
        failure = nil
        selectionTask = Task {
            let result = await router.requestManualLocal(confirmedURL: confirmed.url, revision: confirmed.revision)
            guard !Task.isCancelled else { return }
            switch result {
            case .selected:
                break
            case .unavailable:
                failure = String(localized: "Local address unavailable. The connection was not changed. Check the saved address and Wi-Fi connection.")
            case .unreachable:
                failure = String(localized: "The local address did not answer. The connection was not changed.")
            case .superseded:
                failure = String(localized: "The network, account, or settings changed. The local address was not selected.")
            }
        }
    }
}
