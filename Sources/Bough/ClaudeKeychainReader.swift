import Foundation
import Security
import BoughCore

/// App-target Keychain closure injected into BoughCore's
/// `ClaudeOAuthCredentialsReader` (the core target may not import Security —
/// ArchitectureBoundaryTests). Reads the generic password the Claude Code CLI
/// stores its OAuth credentials under. First access can show a one-time macOS
/// authorization prompt; denial maps to `.denied` and the reader's 6h gate.
enum ClaudeKeychainReader {
    static let service = "Claude Code-credentials"

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
