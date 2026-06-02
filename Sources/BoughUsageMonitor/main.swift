import Foundation
import BoughCore

struct UsageMonitorArguments {
    var runOnce = false
    var statusPath = UsageMonitorRunner.defaultStatusPath()
    var continuityPath = UsageContinuityStore.defaultPath()
    var claudeUsagePath = UsageMonitorRunner.defaultClaudeUsageFilePath()
    var commandPath = UsageMonitorRunner.defaultCommandPath()
    var codexExecutablePath = CodexAppServerClient.defaultExecutablePath
    var codexTimeoutSeconds: TimeInterval = 10

    init(_ arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--once":
                runOnce = true
            case "--status-path":
                if let value = iterator.next() { statusPath = value }
            case "--continuity-path":
                if let value = iterator.next() { continuityPath = value }
            case "--claude-usage-path":
                if let value = iterator.next() { claudeUsagePath = value }
            case "--command-path":
                if let value = iterator.next() { commandPath = value }
            case "--codex-executable-path":
                if let value = iterator.next() { codexExecutablePath = value }
            case "--codex-timeout-seconds":
                if let value = iterator.next(), let seconds = TimeInterval(value) {
                    codexTimeoutSeconds = seconds
                }
            default:
                continue
            }
        }
    }
}

let arguments = UsageMonitorArguments(CommandLine.arguments)

do {
    let store = try UsageContinuityStore(path: arguments.continuityPath)
    let runner = UsageMonitorRunner(
        continuityStore: store,
        claudeUsageFilePath: arguments.claudeUsagePath,
        statusPath: arguments.statusPath,
        commandPath: arguments.commandPath,
        codexRateLimitReader: CodexAppServerRateLimitMonitorReader(
            executableURL: URL(fileURLWithPath: arguments.codexExecutablePath),
            timeoutSeconds: arguments.codexTimeoutSeconds
        )
    )

    if arguments.runOnce {
        _ = runner.runOnce()
    } else {
        while true {
            _ = runner.runOnce()
            Thread.sleep(forTimeInterval: UsageMonitorRunner.appClosedIdleInterval)
        }
    }
} catch {
    fputs("bough-usage-monitor: \(error)\n", stderr)
    exit(1)
}
