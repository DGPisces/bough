import Darwin
import Foundation

/// Minimal PTY "touch" of the Claude CLI (spec §3.4): spawn `claude` on a
/// pseudo-terminal, feed it `/status` periodically, and tear it down at the
/// deadline. The CLI refreshes its own OAuth token during startup/status —
/// success is judged by the coordinator via the Keychain fingerprint, never
/// by this process's output (which is deliberately discarded).
/// Adapted from steipete/CodexBar (MIT). See CREDITS.md.
public enum ClaudeCLITouchRunner {
    public static let defaultTimeout: TimeInterval = 8
    public static let defaultInputInterval: TimeInterval = 0.8

    public static func resolvedClaudeExecutablePath(candidates: [String]? = nil) -> String? {
        let paths = candidates ?? ClaudeCLIVersionProbe.defaultExecutableCandidates()
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func touchStatus(
        executablePath: String,
        timeout: TimeInterval = defaultTimeout,
        inputInterval: TimeInterval = defaultInputInterval
    ) throws {
        // PTY pair: the CLI needs a terminal to boot its REPL.
        let masterFD = posix_openpt(O_RDWR | O_NOCTTY)
        guard masterFD >= 0, grantpt(masterFD) == 0, unlockpt(masterFD) == 0,
              let slavePath = ptsname(masterFD).map({ String(cString: $0) }) else {
            if masterFD >= 0 { close(masterFD) }
            throw ClaudeCLITouchError.launchFailed
        }
        let slaveFD = open(slavePath, O_RDWR | O_NOCTTY)
        guard slaveFD >= 0 else {
            close(masterFD)
            throw ClaudeCLITouchError.launchFailed
        }
        // Non-blocking master so the drain loop never stalls.
        _ = fcntl(masterFD, F_SETFL, fcntl(masterFD, F_GETFL) | O_NONBLOCK)

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        let process = Process()
        // ponytail: macOS posix_spawn + PTY causes /bin/sh to treat PTY stdin as an
        // interactive command stream and ignore the script file. Detect a shebang and
        // invoke the interpreter with the script path as an explicit file argument so
        // non-interactive mode is preserved. This handles wrapper-script installs
        // (e.g. ~/.claude/local/claude is often a shell script) and test fakes;
        // Mach-O binaries (no #!) are exec'd directly and skip this path.
        process.executableURL = URL(fileURLWithPath: executablePath)
        if let handle = FileHandle(forReadingAtPath: executablePath) {
            let header = handle.readData(ofLength: 128)
            try? handle.close()
            if header.count > 2, header[0] == 0x23, header[1] == 0x21,
               let nlIdx = header.firstIndex(of: 0x0A) {
                let interpLine = String(data: header[2..<nlIdx], encoding: .utf8)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                let parts = interpLine.split(separator: " ", maxSplits: 1,
                                             omittingEmptySubsequences: true).map(String.init)
                if let interp = parts.first {
                    process.executableURL = URL(fileURLWithPath: interp)
                    process.arguments = (parts.count > 1 ? [parts[1]] : []) + [executablePath]
                }
            }
        }
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        defer { close(masterFD) }
        do { try process.run() } catch {
            close(slaveFD)
            throw ClaudeCLITouchError.launchFailed
        }
        // Parent-side slave copy is no longer needed once the child holds it.
        close(slaveFD)

        let pid = process.processIdentifier
        let pgidSet = setpgid(pid, pid) == 0
        let deadline = Date().addingTimeInterval(timeout)
        var nextInputAt = Date()
        var drainBuffer = [UInt8](repeating: 0, count: 4096)

        while process.isRunning && Date() < deadline {
            if Date() >= nextInputAt {
                _ = "/status\r".withCString { cString in
                    write(masterFD, cString, strlen(cString))
                }
                nextInputAt = Date().addingTimeInterval(inputInterval)
            }
            // Drain child output; a full PTY buffer would block the child.
            while read(masterFD, &drainBuffer, drainBuffer.count) > 0 {}
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            if pgidSet { kill(-pid, SIGTERM) } else { kill(pid, SIGTERM) }
            let killDeadline = Date().addingTimeInterval(0.4)
            while process.isRunning && Date() < killDeadline {
                while read(masterFD, &drainBuffer, drainBuffer.count) > 0 {}
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                if pgidSet { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
            }
        }
        process.waitUntilExit() // reap — no zombies
    }
}
