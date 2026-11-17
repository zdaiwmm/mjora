import Foundation
import SwiftUI

struct LocalNetworkScreen: View {
    private var router: LocalServerRouter { .shared }

    var body: some View {
        List {
            ManualServerRouteSection()
            Section("Local Configuration") {
                NavigationLink {
                    LocalNetworkAddressScreen()
                } label: {
                    LabeledContent("Local Address", value: router.config?.apiURL?.host() ?? String(localized: "Not Configured"))
                }
                .accessibilityIdentifier("local-network-address-settings")
                NavigationLink {
                    LocalNetworkIdentityScreen()
                } label: {
                    LabeledContent("Connection Verification", value: router.config?.verifiedIdentity == nil
                                   ? String(localized: "Not Verified") : String(localized: "Saved Server Identity"))
                }
                .accessibilityIdentifier("local-network-verification")
            }
            Section {
                NavigationLink("Wi-Fi Networks") { LocalNetworkWiFiScreen() }
                    .accessibilityIdentifier("local-network-wifi-settings")
            }
        }
        .navigationTitle("Local Network")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LocalNetworkAddressScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var addressInvalid = false

    var body: some View {
        List {
            Section {
                TextField("Server Address", text: $address, prompt: Text(verbatim: "https://192.168.1.10:2283"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(saveAddress)
                    .accessibilityIdentifier("local-network-address")
            } footer: {
                if addressInvalid {
                    Text("Enter an HTTP or HTTPS address.").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Local Address")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: saveAddress)
                    .accessibilityIdentifier("local-network-save-address")
            }
        }
        .onAppear {
            let url = LocalServerRouter.shared.config?.apiURL
            address = url.map { ($0.lastPathComponent == "api" ? $0.deletingLastPathComponent() : $0).absoluteString } ?? ""
        }
    }

    private func saveAddress() {
        guard let server = session.client?.apiURL else { return }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = LocalServerConfig.apiURL(from: trimmed)
        guard trimmed.isEmpty || url != nil else {
            addressInvalid = true
            return
        }
        var config = LocalServerRouter.shared.config ?? LocalServerConfig(server: server)
        config.apiURL = url
        config.isEnabled = url != nil
        LocalServerRouter.shared.update(config)
        dismiss()
    }
}

private struct LocalNetworkIdentityScreen: View {
    private var router: LocalServerRouter { .shared }

    var body: some View {
        List {
            Section {
                LabeledContent("Server Identity", value: identityState)
                    .accessibilityIdentifier("local-network-identity-state")
            }
            if let identity = router.config?.verifiedIdentity {
                Section("CA Certificate SHA-256") {
                    Text(identity.fingerprint)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("local-network-identity-fingerprint")
                }
            }
        }
        .navigationTitle("Connection Verification")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var identityState: String {
        if router.isLocalIdentityVerified { return String(localized: "Verified Connection") }
        if router.config?.verifiedIdentity != nil { return String(localized: "Saved Server Identity") }
        return router.config?.identity == nil ? String(localized: "No Server Identity Installed")
            : String(localized: "Invalid Server Identity")
    }
}

private struct LocalNetworkWiFiScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var newNetwork = ""
    @State private var isAddingNetwork = false
    @State private var isReadingNetwork = false
    @State private var networkUnavailable = false
    private var router: LocalServerRouter { .shared }
    private var networks: [String] { router.config?.networks ?? [] }

    var body: some View {
        List {
            Section {
                ForEach(networks, id: \.self) { Text($0) }
                    .onDelete { offsets in edit { $0.networks.remove(atOffsets: offsets) } }
                if networks.isEmpty { Text("No Wi-Fi Networks").foregroundStyle(.secondary) }
            }
            Section {
                Button("Add Current Network", systemImage: "wifi") {
                    Task { await addCurrentNetwork() }
                }
                .disabled(isReadingNetwork)
                Button("Add Network by Name", systemImage: "plus") { isAddingNetwork = true }
                if router.isLocationDenied {
                    Button("Open Settings", systemImage: "gear") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
        }
        .navigationTitle("Wi-Fi Networks")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Add Network", isPresented: $isAddingNetwork) {
            TextField("Wi-Fi Name", text: $newNetwork)
            Button("Add") { add(newNetwork); newNetwork = "" }
            Button("Cancel", role: .cancel) { newNetwork = "" }
        }
        .alert("No Wi-Fi Network", isPresented: $networkUnavailable) {
            Button("OK", role: .cancel) {}
        }
    }

    private func edit(_ change: (inout LocalServerConfig) -> Void) {
        guard let server = session.client?.apiURL else { return }
        var config = router.config ?? LocalServerConfig(server: server)
        change(&config)
        router.update(config)
    }

    private func add(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !networks.contains(name) else { return }
        edit { $0.networks.append(name) }
    }

    private func addCurrentNetwork() async {
        isReadingNetwork = true
        defer { isReadingNetwork = false }
        if let name = await router.currentNetworkName() { add(name) }
        else if !router.isLocationDenied { networkUnavailable = true }
    }
}
