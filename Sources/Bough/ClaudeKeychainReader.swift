import Foundation
import Security
import BoughCore

/// App-target Keychain closures injected into BoughCore's
/// `ClaudeOAuthCredentialsReader` (the core target may not import Security —
/// ArchitectureBoundaryTests). The silent read goes through
/// `/usr/bin/security` (which the item's ACL/partition trusts, so it never
/// prompts); the prompt-capable in-process read is used only when an
/// explicit user retry has armed `.interactiveAllowed`, so background polls
/// can never show the macOS authorization dialog.
enum ClaudeKeychainReader {
    static let service = SecurityCLIKeychainReader.claudeService

    /// Attribute-only read (no `kSecReturnData`): decrypts nothing, so it
    /// never triggers an authorization dialog — safe on the silent path.
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

    static let readCredentialsData: (KeychainReadMode) -> Result<Data, KeychainReadFailure> = { mode in
        KeychainReadChain.run(
            mode: mode,
            silentRead: { SecurityCLIKeychainReader.readCredentialsData(service: service) },
            interactiveRead: { frameworkDataRead() }
        )
    }

    /// Delegated-refresh closure for `ClaudeOAuthUsageClient` (spec §3.4).
    static func makeDelegatedRefresh() -> () -> Bool {
        let coordinator = ClaudeDelegatedRefreshCoordinator(
            touch: {
                guard let path = ClaudeCLITouchRunner.resolvedClaudeExecutablePath() else {
                    throw ClaudeCLITouchError.claudeNotInstalled
                }
                try ClaudeCLITouchRunner.touchStatus(executablePath: path)
            },
            fingerprint: readModificationDate
        )
        return { coordinator.attempt() == .succeeded }
    }

    /// Prompt-capable in-process read. Reached only via the chain's
    /// `.interactiveAllowed` escalation (an explicit user retry), where the
    /// authorization dialog is exactly what we want — it lets the user pick
    /// "Always Allow".
    private static func frameworkDataRead() -> Result<Data, KeychainReadFailure> {
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
            // errSecAuthFailed / errSecUserCanceled: user denied — the 6h gate
            // (armed only for interactive reads) decides what happens next.
            return .failure(.denied(status: status))
        }
    }
}
