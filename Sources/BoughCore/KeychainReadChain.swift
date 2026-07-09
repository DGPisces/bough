import Foundation

/// How far a Keychain read may escalate. Background polls are always
/// `.silent`; `.interactiveAllowed` is armed once per explicit user retry
/// (CodexBar's `onlyOnUserAction` prompt policy).
public enum KeychainReadMode: Sendable {
    case silent
    case interactiveAllowed
}

/// The three-layer read chain (spec §3.1): no-UI framework read →
/// security-CLI fallback → (user-action only) interactive read.
/// Pure function over injected closures so the ordering semantics are unit
/// tested without a real Keychain.
public enum KeychainReadChain {
    public static func run(
        mode: KeychainReadMode,
        noUIRead: () -> Result<Data, KeychainReadFailure>,
        cliRead: () -> Result<Data, KeychainReadFailure>,
        interactiveRead: () -> Result<Data, KeychainReadFailure>
    ) -> Result<Data, KeychainReadFailure> {
        let noUIResult = noUIRead()
        switch noUIResult {
        case .success:
            return noUIResult
        case .failure(.itemNotFound):
            // A no-UI query resolves existence without authorization; a
            // missing item is trustworthy — don't spawn the CLI for it.
            return noUIResult
        case .failure(.denied):
            break
        }
        switch cliRead() {
        case .success(let data):
            return .success(data)
        case .failure(.itemNotFound):
            return .failure(.itemNotFound)
        case .failure(.denied):
            guard mode == .interactiveAllowed else { return noUIResult }
            return interactiveRead()
        }
    }
}
