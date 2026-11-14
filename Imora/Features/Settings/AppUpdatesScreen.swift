import SwiftUI

struct AppUpdatesScreen: View {
    @Environment(AppUpdateStore.self) private var updates
    @State private var confirmation: AppUpdateRelease?

    var body: some View {
        List {
            Section("This App") {
                LabeledContent("App Version", value: updates.installedVersion)
                    .accessibilityIdentifier("app-updates-installed-version")
                LabeledContent("Build", value: updates.installedBuild)
                    .accessibilityIdentifier("app-updates-installed-build")
            }

            Section {
                if updates.isConfigured {
                    if let release = updates.status?.latest {
                        LabeledContent("Prepared Version", value: release.version)
                        LabeledContent("Prepared Build", value: release.build)
                        if !release.notes.isEmpty {
                            Text(verbatim: release.notes)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let installation = updates.status?.installation, installation.state != .idle {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(installationTitle(installation.state))
                            if let code = installation.messageCode {
                                Text(installationMessage(code))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else if installation.state == .succeeded {
                                Text("Reopen the app to verify the installed version above.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("app-updates-installation-state")
                    }

                    if updates.isRequestingInstallation {
                        ProgressView("Requesting Installation...")
                    } else if let release = updates.availableRelease {
                        Button {
                            confirmation = release
                        } label: {
                            Label("Install with Mac", systemImage: "arrow.down.circle")
                        }
                        .disabled(updates.isChecking || updates.isRequestingInstallation)
                        .accessibilityIdentifier("app-updates-install")
                    } else if updates.status != nil, updates.status?.installation?.state == nil || updates.status?.installation?.state == .idle {
                        Text("No Newer Prepared Version")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("app-updates-no-new-version")
                    }

                    if let failure = updates.failureMessage {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("app-updates-error")
                    }

                    Button {
                        Task { await updates.checkForUpdates() }
                    } label: {
                        if updates.isChecking {
                            HStack {
                                ProgressView()
                                Text("Checking for Updates...")
                            }
                        } else {
                            Label("Check for Updates", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(updates.isChecking || updates.isRequestingInstallation)
                    .accessibilityIdentifier("app-updates-check")
                } else {
                    Text("Wireless Updates Not Configured")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("app-updates-unconfigured")
                    Text("This build has no trusted update Mac configured. Your photos and other app features remain available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Wireless Updates")
            } footer: {
                Text("Your Mac installs prepared updates over Wi-Fi after you confirm. Keep it awake and logged in, and keep this paired phone reachable. Apple sign-in or unlocking the phone may be required.")
            }
        }
        .navigationTitle("About & Updates")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if updates.isConfigured && !updates.hasChecked { await updates.checkForUpdates() }
        }
        .alert("Install App Update?", isPresented: Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        ), presenting: confirmation) { release in
            Button("Install with Mac") {
                Task { await updates.confirmInstallation(of: release) }
            }
            .accessibilityIdentifier("app-updates-confirm-install")
            Button("Later", role: .cancel) {}
        } message: { release in
            Text(release.installationConfirmationMessage)
        }
    }

    private func installationTitle(_ state: AppUpdateInstallation.State) -> String {
        switch state {
        case .idle: String(localized: "Ready")
        case .queued: String(localized: "Update Queued on Mac")
        case .installing: String(localized: "Mac Is Installing")
        case .succeeded: String(localized: "Mac Reports Installation Complete")
        case .failed: String(localized: "Installation Needs Attention")
        }
    }

    private func installationMessage(_ code: AppUpdateInstallation.MessageCode) -> String {
        switch code {
        case .needsPhone: String(localized: "The paired phone is not reachable. Check its connection to your Mac, then try again.")
        case .needsUnlock: String(localized: "Unlock this phone, then try again.")
        case .signInRequired: String(localized: "Sign in to Apple on your Mac, then try again.")
        case .invalidPackage: String(localized: "The prepared update could not be validated. Prepare it again on your Mac.")
        case .busy: String(localized: "Your Mac is busy with another installation or renewal. Try again shortly.")
        case .failed: String(localized: "The Mac could not complete the installation. Check it and try again.")
        }
    }
}

extension AppUpdateRelease {
    nonisolated var installationConfirmationMessage: String {
        String(localized: "Install version \(version) (build \(build)) using your Mac? Keep your Mac awake and logged in, and this phone reachable. Apple sign-in or unlocking the phone may be required.")
    }
}
