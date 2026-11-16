import Foundation
import Security

/// minimal keychain wrapper for the session token. items are written into the
/// app group's access group so the share extension can authenticate with the
/// same session; reads stay group-less, which searches every group this
/// process can see and also finds tokens written before the group existed.
enum KeychainStore {
    static let mediaRecoveryFenceKey = "mediaCacheRecoveryFence"
    enum ConditionalRemoval: Equatable { case removed, differentCredential, unavailable(OSStatus), failed(OSStatus) }
    enum ReadResult {
        case value(String)
        case missing
        case unavailable(OSStatus)
    }

    private static let service = "app.imora.credentials"

    private static var accessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "IMORAAppGroup") as? String
    }

    static func set(_ value: String, for key: String) {
        // delete first: an update could match a copy in another group and
        // leave a stale twin behind for reads to trip on.
        delete(key)
        var insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        if let accessGroup {
            insert[kSecAttrAccessGroup as String] = accessGroup
        }
        let status = SecItemAdd(insert as CFDictionary, nil)
        // sharing is best effort: on a build whose provisioning rejects the
        // group, a private token still beats losing the session.
        if status == errSecMissingEntitlement, insert.removeValue(forKey: kSecAttrAccessGroup as String) != nil {
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func get(_ key: String) -> ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8)
            else { return .missing }
            return .value(value)
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed:
            return .unavailable(status)
        default:
            return .missing
        }
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Update only the exact compared keychain item. Unlike general set(),
    /// failure must preserve the previous pending recovery facts.
    static func installRecoveryFence(_ value: String, replacing expected: String?) -> OSStatus {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: mediaRecoveryFenceKey,
            kSecReturnData as String: true, kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        let read = SecItemCopyMatching(query as CFDictionary, &result)
        let written: OSStatus
        if read == errSecItemNotFound {
            guard expected == nil else { return errSecItemNotFound }
            var insert: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: mediaRecoveryFenceKey,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData as String: Data(value.utf8)]
            if let accessGroup { insert[kSecAttrAccessGroup as String] = accessGroup }
            let status = SecItemAdd(insert as CFDictionary, nil)
            if status == errSecMissingEntitlement, insert.removeValue(forKey: kSecAttrAccessGroup as String) != nil {
                written = SecItemAdd(insert as CFDictionary, nil)
            } else { written = status }
        } else {
            guard read == errSecSuccess else { return read }
            guard let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data,
                  let reference = item[kSecValuePersistentRef as String] as? Data,
                  let expected, data == Data(expected.utf8) else { return errSecDuplicateItem }
            let exact: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecValuePersistentRef as String: reference]
            written = SecItemUpdate(exact as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        }
        guard written == errSecSuccess else { return written }
        guard case .value(let actual) = get(mediaRecoveryFenceKey), actual == value else { return errSecIO }
        return errSecSuccess
    }

    /// Main-actor isolation serializes comparison/deletion with this app's
    /// credential replacements. A fence forces a fresh content namespace on
    /// recovery; no newer/different credential is deleted.
    static func removeIfMatching(_ expected: String, for key: String, recoveryFence: String? = nil,
                                 expectedRecoveryFence: String? = nil, deleteItem: ([String: Any]) -> OSStatus = { SecItemDelete($0 as CFDictionary) }) -> ConditionalRemoval {
        let read: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        let readStatus = SecItemCopyMatching(read as CFDictionary, &result)
        if readStatus == errSecItemNotFound { return .differentCredential }
        if readStatus == errSecInteractionNotAllowed { return .unavailable(readStatus) }
        guard readStatus == errSecSuccess, let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let reference = item[kSecValuePersistentRef as String] as? Data else { return .failed(readStatus) }
        guard data == Data(expected.utf8) else { return .differentCredential }
        if let recoveryFence {
            let status = installRecoveryFence(recoveryFence, replacing: expectedRecoveryFence)
            guard status == errSecSuccess else { return .failed(status) }
        }
        // Scope the deletion to the exact compared item. A private/app-group
        // twin or a delete-and-reinsert replacement has a different reference.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: reference]
        let status = deleteItem(query)
        guard status == errSecSuccess || status == errSecItemNotFound else { return .failed(status) }
        switch get(key) {
        case .missing: return .removed
        case .value(let current): return current == expected ? .failed(errSecIO) : .differentCredential
        case .unavailable(let status): return .unavailable(status)
        }
    }
}
