import Darwin
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
    private static let uiFailPolicy = resolveUIFailPolicy()

    static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = uiFailPolicy as CFString
    }

    /// Resolve the deprecated kSecUseAuthenticationUIFail constant at runtime
    /// so we keep its true value without referencing deprecated API at
    /// compile time; fall back to the known literal.
    private static func resolveUIFailPolicy() -> String {
        let securityPath = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(securityPath, RTLD_NOW) else { return "u_AuthUIF" }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else { return "u_AuthUIF" }
        return (symbol.assumingMemoryBound(to: CFString?.self).pointee as String?) ?? "u_AuthUIF"
    }
}
