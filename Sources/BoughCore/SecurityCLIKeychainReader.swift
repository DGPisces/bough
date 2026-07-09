import Foundation

/// Reads the Claude Code CLI Keychain item by spawning `/usr/bin/security`.
/// The security binary sits in the item's ACL and its `apple-tool:` partition,
/// so this read NEVER shows an authorization dialog — unlike an in-process
/// SecItemCopyMatching from a partition-mismatched app.
/// Pure Foundation (no Security import) so both the app and the usage-monitor
/// helper can use it (ArchitectureBoundaryTests keeps Security out of BoughCore).
/// Adapted from steipete/CodexBar (MIT). See CREDITS.md.
public enum SecurityCLIKeychainReader {
    public static let claudeService = "Claude Code-credentials"
    public static let defaultBinaryPath = "/usr/bin/security"
    public static let defaultTimeout: TimeInterval = 1.5
    /// `security` exits 44 when the item does not exist.
    static let itemNotFoundExitCode: Int32 = 44

    public static func readCredentialsData(
        service: String,
        binaryPath: String = defaultBinaryPath,
        timeout: TimeInterval = defaultTimeout
    ) -> Result<Data, KeychainReadFailure> {
        guard let run = runCommand(
            binaryPath: binaryPath,
            arguments: ["find-generic-password", "-s", service, "-w"],
            timeout: timeout
        ) else { return .failure(.denied(status: -1)) }
        guard run.exitCode == 0 else {
            return run.exitCode == Self.itemNotFoundExitCode
                ? .failure(.itemNotFound)
                : .failure(.denied(status: run.exitCode))
        }
        var output = run.output
        while let last = output.last, last == 0x0A || last == 0x0D { output.removeLast() }
        guard !output.isEmpty else { return .failure(.denied(status: -1)) }
        return .success(output)
    }

    public static func readModificationDate(
        service: String,
        binaryPath: String = defaultBinaryPath,
        timeout: TimeInterval = defaultTimeout
    ) -> Date? {
        guard let run = runCommand(
            binaryPath: binaryPath,
            arguments: ["find-generic-password", "-s", service],
            timeout: timeout
        ), run.exitCode == 0,
            let text = String(data: run.output, encoding: .utf8) else { return nil }
        // Attribute line shape: "mdat"<timedate>=0x…  "20260709044355Z\000"
        let regex = try? NSRegularExpression(
            pattern: #""mdat"<timedate>=0x[0-9A-Fa-f]+ +"(\d{14})Z"#,
            options: []
        )
        guard let regex = regex else { return nil }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard let match = matches.first, match.numberOfRanges > 1 else { return nil }
        let digitsRange = match.range(at: 1)
        guard digitsRange.location != NSNotFound else { return nil }
        let digitsStr = nsText.substring(with: digitsRange)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: digitsStr)
    }

    private struct CommandRun {
        let exitCode: Int32
        let output: Data
    }

    private static func runCommand(
        binaryPath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> CommandRun? {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        // Attribute output may land on stderr on some OS builds; merge it.
        process.standardError = stdoutPipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let pid = process.processIdentifier
        let pgidSet = setpgid(pid, pid) == 0  // own process group so cleanup kills descendants
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            if pgidSet { kill(-pid, SIGTERM) } else { kill(pid, SIGTERM) }
            let killDeadline = Date().addingTimeInterval(0.4)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                if pgidSet { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
            }
            process.waitUntilExit() // reap
            return nil
        }
        let output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return CommandRun(exitCode: process.terminationStatus, output: output)
    }
}
