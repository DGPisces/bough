import Foundation

struct RemoteHost: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var host: String
    var user: String
    var port: Int?
    var identityFile: String
    var autoConnect: Bool
    /// Optional SSH_AUTH_SOCK path — lets password-manager-backed SSH agents
    /// (1Password, Bitwarden, etc.) sign the handshake when the GUI launch
    /// didn't inherit the env var from a shell. See issue #81.
    var authSocket: String

    init(
        id: String = UUID().uuidString,
        name: String,
        host: String,
        user: String = "",
        port: Int? = nil,
        identityFile: String = "",
        autoConnect: Bool = false,
        authSocket: String = ""
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.autoConnect = autoConnect
        self.authSocket = authSocket
    }

    // Backward compatibility: hosts persisted before authSocket existed decode with ""
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.host = try c.decode(String.self, forKey: .host)
        self.user = try c.decode(String.self, forKey: .user)
        self.port = try c.decodeIfPresent(Int.self, forKey: .port)
        self.identityFile = try c.decode(String.self, forKey: .identityFile)
        self.autoConnect = try c.decode(Bool.self, forKey: .autoConnect)
        self.authSocket = try c.decodeIfPresent(String.self, forKey: .authSocket) ?? ""
    }

    var sshTarget: String {
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedUser.isEmpty {
            return host.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "\(trimmedUser)@\(host.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    var validatedSSHTarget: String? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeSSHDestinationComponent(trimmedHost, allowEmpty: false) else { return nil }

        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeSSHDestinationComponent(trimmedUser, allowEmpty: true) else { return nil }

        if trimmedUser.isEmpty {
            return trimmedHost
        }
        return "\(trimmedUser)@\(trimmedHost)"
    }

    var remoteSocketDirectory: String {
        "/tmp/bough-\(remoteSocketSlug)"
    }

    var remoteSocketPath: String {
        "\(remoteSocketDirectory)/hook.sock"
    }

    private var remoteSocketSlug: String {
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = trimmedUser.isEmpty ? NSUserName() : trimmedUser
        let raw = "\(owner)-\(id)"
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let scalars = raw.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return String((sanitized.isEmpty ? "host" : sanitized).prefix(64))
    }

    var displayAddress: String {
        if let port {
            return "\(sshTarget):\(port)"
        }
        return sshTarget
    }

    private static func isSafeSSHDestinationComponent(_ value: String, allowEmpty: Bool) -> Bool {
        if value.isEmpty { return allowEmpty }
        if value.hasPrefix("-") { return false }
        return value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
