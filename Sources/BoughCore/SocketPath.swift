import Foundation
import Darwin

public enum SocketPath {
    public static var defaultPath: String {
        "/tmp/bough-\(getuid()).sock"
    }

    public static var path: String {
        if let env = ProcessInfo.processInfo.environment["BOUGH_SOCKET_PATH"], !env.isEmpty {
            return env
        }
        return defaultPath
    }

    public static func canAutoRemoveExistingSocket(at path: String) -> Bool {
        path == defaultPath
    }
}
