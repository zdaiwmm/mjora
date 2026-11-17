import Foundation
import SwiftUI

/// One owner for connection status, mode selection and manual consent.
struct ManualServerRouteSection: View {
    @State private var confirmation: Confirmation?
    @State private var selectionTask: Task<Void, Never>?
    @State private var failure: String?

    private var router: LocalServerRouter { .shared }

    private struct Confirmation {
        let url: URL
        let revision: UInt64
        let verifiesIdentity: Bool
    }

    var body: some View {
        Section("Current Connection") {
            LabeledContent("Connected Through", value: statusText)
                .accessibilityIdentifier("server-route-status")
            if let endpoint = router.activeEndpoint {
                Text(endpoint.absoluteString)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("server-route-endpoint")
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
                    .accessibilityIdentifier("server-route-failure")
            }
            if router.status == .held {
                Text(holdText).foregroundStyle(.secondary)
                    .accessibilityIdentifier("server-route-hold-reason")
                if router.holdReason != .checking {
                    Button("Confirm Local Address") { selectMode(.local) }
                        .accessibilityIdentifier("server-route-retry-local")
                }
            }
            if router.isCheckingManualLocal || router.holdReason == .checking {
                ProgressView("Checking Local Address...")
            }
        }
        Section("Connection Mode") {
            Picker("Connection Mode", selection: Binding(
                get: { router.connectionMode }, set: selectMode
            )) {
                Text("Automatic Selection").tag(LocalServerRouter.ConnectionMode.automatic)
                    .accessibilityIdentifier("server-route-automatic")
                Text("Use External Address").tag(LocalServerRouter.ConnectionMode.external)
                    .accessibilityIdentifier("server-route-use-external")
                Text("Manual Local Network").tag(LocalServerRouter.ConnectionMode.local)
                    .accessibilityIdentifier("server-route-use-local")
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(router.isCheckingManualLocal || router.holdReason == .checking)
            .accessibilityIdentifier("server-route-mode")
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
            if confirmed.verifiesIdentity {
                Text("Use \(confirmed.url.absoluteString) on this Wi-Fi network? Imora will verify the server with the saved identity before connecting. Manual local mode never switches to the external address.")
            } else if confirmed.url.scheme?.lowercased() == "http" {
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

    private func selectMode(_ mode: LocalServerRouter.ConnectionMode) {
        selectionTask?.cancel()
        failure = nil
        switch mode {
        case .automatic:
            router.useAutomatic()
        case .external:
            router.useExternal()
        case .local:
            guard router.config?.isUsable == true, let url = router.config?.apiURL else {
                failure = String(localized: "Save a local address first.")
                return
            }
            guard router.canSelectManualLocal else {
                failure = String(localized: "Connect to Wi-Fi to select the local address.")
                return
            }
            confirmation = Confirmation(url: url, revision: router.selectionRevision,
                                        verifiesIdentity: router.config?.verifiedIdentity != nil)
        }
    }

    private var statusText: String {
        switch router.status {
        case .off, .external: String(localized: "External Address")
        case .checking: String(localized: "Checking...")
        case .held: String(localized: "Local Connection Paused")
        case .local:
            if router.isLocalIdentityVerified {
                router.isManualLocal ? String(localized: "Verified Local Address (Manual)") : String(localized: "Verified Local Address")
            } else {
                router.isManualLocal ? String(localized: "Local Address (Manual)") : String(localized: "Local Address")
            }
        }
    }

    private var holdText: String {
        switch router.holdReason {
        case .wifiRequired:
            String(localized: "Wi-Fi is unavailable. Local mode stays selected, and new connections are blocked. The external address will not be used.")
        case .confirmationRequired:
            String(localized: "The app returned from the background or the network changed. Confirm the local address to resume. The external address will not be used.")
        case .checking:
            String(localized: "Verifying the local server on this Wi-Fi network. Connections remain paused until verification succeeds.")
        case .unreachable:
            String(localized: "The verified local server did not answer. Local mode stays selected. Try again on your home Wi-Fi or choose the external address.")
        case nil:
            String(localized: "Local connections are paused. The external address will not be used.")
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
