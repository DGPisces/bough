import Foundation

/// How far a Keychain read may escalate. Background polls are always
/// `.silent`; `.interactiveAllowed` is armed once per explicit user retry
/// (CodexBar's `onlyOnUserAction` prompt policy).
public enum KeychainReadMode: Sendable {
    case silent
    case interactiveAllowed
}

/// Two-layer read chain: a silent read that can never prompt (the
/// `/usr/bin/security` subprocess, which sits in the item's ACL/partition)
/// followed — only on an explicit user retry — by a prompt-capable
/// interactive read that lets the user grant "Always Allow".
///
/// An in-process `SecItemCopyMatching` data read is NOT used on the silent
/// path: `kSecUseAuthenticationUIFail` + `LAContext.interactionNotAllowed`
/// do not reliably suppress the legacy ACL authorization dialog — the read
/// blocks on the dialog instead of failing closed, which is exactly the
/// prompt we must avoid. Pure function so the ordering is unit-tested
/// without a real Keychain.
public enum KeychainReadChain {
    public static func run(
        mode: KeychainReadMode,
        silentRead: () -> Result<Data, KeychainReadFailure>,
        interactiveRead: () -> Result<Data, KeychainReadFailure>
    ) -> Result<Data, KeychainReadFailure> {
        let result = silentRead()
        switch result {
        case .success, .failure(.itemNotFound):
            return result
        case .failure(.denied):
            guard mode == .interactiveAllowed else { return result }
            return interactiveRead()
        }
    }
}
