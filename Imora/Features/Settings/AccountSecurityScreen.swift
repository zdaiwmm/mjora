import Foundation
import SwiftUI

/// password, signed-in devices, api keys and the oauth link. every route
/// here is on every immich 3.x, gallery 5.x and imora server, except
/// passkeys, which only show where the server has them.
struct AccountSecurityScreen: View {
    @Environment(SessionStore.self) private var session

    @State private var hasPassword = true
    @State private var sessions: [ServerSession] = []
    @State private var keys: [APIKey] = []
    @State private var showChangePassword = false
    @State private var showCreateKey = false
    @State private var newKeyName = ""
    @State private var createdSecret: String?
    @State private var renamingKey: APIKey?
    @State private var renameDraft = ""
    @State private var confirmSignOutOthers = false
    @State private var confirmUnlink = false
    @State private var passkeys: [Passkey] = []
    @State private var renamingPasskey: Passkey?
    @State private var passkeyNameDraft = ""
    @State private var deletingPasskey: Passkey?
    @State private var isWorking = false

    private var oauthEnabled: Bool { session.features?.oauth == true }
    private var passkeysEnabled: Bool { session.capabilities.supportsPasskeys }
    /// adding one needs the server's own web page, so it is made for the server's domain.
    private var canAddPasskeys: Bool { session.capabilities.supportsAppLogin }

    var body: some View {
        List {
            Section {
                if hasPassword {
                    Button {
                        showChangePassword = true
                    } label: {
                        Label("Change Password", systemImage: "key")
                    }
                    .accessibilityIdentifier("security-change-password")
                }
                if oauthEnabled {
                    if session.user?.hasLinkedOAuth == true {
                        Button(role: .destructive) {
                            confirmUnlink = true
                        } label: {
                            Label("Unlink OAuth Account", systemImage: "link")
                        }
                    } else {
                        Button {
                            Task { await linkOAuth() }
                        } label: {
                            Label("Link OAuth Account", systemImage: "link")
                        }
                    }
                }
            } header: {
                Text("Sign In")
            } footer: {
                if !hasPassword {
                    Text("This account signs in through your provider and has no password.")
                }
            }
            .disabled(isWorking)

            if passkeysEnabled {
                passkeysSection
            }

            Section {
                ForEach(sessions) { device in
                    SessionRow(device: device)
                        .swipeActions {
                            if !device.current {
                                Button("Sign Out", role: .destructive) {
                                    Task { await signOut(device) }
                                }
                            }
                        }
                }
                if sessions.contains(where: { !$0.current }) {
                    Button("Sign Out of Other Devices", role: .destructive) {
                        confirmSignOutOthers = true
                    }
                }
            } header: {
                Text("Devices")
            }

            Section {
                ForEach(keys) { key in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key.name.isEmpty ? String(localized: "Unnamed key") : key.name)
                        if let created = APIDate.parse(key.createdAt) {
                            Text("Created \(created.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            Task { await delete(key) }
                        }
                        Button("Rename") {
                            renameDraft = key.name
                            renamingKey = key
                        }
                        .tint(.accentColor)
                    }
                }
                Button {
                    newKeyName = ""
                    showCreateKey = true
                } label: {
                    Label("New API Key", systemImage: "plus")
                }
            } header: {
                Text("API Keys")
            } footer: {
                Text("Keys let other apps and scripts use your account. Treat them like a password.")
            }
        }
        .navigationTitle("Account Security")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordSheet()
        }
        .alert("New API Key", isPresented: $showCreateKey) {
            TextField("Name", text: $newKeyName)
            Button("Create") { Task { await createKey() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename API Key", isPresented: Binding(
            get: { renamingKey != nil },
            set: { if !$0 { renamingKey = nil } }
        )) {
            TextField("Name", text: $renameDraft)
            Button("Save") {
                if let key = renamingKey { Task { await rename(key, to: renameDraft) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: Binding(
            get: { createdSecret.map { SecretItem(secret: $0) } },
            set: { if $0 == nil { createdSecret = nil } }
        )) { item in
            APIKeySecretSheet(secret: item.secret)
        }
        .confirmationDialog("Sign out of every other device?", isPresented: $confirmSignOutOthers,
                            titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await signOutOthers() } }
        }
        .alert("Rename Passkey", isPresented: Binding(
            get: { renamingPasskey != nil },
            set: { if !$0 { renamingPasskey = nil } }
        )) {
            TextField("Name", text: $passkeyNameDraft)
            Button("Save") {
                if let passkey = renamingPasskey { Task { await rename(passkey, to: passkeyNameDraft) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete this passkey?",
            isPresented: Binding(
                get: { deletingPasskey != nil },
                set: { if !$0 { deletingPasskey = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletingPasskey
        ) { passkey in
            Button("Delete", role: .destructive) { Task { await delete(passkey) } }
        } message: { _ in
            Text("You will no longer be able to sign in with it.")
        }
        .confirmationDialog("Unlink your provider account?", isPresented: $confirmUnlink, titleVisibility: .visible) {
            Button("Unlink", role: .destructive) { Task { await unlinkOAuth() } }
        } message: {
            Text(hasPassword ? "You can still sign in with your password." : "Set a password first, or you will not be able to sign in.")
        }
    }

    private var passkeysSection: some View {
        Section {
            ForEach(passkeys) { passkey in
                PasskeyRow(passkey: passkey)
                    .swipeActions {
                        Button("Delete") { deletingPasskey = passkey }
                            .tint(.red)
                        Button("Rename") {
                            passkeyNameDraft = passkey.name ?? ""
                            renamingPasskey = passkey
                        }
                        .tint(.accentColor)
                    }
            }
            if canAddPasskeys {
                Button {
                    Task { await addPasskey() }
                } label: {
                    Label("Add Passkey", systemImage: "plus")
                }
                .disabled(isWorking)
            }
        } header: {
            Text("Passkeys")
        } footer: {
            if canAddPasskeys {
                Text("A passkey signs you in without a password. Adding one opens your server's web page.")
            } else {
                Text("Passkeys are added from the web app. You can rename and delete them here.")
            }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        async let status = try? client.authStatus()
        async let fetchedSessions = try? client.sessions()
        async let fetchedKeys = try? client.apiKeys()
        async let fetchedPasskeys = passkeysEnabled ? try? client.passkeys() : nil
        if let status = await status { hasPassword = status.password }
        if let fetched = await fetchedSessions {
            sessions = fetched.sorted { lhs, rhs in
                if lhs.current != rhs.current { return lhs.current }
                return lhs.updatedAt > rhs.updatedAt
            }
        }
        if let fetched = await fetchedKeys { keys = fetched.sorted { $0.createdAt > $1.createdAt } }
        if let fetched = await fetchedPasskeys { passkeys = Self.sorted(fetched) }
    }

    private static func sorted(_ passkeys: [Passkey]) -> [Passkey] {
        passkeys.sorted { $0.createdAt > $1.createdAt }
    }

    private func loadPasskeys() async {
        guard let client = session.client, let fetched = try? await client.passkeys() else { return }
        passkeys = Self.sorted(fetched)
    }

    /// the server's own page makes the passkey, so it belongs to the server's
    /// domain. the browser session is the one the passkey sign in uses.
    private func addPasskey() async {
        guard let client = session.client, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let page = ImoraClient.webURL(apiURL: client.apiURL).appending(path: "user-settings/security")
        do {
            try await OAuthService.shared.browse(page)
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't open the passkey page."), error: error)
        }
        await loadPasskeys()
    }

    private func rename(_ passkey: Passkey, to name: String) async {
        guard let client = session.client else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = trimmed.isEmpty ? nil : trimmed
        guard newName != passkey.name else { return }
        let rollback = passkey.name
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't rename the passkey."),
            apply: { if let index = passkeys.firstIndex(where: { $0.id == passkey.id }) { passkeys[index].name = newName } },
            rollback: { if let index = passkeys.firstIndex(where: { $0.id == passkey.id }) { passkeys[index].name = rollback } },
            request: { try await client.renamePasskey(id: passkey.id, name: newName) }
        )
    }

    private func delete(_ passkey: Passkey) async {
        guard let client = session.client else { return }
        let snapshot = passkeys
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't delete the passkey."),
            apply: { passkeys.removeAll { $0.id == passkey.id } },
            rollback: { passkeys = snapshot },
            request: { try await client.deletePasskey(id: passkey.id) }
        )
    }

    private func signOut(_ device: ServerSession) async {
        guard let client = session.client else { return }
        let snapshot = sessions
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't sign that device out."),
            apply: { sessions.removeAll { $0.id == device.id } },
            rollback: { sessions = snapshot },
            request: { try await client.deleteSession(id: device.id) }
        )
    }

    private func signOutOthers() async {
        guard let client = session.client else { return }
        let snapshot = sessions
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't sign the other devices out."),
            apply: { sessions.removeAll { !$0.current } },
            rollback: { sessions = snapshot },
            request: { try await client.deleteOtherSessions() }
        )
    }

    private func createKey() async {
        guard let client = session.client else { return }
        let name = newKeyName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let created = try await client.createAPIKey(name: name.isEmpty ? "Imora" : name)
            keys.insert(created.apiKey, at: 0)
            createdSecret = created.secret
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't create the key."), error: error)
        }
    }

    private func rename(_ key: APIKey, to name: String) async {
        guard let client = session.client, let index = keys.firstIndex(of: key) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != key.name else { return }
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't rename the key."),
            apply: { keys[index].name = trimmed },
            rollback: { if let index = keys.firstIndex(where: { $0.id == key.id }) { keys[index].name = key.name } },
            request: { try await client.renameAPIKey(id: key.id, name: trimmed) }
        )
    }

    private func delete(_ key: APIKey) async {
        guard let client = session.client else { return }
        let snapshot = keys
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't delete the key."),
            apply: { keys.removeAll { $0.id == key.id } },
            rollback: { keys = snapshot },
            request: { try await client.deleteAPIKey(id: key.id) }
        )
    }

    private func linkOAuth() async {
        guard let client = session.client, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if try await OAuthService.shared.link(client: client) {
                await session.refreshUser()
            }
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't link your provider account."), error: error)
        }
    }

    private func unlinkOAuth() async {
        guard let client = session.client, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.unlinkOAuth()
            await session.refreshUser()
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't unlink your provider account."), error: error)
        }
    }
}

private struct SecretItem: Identifiable {
    let secret: String
    var id: String { secret }
}

private struct PasskeyRow: View {
    let passkey: Passkey

    private var detail: String {
        let created = APIDate.parse(passkey.createdAt)?.formatted(date: .abbreviated, time: .omitted)
        let used = passkey.usedAt.flatMap(APIDate.parse)?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "never")
        return created.map { String(localized: "Created \($0), last used \(used)") } ?? String(localized: "Last used \(used)")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.badge.key")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(passkey.name ?? String(localized: "Passkey"))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SessionRow: View {
    let device: ServerSession

    private var icon: String {
        switch device.deviceOS.lowercased() {
        case let os where os.contains("ios") || os.contains("iphone"): "iphone"
        case let os where os.contains("ipad"): "ipad"
        case let os where os.contains("android"): "smartphone"
        case let os where os.contains("mac"): "laptopcomputer"
        default: device.deviceType.isEmpty ? "desktopcomputer" : "globe"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text([device.deviceType, device.deviceOS].filter { !$0.isEmpty }.joined(separator: " · ").nonEmpty
                     ?? String(localized: "Unknown device"))
                if device.current {
                    Text("This device")
                        .font(.caption)
                        .foregroundStyle(.tint)
                } else if let seen = APIDate.parse(device.updatedAt) {
                    Text("Last active \(seen.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ChangePasswordSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""
    @State private var signOutOthers = true
    @State private var isSaving = false

    private var canSave: Bool {
        !current.isEmpty && !new.isEmpty && new == confirmation && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Current password", text: $current)
                        .textContentType(.password)
                }
                Section {
                    SecureField("New password", text: $new)
                        .textContentType(.newPassword)
                    SecureField("Confirm new password", text: $confirmation)
                        .textContentType(.newPassword)
                } footer: {
                    if !confirmation.isEmpty, new != confirmation {
                        Text("The passwords don't match.")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Toggle("Sign Out of Other Devices", isOn: $signOutOthers)
                }
            }
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func save() async {
        guard let client = session.client, canSave else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await client.changePassword(current: current, new: new, signOutOtherDevices: signOutOthers)
            dismiss()
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't change the password."), error: error)
        }
    }
}

/// shows a new key's secret, the only time the server hands it out.
private struct APIKeySecretSheet: View {
    @Environment(\.dismiss) private var dismiss
    let secret: String
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(secret)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = secret
                        copied = true
                    }
                } footer: {
                    Text("Copy the key now. It won't be shown again.")
                }
            }
            .navigationTitle("API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
