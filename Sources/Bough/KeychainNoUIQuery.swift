import Foundation
import LocalAuthentication
import Security

/// Applies the non-interactive authorization context to a SecItem query:
/// with these flags a read either succeeds silently (modern authorization
/// path honors the session's unlock state) or fails with
/// errSecInteractionNotAllowed — it can never show the legacy Allow/Deny/
/// password dialog. Verified on this repo's target OS: a plain data read of
/// the CLI-owned item hangs on a dialog; the flagged read returns the data.
/// Adapted from steipete/CodexBar (MIT). See CREDITS.md.
enum KeychainNoUIQuery {
    /// The raw value of the deprecated `kSecUseAuthenticationUIFail`
    /// constant. Referenced as a frozen literal instead of the symbol
    /// (which warns at compile time) or a dynamic symbol lookup
    /// (repo governance confines dynamic framework loading to the
    /// music adapter layer). The value is ABI-stable; verified
    /// silent-read behavior on the target OS.
    private static let uiFailPolicy = "u_AuthUIF"

    static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = uiFailPolicy as CFString
    }
}
