import Darwin
import XCTest
@testable import BoughCore

final class ClaudeCLITouchRunnerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("touch-runner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func fakeClaude(script: String) throws -> String {
        let url = tempDir.appendingPathComponent("claude")
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testResolvedPathReturnsFirstExecutableCandidate() throws {
        let real = try fakeClaude(script: "true")
        let missing = tempDir.appendingPathComponent("missing").path
        XCTAssertEqual(
            ClaudeCLITouchRunner.resolvedClaudeExecutablePath(candidates: [missing, real]), real)
        XCTAssertNil(ClaudeCLITouchRunner.resolvedClaudeExecutablePath(candidates: [missing]))
    }

    func testTouchWritesStatusInputToChild() throws {
        let capture = tempDir.appendingPathComponent("captured.txt").path
        // 读 stdin 写入文件，读到内容即退出。
        let bin = try fakeClaude(script: "head -c 8 > '\(capture)'")
        try ClaudeCLITouchRunner.touchStatus(executablePath: bin, timeout: 3, inputInterval: 0.1)
        let captured = try String(contentsOfFile: capture, encoding: .utf8)
        XCTAssertTrue(captured.contains("/status"), "captured: \(captured)")
    }

    func testTouchKillsLongRunningChildAtDeadline() throws {
        let pidFile = tempDir.appendingPathComponent("pid.txt").path
        let bin = try fakeClaude(script: "echo $$ > '\(pidFile)'; sleep 60")
        let started = Date()
        try ClaudeCLITouchRunner.touchStatus(executablePath: bin, timeout: 0.5, inputInterval: 0.1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        // 子进程必须已被收割/终止。
        let pid = Int32(try String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        XCTAssertGreaterThan(pid, 0)
        // ESRCH 才算干净；给 SIGTERM→SIGKILL 一点收尾时间。
        let deadline = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(kill(pid, 0), -1)
    }

    func testTouchSurvivesChattyChildOutput() throws {
        // 子进程猛写输出：runner 必须持续排空 PTY master，否则子进程阻塞、
        // deadline 失效。yes 每行 2 字节，1s 内可产出远超 PTY 缓冲。
        let bin = try fakeClaude(script: "yes chatty-output-line")
        let started = Date()
        try ClaudeCLITouchRunner.touchStatus(executablePath: bin, timeout: 0.6, inputInterval: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testMissingBinaryThrowsLaunchFailed() {
        XCTAssertThrowsError(try ClaudeCLITouchRunner.touchStatus(
            executablePath: tempDir.appendingPathComponent("nope").path, timeout: 0.5)
        ) { error in
            XCTAssertEqual(error as? ClaudeCLITouchError, .launchFailed)
        }
    }
}
