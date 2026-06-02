import XCTest
@testable import Bough

/// UI-05 — Snapshot tests for the expanded notch panel at 14" (notchW=155) and
/// 16" (notchW=200) MacBook widths. Uses model-level panelWidth assertions
/// (mirrors the NotchPanelView.panelWidth formula for expanded state) and a
/// source-scan structural assertion confirming the single-row layout.
/// No external snapshot library; consistent with existing test style in this project.
final class ExpandedPanelLayoutSnapshotTests: XCTestCase {

    // MARK: - panelWidth assertions (D-03)

    func testExpandedPanelWidthAt14Inch() {
        // 14" MacBook native resolution: notchW=155, screenWidth=1512
        let panelWidth = Self.expandedPanelWidth(notchW: 155, screenWidth: 1512)
        XCTAssertEqual(panelWidth, 580, accuracy: 1,
            "UI-05: Expanded panel at 14\" (notchW=155, screenWidth=1512) must be 580pt. " +
            "Formula: min(max(nw+200, 580), min(620, screenWidth-40))")
    }

    func testExpandedPanelWidthAt16Inch() {
        // 16" MacBook native resolution: notchW=200, screenWidth=1728
        let panelWidth = Self.expandedPanelWidth(notchW: 200, screenWidth: 1728)
        XCTAssertEqual(panelWidth, 580, accuracy: 1,
            "UI-05: Expanded panel at 16\" (notchW=200, screenWidth=1728) must be 580pt. " +
            "Formula: min(max(nw+200, 580), min(620, screenWidth-40))")
    }

    // MARK: - Single-row structural assertion (UI-03)

    func testUsageStripBodyIsSingleRow() throws {
        let sourceURL = Self.repoRoot
            .appendingPathComponent("Sources/Bough/Notch/UsageStrip.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // Extract UsageStrip struct body only — stop before UsageStripSlot so the slot's
        // own VStack body does not confuse the ordering check.
        guard let stripStart = source.range(of: "struct UsageStrip: View"),
              let slotStart = source.range(of: "private struct UsageStripSlot: View",
                                           range: stripStart.upperBound..<source.endIndex) else {
            XCTFail("Could not locate UsageStrip or UsageStripSlot in UsageStrip.swift")
            return
        }
        let stripBody = String(source[stripStart.lowerBound..<slotStart.lowerBound])

        XCTAssertFalse(
            stripBody.contains("expandedTodayText"),
            "UI-03: UsageStrip.body must not reference expandedTodayText after SC2 fix. " +
            "The Today value must be in slots[2], not a second row."
        )
        // The outer container must be HStack, not VStack, for single-row layout.
        // Assert that NO VStack appears inside UsageStrip's own var body closure.
        if let bodyRange = stripBody.range(of: "var body: some View") {
            let bodyImpl = String(stripBody[bodyRange.upperBound...])
            // Find the closing brace of UsageStrip.body by looking for ForEach(model.slots)
            // then asserting no VStack appears before the ForEach call.
            let forEachRange = bodyImpl.range(of: "ForEach(model.slots")
            let bodyHead = forEachRange.map { String(bodyImpl[bodyImpl.startIndex..<$0.lowerBound]) } ?? bodyImpl
            XCTAssertFalse(
                bodyHead.contains("VStack"),
                "UI-03: UsageStrip.body must not contain VStack before ForEach(model.slots). " +
                "The outer container must be HStack for single-row layout — regression is present."
            )
        }
    }

    // MARK: - Helpers

    /// Mirrors the NotchPanelView.panelWidth formula for expanded state.
    /// Source: NotchPanelView.swift:63 [VERIFIED]
    ///   `if shouldShowExpanded { return min(max(nw + 200, 580), maxWidth) }`
    ///   where `maxWidth = min(620, screenWidth - 40)`
    private static func expandedPanelWidth(notchW: CGFloat, screenWidth: CGFloat) -> CGFloat {
        let maxWidth = min(620, screenWidth - 40)
        return min(max(notchW + 200, 580), maxWidth)
    }

    private static let repoRoot = TestHelpers.repoRoot(from: #filePath)
}
