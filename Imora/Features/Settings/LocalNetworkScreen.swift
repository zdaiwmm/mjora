import Foundation
import SwiftUI

/// A saved address for the same server, selected automatically on listed
/// Wi-Fi networks or manually after confirmation without reading an SSID.
struct LocalNetworkScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL

    @State private var address = ""
    @State private var addressInvalid = false
    @State private var newNetwork = ""
    @State private var isAddingNetwork = false
    @State private var isReadingNetwork = false
    @State private var networkUnavailable = false
    @FocusState private var addressFocused: Bool

    private var router: LocalServerRouter { .shared }
    private var config: LocalServerConfig? { router.config }
    private var isEnabled: Bool { config?.isEnabled ?? false }
    private var networks: [String] { config?.networks ?? [] }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { isEnabled },
                    set: { enabled in edit { $0.isEnabled = enabled } }
                )) {
                    Label("Use Local Address", systemImage: "wifi")
                }
            } footer: {
                Text("Configure verified automatic selection below, or choose Use Local Now. Both addresses use the same account and photo cache.")
            }

            ManualServerRouteSection(showsConfigurationLink: false)

            if isEnabled {
                Section {
                    TextField("http://192.168.1.10:2283", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($addressFocused)
                        .onSubmit(saveAddress)
                        .accessibilityIdentifier("local-network-address")
                } header: {
                    Text("Local Address")
                } footer: {
                    if addressInvalid {
                        Text("Enter an HTTP or HTTPS address.")
                            .foregroundStyle(.red)
                    }
                }

                identitySection

                Section {
                    ForEach(networks, id: \.self) { name in
                        Text(name)
                    }
                    .onDelete { offsets in
                        edit { $0.networks.remove(atOffsets: offsets) }
                    }
                    Button {
                        Task { await addCurrentNetwork() }
                    } label: {
                        Label("Add Current Network", systemImage: "wifi")
                    }
                    .disabled(isReadingNetwork)
                    Button {
                        isAddingNetwork = true
                    } label: {
                        Label("Add Network by Name", systemImage: "plus")
                    }
                    if router.isLocationDenied {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        } label: {
                            Label("Open Settings", systemImage: "gear")
                        }
                    }
                } header: {
                    Text("Wi-Fi Networks")
                } footer: {
                    Text(router.isLocationDenied
                        ? String(localized: "Reading Wi-Fi names for the network-name method needs precise location access. Verified automatic selection and Use Local Now work without it.")
                        : String(localized: "Reading the Wi-Fi name needs location access. Wi-Fi names and ping responses select a saved route; they do not verify server identity. HTTP sends photos and account credentials without transport encryption."))
                }
            }
        }
        .navigationTitle("Local Network")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Add Network", isPresented: $isAddingNetwork) {
            TextField("Wi-Fi Name", text: $newNetwork)
            Button("Add") {
                add(newNetwork)
                newNetwork = ""
            }
            Button("Cancel", role: .cancel) { newNetwork = "" }
        }
        .alert("No Wi-Fi Network", isPresented: $networkUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Connect to the Wi-Fi network your server is on, then try again.")
        }
        .onAppear {
            address = config?.apiURL.map(Self.displayAddress) ?? ""
        }
        .onChange(of: addressFocused) { _, focused in
            if !focused { saveAddress() }
        }
        .onDisappear(perform: saveAddress)
    }

    private var identitySection: some View {
        Section {
            if let identity = config?.verifiedIdentity {
                Toggle(isOn: Binding(
                    get: { config?.automaticallyUseVerifiedLocal ?? false },
                    set: { enabled in edit { $0.automaticallyUseVerifiedLocal = enabled } }
                )) {
                    Label("Automatically Use Verified Local Server", systemImage: "checkmark.shield")
                }
                .accessibilityIdentifier("local-network-verified-auto")
                LabeledContent("Server Identity", value: router.isLocalIdentityVerified
                    ? String(localized: "Verified Connection") : String(localized: "Saved Server Identity"))
                    .accessibilityIdentifier("local-network-identity-state")
                VStack(alignment: .leading, spacing: 6) {
                    Text("CA Certificate SHA-256")
                        .font(.footnote)
                    Text(identity.fingerprint)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("local-network-identity-fingerprint")
                }
            } else {
                Text(config?.identity == nil ? String(localized: "No Server Identity Installed") : String(localized: "Invalid Server Identity"))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("local-network-identity-state")
            }
        } header: {
            Text("Verified Local Connection")
        } footer: {
            if config?.verifiedIdentity != nil {
                Text("On Wi-Fi, Imora checks the server against this saved certificate before using the local address. It does not need the Wi-Fi name. Automatic mode uses the external address when the verified local server is unavailable. Manual local mode stays selected and never switches to the external address.")
            } else {
                Text("Verified automatic selection needs an HTTPS address and a server identity installed through trusted setup. This trust applies only inside Imora; it does not install an iPhone certificate profile. Editing the local address removes a mismatching identity.")
            }
        }
    }

    private func edit(_ change: (inout LocalServerConfig) -> Void) {
        guard let server = session.client?.apiURL else { return }
        var config = router.config ?? LocalServerConfig(server: server)
        change(&config)
        router.update(config)
    }

    private func saveAddress() {
        guard isEnabled else { return }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            addressInvalid = false
            edit { $0.apiURL = nil }
            return
        }
        guard let url = LocalServerConfig.apiURL(from: trimmed) else {
            addressInvalid = true
            return
        }
        addressInvalid = false
        edit { $0.apiURL = url }
        // Trusted setup may replace a legacy address with its enrolled HTTPS
        // endpoint. Keep a later blur/disappearance from saving the old draft.
        address = config?.apiURL.map(Self.displayAddress) ?? ""
    }

    private func add(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !networks.contains(name) else { return }
        edit { $0.networks.append(name) }
    }

    private func addCurrentNetwork() async {
        isReadingNetwork = true
        defer { isReadingNetwork = false }
        if let name = await router.currentNetworkName() {
            add(name)
        } else if !router.isLocationDenied {
            networkUnavailable = true
        }
    }

    /// the api suffix is implied, so the field shows what people typed.
    private static func displayAddress(_ apiURL: URL) -> String {
        var string = (apiURL.lastPathComponent == "api" ? apiURL.deletingLastPathComponent() : apiURL)
            .absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        return string
    }
}
