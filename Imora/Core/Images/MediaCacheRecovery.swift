import Foundation
import UIKit
import os

@MainActor
enum MediaCacheRecovery {
    enum Outcome: Equatable, Sendable { case temporaryProtection, journalDiscarded, signInRequired, newerCredential, unresolvedDurability }

    static func resolve(protectedDataAvailable: Bool, journalRemovalSucceeded: Bool,
                        removeCredential: () -> KeychainStore.ConditionalRemoval) -> Outcome {
        guard protectedDataAvailable else { return .temporaryProtection }
        if journalRemovalSucceeded { return .journalDiscarded }
        switch removeCredential() {
        case .removed: return .signInRequired
        case .differentCredential: return .newerCredential
        case .unavailable, .failed: return .unresolvedDurability
        }
    }

    static func handle(client: ImoraClient, failure: MediaContentGenerations.RetirementFailure) {
        let protected = UIApplication.shared.isProtectedDataAvailable
        // Temporary lock is not a logout. Cache reads are already fail-closed;
        // the normal protected-data callback retries namespace persistence.
        if protected, !failure.journalRemovalSucceeded { client.invalidate() }
        let outcome = resolve(protectedDataAvailable: protected, journalRemovalSucceeded: failure.journalRemovalSucceeded) {
            KeychainStore.removeIfMatching(client.accessToken, for: "accessToken", recoveryFence: client.offlineAccountKey)
        }
        let notice: String?
        switch outcome {
        case .temporaryProtection, .journalDiscarded, .newerCredential: notice = nil
        case .signInRequired: notice = String(localized: "Sign in again to continue. Your edits are preserved.")
        case .unresolvedDurability:
            notice = String(localized: "Photos are temporarily unavailable. Your edits are preserved. Reopen the app and try again.")
            Logger(subsystem: "com.vexcited.imora", category: "LaunchPreview").error("Unresolved cache retirement durability; runtime remains closed")
        }
        client.reportMediaCacheRecovery(outcome: outcome, notice: notice)
    }
}
