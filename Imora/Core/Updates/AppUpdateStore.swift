import Foundation
import Observation

@MainActor @Observable
final class AppUpdateStore {
    let installedVersion: String
    let installedBuild: String
    private(set) var status: AppUpdateStatus?
    private(set) var isChecking = false
    private(set) var isRequestingInstallation = false
    private(set) var hasChecked = false
    private(set) var failureMessage: String?
    private(set) var alertRelease: AppUpdateRelease?

    private let service: (any AppUpdateServicing)?
    private let defaults: UserDefaults?
    private let promptKey: String
    private var lastAutomaticCheck: Date?
    private var lastPromptedReleaseID: String?
    private var lastPromptedAt: Date?

    convenience init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        let config = AppUpdateConfiguration.decode(AppUpdateConfiguration.bundledData(bundle: bundle))
        self.init(service: config.map { AppUpdateClient(configuration: $0) },
            installedVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
            installedBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—",
            hostID: config?.hostId ?? "unconfigured", defaults: defaults)
    }

    init(service: (any AppUpdateServicing)?, installedVersion: String, installedBuild: String,
         hostID: String = "unconfigured", defaults: UserDefaults? = nil) {
        self.service = service
        self.installedVersion = installedVersion
        self.installedBuild = installedBuild
        self.defaults = defaults
        promptKey = "imora.appUpdates.prompt." + hostID
        lastPromptedReleaseID = defaults?.string(forKey: promptKey + ".release")
        if let date = defaults?.object(forKey: promptKey + ".date") as? Date { lastPromptedAt = date }
    }

    var isConfigured: Bool { service != nil }

    var availableRelease: AppUpdateRelease? {
        guard let status, let release = status.latest, release.isValid,
              let installed = AppUpdateVersion(version: installedVersion, build: installedBuild),
              let prepared = AppUpdateVersion(version: release.version, build: release.build), prepared > installed else { return nil }
        if let installation = status.installation {
            guard installation.state != .queued, installation.state != .installing,
                  installation.messageCode != .invalidPackage,
                  !(installation.state == .succeeded && installation.releaseId == release.releaseId) else { return nil }
        }
        return release
    }

    /// Automatic failures only update the About screen; they never interrupt
    /// the foreground with an error. Manual checks always bypass the cooldown.
    /// Returns true only when a completed manual check can confirm that this
    /// installed version is current. Callers may use it for tap feedback;
    /// unavailable offers (for example an installation in progress) aren't proof.
    @discardableResult
    func checkForUpdates(automatically: Bool = false, now: Date = Date()) async -> Bool {
        guard let service, !isChecking, !isRequestingInstallation else { return false }
        if automatically {
            if let lastAutomaticCheck, now.timeIntervalSince(lastAutomaticCheck) < 900 { return false }
            lastAutomaticCheck = now
        }
        isChecking = true
        failureMessage = nil
        defer { isChecking = false }
        do {
            let checked = try await service.status()
            try Task.checkCancellation()
            status = checked
            hasChecked = true
            if automatically, let release = availableRelease {
                let recentlyPrompted = lastPromptedReleaseID == release.releaseId
                    && lastPromptedAt.map { now.timeIntervalSince($0) < 86_400 } == true
                if !recentlyPrompted {
                    alertRelease = release
                    lastPromptedReleaseID = release.releaseId
                    lastPromptedAt = now
                    defaults?.set(release.releaseId, forKey: promptKey + ".release")
                    defaults?.set(now, forKey: promptKey + ".date")
                }
            } else if availableRelease == nil {
                alertRelease = nil
            }
            guard !automatically, checked.schemaVersion == 1,
                  let release = checked.latest, release.isValid,
                  let installed = AppUpdateVersion(version: installedVersion, build: installedBuild),
                  let prepared = AppUpdateVersion(version: release.version, build: release.build),
                  installed >= prepared else { return false }
            if let installation = checked.installation {
                guard installation.isValid, installation.messageCode == nil,
                      installation.state == .idle || installation.state == .succeeded else { return false }
            }
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            status = nil
            alertRelease = nil
            hasChecked = true
            failureMessage = String(localized: "Couldn't check for updates. Make sure your Mac is awake and reachable, then try again.")
            return false
        }
    }

    func dismissUpdateAlert() { alertRelease = nil }

    /// This is the sole installation entry point. It is called only by an
    /// explicit confirmation button, and revalidates the prepared release.
    func confirmInstallation(of confirmed: AppUpdateRelease) async {
        guard let service, !isChecking, !isRequestingInstallation, availableRelease == confirmed else { return }
        isRequestingInstallation = true
        alertRelease = nil
        failureMessage = nil
        defer { isRequestingInstallation = false }
        do {
            status = try await service.status()
            try Task.checkCancellation()
            guard availableRelease == confirmed else {
                failureMessage = String(localized: "The prepared update changed or is no longer available. Check for updates again.")
                return
            }
            let receipt = try await service.install(releaseID: confirmed.releaseId, requestID: UUID())
            guard let current = status else { return }
            status = AppUpdateStatus(schemaVersion: current.schemaVersion, hostId: current.hostId,
                latest: current.latest, installation: receipt)
        } catch {
            status = nil
            failureMessage = String(localized: "Couldn't confirm the installation request. Check the update status before trying again.")
        }
    }
}
