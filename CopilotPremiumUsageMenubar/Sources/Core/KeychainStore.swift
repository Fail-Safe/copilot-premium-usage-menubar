import Foundation
import Security

/// A tiny Keychain wrapper for storing a GitHub token (PAT or OAuth access token).
///
/// Notes:
/// - Stores data as a Generic Password item.
/// - Uses `service` + `account` to uniquely identify the secret.
/// - Default service is derived from the app bundle id if available, otherwise a stable fallback.
///
/// This is intentionally minimal and synchronous (Keychain calls are fast).
public final class KeychainStore: @unchecked Sendable {
    public struct Entry: Sendable {
        public var service: String
        public var account: String

        public init(service: String, account: String) {
            self.service = service
            self.account = account
        }
    }

    public enum KeychainError: Error, Sendable, CustomStringConvertible {
        case unexpectedStatus(OSStatus)
        case invalidItemData
        case stringEncodingFailed
        case stringDecodingFailed

        public var description: String {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown"
                return "Keychain error (\(status)): \(message)"
            case .invalidItemData:
                return "Keychain item data was invalid."
            case .stringEncodingFailed:
                return "Failed to encode string as UTF-8."
            case .stringDecodingFailed:
                return "Failed to decode UTF-8 string."
            }
        }
    }

    private let entry: Entry
    private let accessGroup: String?
    private let synchronizable: Bool

    /// Store accessibility as a String constant rather than a CFString value to avoid Swift 6 Sendable warnings.
    /// We only need to pass one of the Keychain constants back into SecItemAdd/SecItemUpdate.
    private let accessibilityAttrValue: String

    /// Creates a store for a specific key.
    ///
    /// - Parameters:
    ///   - service: Keychain service name. If nil, uses bundle id or fallback.
    ///   - account: Keychain account name (think: key name). Defaults to "github.com".
    ///   - accessGroup: Optional keychain access group (generally nil unless you need sharing).
    ///   - accessibility: When the item is accessible. Defaults to after first unlock.
    ///   - synchronizable: Whether the item should sync via iCloud Keychain (defaults false).
    public init(
        service: String? = nil,
        account: String = "github.com",
        accessGroup: String? = nil,
        accessibility: String = kSecAttrAccessibleAfterFirstUnlock as String,
        synchronizable: Bool = false
    ) {
        // Important:
        // Use a stable Keychain "service" identifier so different launch modes can see the same item.
        //
        // If we used `Bundle.main.bundleIdentifier`, then:
        // - SwiftPM executable runs may use a different bundle id (or none),
        // - the Xcode wrapper `.app` will have its own bundle id,
        // causing the token to be written under different Keychain services and "disappear".
        //
        // Keep this stable across both the wrapper and SwiftPM builds.
        let derivedService = service ?? "com.failsafe.CopilotPremiumUsageMenubar"
        self.entry = Entry(service: derivedService, account: account)
        self.accessGroup = accessGroup
        self.accessibilityAttrValue = accessibility
        self.synchronizable = synchronizable
    }

    public func readToken() throws -> String? {
        var query: [String: Any] = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = item as? Data else {
            throw KeychainError.invalidItemData
        }
        guard let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.stringDecodingFailed
        }
        return token
    }

    /// Writes (creates or updates) the token.
    public func writeToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.stringEncodingFailed
        }

        // Try update-first (fast path if it exists).
        var attributesToUpdate: [String: Any] = [
            kSecValueData as String: data
        ]

        // Some attributes can be set on update, though not all are respected depending on OS.
        attributesToUpdate[kSecAttrAccessible as String] = accessibilityAttrValue
        attributesToUpdate[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        // Not found: add it.
        var addQuery: [String: Any] = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = accessibilityAttrValue
        addQuery[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    /// Deletes the stored token (if any). Not-found is treated as success.
    public func deleteToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw KeychainError.unexpectedStatus(status)
    }

    // MARK: - Helpers

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: entry.service,
            kSecAttrAccount as String: entry.account
        ]

        // Keep behavior explicit: do not sync secrets unless the user explicitly opts in.
        query[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!

        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        return query
    }
}
