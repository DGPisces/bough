import Foundation
import Security
import BoughCore

/// App-target Keychain closures injected into BoughCore's
/// `ClaudeOAuthCredentialsReader` (the core target may not import Security —
/// ArchitectureBoundaryTests). Reads run the three-layer chain (spec §3.1):
/// no-UI framework read → security-CLI fallback → interactive read (armed
/// only by an explicit user retry). Background polls can no longer show the
/// macOS authorization dialog.
enum ClaudeKeychainReader {
    static let service = SecurityCLIKeychainReader.claudeService

    static let readModificationDate: () -> Date? = {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        KeychainNoUIQuery.apply(to: &query)
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any] else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    static let readCredentialsData: (KeychainReadMode) -> Result<Data, KeychainReadFailure> = { mode in
        KeychainReadChain.run(
            mode: mode,
            noUIRead: { frameworkDataRead(noUI: true) },
            cliRead: { SecurityCLIKeychainReader.readCredentialsData(service: service) },
            interactiveRead: { frameworkDataRead(noUI: false) }
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

    private static func frameworkDataRead(noUI: Bool) -> Result<Data, KeychainReadFailure> {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if noUI { KeychainNoUIQuery.apply(to: &query) }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .failure(.denied(status: status)) }
            return .success(data)
        case errSecItemNotFound:
            return .failure(.itemNotFound)
        default:
            // errSecInteractionNotAllowed / errSecAuthFailed / errSecUserCanceled:
            // denial semantics — the chain (or the 6h gate) decides what's next.
            return .failure(.denied(status: status))
        }
    }
}
