import Foundation
import SwiftUI

/// a second address for the server, used on the listed wi-fi networks so
/// backups and browsing at home stay on the local network.
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
                Text("On the Wi-Fi networks below, Imora connects to the local address when the server answers there, and to \(session.client?.apiURL.host() ?? String(localized: "the server")) everywhere else.")
            }

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
                        ? "Imora needs precise location access to read the Wi-Fi name. Without it, the external address is always used."
                        : "Reading the Wi-Fi name needs location access. Wi-Fi names and ping responses select a saved route; they do not verify server identity. HTTP sends photos and account credentials without transport encryption.")
                }

                Section {
                    LabeledContent("Connected Through", value: statusText)
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

    private var statusText: String {
        switch router.status {
        case .off, .external: String(localized: "External Address")
        case .checking: String(localized: "Checking...")
        case .local: String(localized: "Local Address")
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
