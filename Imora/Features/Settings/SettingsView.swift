import Foundation
import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var about: ServerAbout?
    @State private var confirmLogout = false
    @State private var memoriesMutations = SerialOptimisticValue<Bool>()
    @State private var peopleMutations = SerialOptimisticValue<Bool>()
    @State private var updateStrategyMutations = SerialOptimisticValue<PersonUpdateStrategy>()

    /// shared people only take edits on servers that share them.
    private var showsUpdateStrategy: Bool {
        session.capabilities.supportsPeopleSharing && ServerFeaturePreference.people.isEnabled(in: session.preferences)
    }

    private func preferenceToggle(
        _ title: String,
        icon: String,
        section: ServerFeaturePreference
    ) -> some View {
        Toggle(isOn: Binding(
            get: { section.isEnabled(in: session.preferences) },
            set: { updatePreference(section, enabled: $0) }
        )) {
            Label(title, systemImage: icon)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        ProfileAvatar(size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.user?.name ?? String(localized: "Unknown"))
                                .font(.headline)
                            Text(session.user?.email ?? "")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    preferenceToggle(String(localized: "Memories"), icon: "clock.arrow.circlepath", section: .memories)
                    preferenceToggle(String(localized: "People"), icon: "person.2", section: .people)
                    if showsUpdateStrategy {
                        Picker(selection: Binding(
                            get: { session.preferences?.peopleUpdateStrategy ?? .everyone },
                            set: { updateStrategy($0) }
                        )) {
                            Text("Everyone With Access").tag(PersonUpdateStrategy.everyone)
                            Text("Only Me").tag(PersonUpdateStrategy.onlyMe)
                        } label: {
                            Label("Shared People Edits", systemImage: "person.2.badge.gearshape")
                        }
                        .accessibilityIdentifier("settings-people-update-strategy")
                    }
                } header: {
                    Text("Features")
                } footer: {
                    if showsUpdateStrategy {
                        Text(session.preferences?.peopleUpdateStrategy == .onlyMe
                            ? "Renaming a shared person or changing their birthday only changes your own copy."
                            : "Renaming a shared person or changing their birthday also changes it for the owners who let you edit it.")
                    }
                }

                if session.capabilities.supportsClusterGroups {
                    Section {
                        NavigationLink {
                            FaceSharingScreen()
                        } label: {
                            Label("Face Sharing", systemImage: "person.2.crop.square.stack")
                        }
                        .accessibilityIdentifier("settings-face-sharing")
                    }
                }

                Section {
                    NavigationLink {
                        NotificationSettingsScreen()
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                    .accessibilityIdentifier("settings-notifications")

                    NavigationLink {
                        AccountSecurityScreen()
                    } label: {
                        Label("Account Security", systemImage: "person.badge.key")
                    }
                    .accessibilityIdentifier("settings-account-security")

                    NavigationLink {
                        PrivacyScreen()
                    } label: {
                        Label("Privacy", systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("settings-privacy")

                    NavigationLink {
                        LockedFolderSettingsScreen()
                    } label: {
                        Label("Locked Folder", systemImage: "lock")
                    }
                    .accessibilityIdentifier("settings-locked-folder")

                    NavigationLink {
                        StorageScreen()
                    } label: {
                        Label("Storage", systemImage: "internaldrive")
                    }
                    .accessibilityIdentifier("settings-storage")

                    NavigationLink {
                        BackupScreen()
                    } label: {
                        LabeledContent {
                            if session.backup?.autoBackup == false {
                                Text("Off")
                                    .foregroundStyle(.secondary)
                            }
                        } label: {
                            Label("Backup", systemImage: "arrow.triangle.2.circlepath.icloud")
                        }
                    }
                    .accessibilityValue(session.backup?.autoBackup == false ? "Automatic backup off" : "")
                    .accessibilityIdentifier("settings-backup")
                }

                Section("Server") {
                    LabeledContent("Address") {
                        Text(session.client?.apiURL.host() ?? "")
                            .lineLimit(1)
                    }
                    NavigationLink {
                        LocalNetworkScreen()
                    } label: {
                        Label("Local Network", systemImage: "wifi")
                    }
                    .accessibilityIdentifier("settings-local-network")
                    if let about {
                        LabeledContent(session.serverProduct.map { $0 == .immich ? String(localized: "Version") : $0.displayName } ?? String(localized: "Version")) {
                            Text(about.version)
                        }
                    }
                    if session.user?.isAdmin == true {
                        NavigationLink {
                            AdminScreen()
                        } label: {
                            Label("Administration", systemImage: "person.badge.key")
                        }
                        .accessibilityIdentifier("settings-administration")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmLogout = true
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .accessibilityIdentifier("settings-sign-out")
                    // ios 26 morphs the dialog out of its source control, so it
                    // sits on the row - on the screen root it floats detached.
                    .confirmationDialog("Sign out of this server?", isPresented: $confirmLogout, titleVisibility: .visible) {
                        Button("Sign Out", role: .destructive) {
                            dismiss()
                            Task { await session.logOut() }
                        }
                        .accessibilityIdentifier("settings-confirm-sign-out")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityIdentifier("settings-close")
                }
            }
            .task {
                about = try? await session.client?.serverAbout()
            }
        }
    }

    private func updateStrategy(_ strategy: PersonUpdateStrategy) {
        guard let client = session.client else {
            ErrorToastCenter.shared.show(String(localized: "Couldn't update shared people edits. The server is not available."))
            return
        }
        updateStrategyMutations.submit(
            current: session.preferences?.peopleUpdateStrategy ?? .everyone,
            desired: strategy,
            errorMessage: String(localized: "Couldn't update shared people edits"),
            apply: { value in
                guard session.client === client else { return }
                let current = session.preferences ?? .emptyForLocalProjection
                session.projectPreferences(current.replacingPeopleUpdateStrategy(value), field: "peopleUpdateStrategy")
            },
            request: { value in
                try await client.updatePeopleUpdateStrategy(value).peopleUpdateStrategy
            },
            activityChanged: { active in
                guard session.client === client else { return }
                session.setPreferenceMutation("peopleUpdateStrategy", active: active)
            }
        )
    }

    private func updatePreference(_ section: ServerFeaturePreference, enabled: Bool) {
        guard let client = session.client else {
            ErrorToastCenter.shared.show(String(localized: "Couldn't update \(section.title.lowercased()). The server is not available."))
            return
        }
        let mutations = section == .memories ? memoriesMutations : peopleMutations
        mutations.submit(
            current: section.isEnabled(in: session.preferences),
            desired: enabled,
            errorMessage: String(localized: "Couldn't update \(section.title.lowercased())"),
            apply: { value in
                guard session.client === client else { return }
                let current = session.preferences ?? .emptyForLocalProjection
                session.projectPreferences(
                    current.replacingFeature(section, enabled: value),
                    field: section.rawValue
                )
            },
            request: { value in
                let updated = try await client.updatePreference(section: section.rawValue, enabled: value)
                return section.isEnabled(in: updated)
            },
            activityChanged: { active in
                guard session.client === client else { return }
                session.setPreferenceMutation(section.rawValue, active: active)
            }
        )
    }
}

nonisolated enum ServerFeaturePreference: String {
    case memories
    case people

    var title: String {
        switch self {
        case .memories: String(localized: "Memories")
        case .people: String(localized: "People")
        }
    }

    func isEnabled(in preferences: UserPreferences?) -> Bool {
        switch self {
        case .memories: preferences?.memoriesEnabled ?? true
        case .people: preferences?.peopleEnabled ?? true
        }
    }
}

extension UserPreferences {
    nonisolated static var emptyForLocalProjection: UserPreferences {
        UserPreferences(
            memories: nil,
            people: nil,
            folders: nil,
            ratings: nil,
            tags: nil,
            sharedLinks: nil,
            emailNotifications: nil
        )
    }

    nonisolated func replacingFeature(
        _ section: ServerFeaturePreference,
        enabled: Bool
    ) -> UserPreferences {
        UserPreferences(
            memories: section == .memories ? FeatureToggle(enabled: enabled) : memories,
            people: section == .people
                ? PeoplePreferences(enabled: enabled, updateStrategy: people?.updateStrategy)
                : people,
            folders: folders,
            ratings: ratings,
            tags: tags,
            sharedLinks: sharedLinks,
            emailNotifications: emailNotifications
        )
    }

    nonisolated func replacingPeopleUpdateStrategy(_ strategy: PersonUpdateStrategy) -> UserPreferences {
        UserPreferences(
            memories: memories,
            people: PeoplePreferences(enabled: people?.enabled ?? true, updateStrategy: strategy),
            folders: folders,
            ratings: ratings,
            tags: tags,
            sharedLinks: sharedLinks,
            emailNotifications: emailNotifications
        )
    }

    nonisolated func replacingEmailNotifications(
        with email: EmailNotificationPreferences
    ) -> UserPreferences {
        UserPreferences(
            memories: memories,
            people: people,
            folders: folders,
            ratings: ratings,
            tags: tags,
            sharedLinks: sharedLinks,
            emailNotifications: email
        )
    }
}
