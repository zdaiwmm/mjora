import Foundation
import UIKit
import os
import Security

nonisolated struct MediaRecoveryFence: Codable {
    struct Failure: Codable, Hashable {
        let scope: StableMediaScope
        let credentialScope: String
    }
    struct Resolution { let scopes: [StableMediaScope]; let unresolved: Bool }
    private static let limit = 8 << 10
    private static let payloadLimit = limit - 256
    var version = 2
    var scope: StableMediaScope?
    var credentialScope: String?
    var failures: [Failure]?
    var legacyValues: [String]?
    var unresolvedCollision: Bool?

    private static func valid(_ scope: StableMediaScope) -> Bool {
        scope.accountID?.isEmpty == false && scope.credentialScope == nil && !scope.serverIdentity.isEmpty
    }

    private static func parsed(_ raw: String) -> Self {
        if let record = try? JSONDecoder().decode(Self.self, from: Data(raw.utf8)) {
            if record.version == 1, let scope = record.scope, valid(scope),
               let credential = record.credentialScope, !credential.isEmpty {
                return Self(failures: [.init(scope: scope, credentialScope: credential)])
            }
            if record.version == 2, (record.failures ?? []).allSatisfy({ valid($0.scope) && !$0.credentialScope.isEmpty }) {
                return record
            }
        }
        if let scope = SessionCache.verifiedMediaScope(credential: raw) {
            return Self(failures: [.init(scope: scope, credentialScope: raw)])
        }
        return Self(legacyValues: [raw])
    }

    private func data() -> Data? { try? JSONEncoder().encode(self) }

    static func encoded(scope: StableMediaScope, credentialScope: String?) -> String? {
        merging(existing: nil, scope: scope, credentialScope: credentialScope)
    }

    /// One bounded envelope in the existing keychain item. Never replace an
    /// older pending negative with only the latest failed account.
    static func merging(existing: String?, scope: StableMediaScope, credentialScope: String?) -> String? {
        guard let credentialScope, !credentialScope.isEmpty else { return nil }
        var record = existing.map(parsed) ?? Self()
        // Oversized legacy records remain untouched and cannot auto-resolve.
        guard (record.data()?.count ?? Int.max) <= payloadLimit,
              existing == nil || existing!.utf8.count <= limit else { return nil }
        let previous = record
        if valid(scope) {
            var failures = record.failures ?? []
            let next = Failure(scope: scope, credentialScope: credentialScope)
            if !failures.contains(next) { failures.append(next) }
            record.failures = failures
        } else {
            var legacy = record.legacyValues ?? []
            if !legacy.contains(credentialScope) { legacy.append(credentialScope) }
            record.legacyValues = legacy
        }
        if (record.data()?.count ?? Int.max) > payloadLimit {
            record = previous
            record.unresolvedCollision = true
        }
        guard let data = record.data(), data.count <= limit else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func resolution(_ raw: String) -> Resolution {
        let record = parsed(raw)
        var scopes = Set((record.failures ?? []).map(\.scope))
        var unresolved = record.unresolvedCollision == true || raw.utf8.count > limit
            || (record.data()?.count ?? Int.max) > payloadLimit
        for legacy in record.legacyValues ?? [] {
            if let scope = SessionCache.verifiedMediaScope(credential: legacy) { scopes.insert(scope) }
            else { unresolved = true }
        }
        return .init(scopes: Array(scopes), unresolved: unresolved)
    }

    static func failedScope(_ raw: String) -> StableMediaScope? {
        let result = resolution(raw)
        return !result.unresolved && result.scopes.count == 1 ? result.scopes.first : nil
    }
}

@MainActor
enum MediaCacheRecovery {
    enum Outcome: Equatable, Sendable { case scopeUnavailable, temporaryProtection, signInRequired, newerCredential, unresolvedDurability }

    static func resolve(protectedDataAvailable: Bool, journalRemovalSucceeded _: Bool,
                        removeCredential: () -> KeychainStore.ConditionalRemoval) -> Outcome {
        guard protectedDataAvailable else { return .temporaryProtection }
        switch removeCredential() {
        case .removed: return .signInRequired
        case .differentCredential: return .newerCredential
        case .unavailable, .failed: return .unresolvedDurability
        }
    }

    static func handle(client: ImoraClient, failure: MediaContentGenerations.RetirementFailure) {
        if failure.durableScopeDenied {
            client.reportMediaCacheRecovery(outcome: .scopeUnavailable,
                notice: String(localized: "Photos are temporarily unavailable. Your edits are preserved. Reopen the app and try again."))
            return
        }
        let failedScope = client.mediaDisplayScope, failedCredential = client.offlineAccountKey
        let protected = UIApplication.shared.isProtectedDataAvailable
        let previous: String?
        switch KeychainStore.get(KeychainStore.mediaRecoveryFenceKey) {
        case .missing: previous = nil
        case .value(let value): previous = value
        case .unavailable:
            if protected { client.invalidate() }
            client.reportMediaCacheRecovery(outcome: .unresolvedDurability,
                notice: String(localized: "Photos are temporarily unavailable. Your edits are preserved. Reopen the app and try again."))
            return
        }
        // Persist negative knowledge even during temporary protection or when
        // another credential already owns the login. Neither is a logout.
        guard let fence = MediaRecoveryFence.merging(existing: previous, scope: failedScope,
                  credentialScope: failedCredential),
              KeychainStore.installRecoveryFence(fence, replacing: previous) == errSecSuccess else {
            if protected { client.invalidate() }
            client.reportMediaCacheRecovery(outcome: .unresolvedDurability,
                notice: String(localized: "Photos are temporarily unavailable. Your edits are preserved. Reopen the app and try again."))
            return
        }
        if protected { client.invalidate() }
        let outcome = resolve(protectedDataAvailable: protected, journalRemovalSucceeded: false) {
            KeychainStore.removeIfMatching(client.accessToken, for: "accessToken")
        }
        let notice: String?
        switch outcome {
        case .newerCredential: notice = nil
        case .signInRequired: notice = String(localized: "Sign in again to continue. Your edits are preserved.")
        case .scopeUnavailable, .temporaryProtection, .unresolvedDurability:
            notice = String(localized: "Photos are temporarily unavailable. Your edits are preserved. Reopen the app and try again.")
            Logger(subsystem: "com.vexcited.imora", category: "LaunchPreview").error("Unresolved cache retirement durability; runtime remains closed")
        }
        client.reportMediaCacheRecovery(outcome: outcome, notice: notice)
    }
}
