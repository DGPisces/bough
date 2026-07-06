import Foundation
import Security
import BoughCore

/// App-target Keychain closures injected into BoughCore's
/// `ClaudeOAuthCredentialsReader` (the core target may not import Security —
/// ArchitectureBoundaryTests). Reads the generic password the Claude Code CLI
/// stores its OAuth credentials under. A data read can show a macOS
/// authorization prompt; denial maps to `.denied` and the reader's 6h gate.
/// `readModificationDate` queries attributes only, which never prompts — the
/// reader uses it to skip data reads while the item is unchanged.
enum ClaudeKeychainReader {
    static let service = "Claude Code-credentials"

    static let readModificationDate: () -> Date? = {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any] else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    static let readCredentialsData: () -> Result<Data, KeychainReadFailure> = {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .failure(.denied(status: status)) }
            return .success(data)
        case errSecItemNotFound:
            return .failure(.itemNotFound)
        default:
            // errSecAuthFailed / errSecUserCanceled / anything else: treat as
            // denial so the core reader arms its prompt-suppression cooldown.
            return .failure(.denied(status: status))
        }
    }
}
