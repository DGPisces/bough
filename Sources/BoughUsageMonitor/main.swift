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

    init(_ arguments: [String]) throws {
        let values = Array(arguments.dropFirst())
        var index = 0
        while index < values.count {
            let argument = values[index]
            switch argument {
            case "--once":
                runOnce = true
                index += 1
            case "--status-path":
                statusPath = try Self.requiredValue(after: argument, in: values, index: &index)
            case "--continuity-path":
                continuityPath = try Self.requiredValue(after: argument, in: values, index: &index)
            case "--claude-usage-path":
                claudeUsagePath = try Self.requiredValue(after: argument, in: values, index: &index)
            case "--command-path":
                commandPath = try Self.requiredValue(after: argument, in: values, index: &index)
            case "--codex-executable-path":
                codexExecutablePath = try Self.requiredValue(after: argument, in: values, index: &index)
            case "--codex-timeout-seconds":
                let value = try Self.requiredValue(after: argument, in: values, index: &index)
                guard let seconds = TimeInterval(value), seconds.isFinite, seconds > 0 else {
                    throw UsageMonitorArgumentError.invalidValue(option: argument, value: value)
                }
                codexTimeoutSeconds = seconds
            default:
                throw UsageMonitorArgumentError.unknownOption(argument)
            }
        }
    }

    private static func requiredValue(after option: String, in values: [String], index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < values.count, !values[valueIndex].hasPrefix("--") else {
            throw UsageMonitorArgumentError.missingValue(option: option)
        }
        index += 2
        return values[valueIndex]
    }
}

enum UsageMonitorArgumentError: LocalizedError {
    case unknownOption(String)
    case missingValue(option: String)
    case invalidValue(option: String, value: String)

    var errorDescription: String? {
        switch self {
        case .unknownOption(let option):
            return "unknown option \(option)"
        case .missingValue(let option):
            return "missing value for \(option)"
        case .invalidValue(let option, let value):
            return "invalid value for \(option): \(value)"
        }
    }
}

let arguments: UsageMonitorArguments
do {
    arguments = try UsageMonitorArguments(CommandLine.arguments)
} catch {
    fputs("bough-usage-monitor: \(error.localizedDescription)\n", stderr)
    exit(2)
}

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
