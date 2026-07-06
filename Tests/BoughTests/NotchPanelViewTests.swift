import XCTest
@testable import Bough
@testable import BoughCore

final class NotchPanelViewTests: XCTestCase {
    private var savedLanguage: String!
    private var savedLanguageDefaultValue: Any?
    private var lockedProcessState = false

    override func setUp() {
        super.setUp()
        TestHelpers.processStateLock.lock()
        lockedProcessState = true
        savedLanguage = L10n.shared.language
        savedLanguageDefaultValue = UserDefaults.standard.object(forKey: SettingsKey.appLanguage)
        L10n.shared.language = "en"
    }

    override func tearDown() {
        if lockedProcessState {
            TestHelpers.restoreSharedLanguage(savedLanguage, savedDefaultValue: savedLanguageDefaultValue)
        }
        savedLanguage = nil
        savedLanguageDefaultValue = nil
        if lockedProcessState {
            TestHelpers.processStateLock.unlock()
            lockedProcessState = false
        }
        super.tearDown()
    }

    // UI-03: three-slot layout (5h, Week, Today)

    func testUsageStripRendersThreeDataSlots() {
        let now = Date(timeIntervalSince1970: 1_000)
        let five = UsageWindowSnapshot(kind: .fiveHour, usedPercent: 12.8, resetsAt: Date(timeIntervalSince1970: 1_900), windowDurationMins: 300, sourceLabel: "Codex", updatedAt: now)
        let week = UsageWindowSnapshot(kind: .weekly, usedPercent: 58.9, resetsAt: Date(timeIntervalSince1970: 91_000), windowDurationMins: 10080, sourceLabel: "Codex", updatedAt: now)
        let basis = TodayBasis(localDate: "2026-05-16", weeklyUsedAtDayStart: 30.0, weeklyUsedNow: 40.0, todayAllowanceOfWeek: 14.3, daysRemainingUntilWeeklyReset: 3.0, weeklyResetAlreadyFiredToday: false)
        let today = TodayValue(pct: 50.0, todayAllowanceOfWeek: 14.3, severity: .healthy, basis: basis)
        let snapshot = UsageSnapshot(tool: .codex, planName: "prolite", fiveHour: .available(five), weekly: .available(week), today: today, availability: .available, lastRefresh: now)

        let model = UsageStripModel(snapshot: snapshot, now: now)

        XCTAssertEqual(model.slots.count, 3, "UI-03: expanded strip must render three data slots (5h, Week, Today)")
        XCTAssertEqual(model.slots[0].value, "87% · 15m")
        XCTAssertEqual(model.slots[1].value, "41% · 1d 1h 0m")
        XCTAssertEqual(model.slots[2].title, "Today")
        XCTAssertEqual(model.slots[2].severity, .healthy)
    }

    func testUsageStripShowsCompactResetExplanation() {
        let now = Date(timeIntervalSince1970: 1_000)
        let basis = TodayBasis(
            localDate: "2026-05-16",
            weeklyUsedAtDayStart: 80.0,
            weeklyUsedNow: 4.0,
            todayAllowanceOfWeek: 20.0,
            daysRemainingUntilWeeklyReset: 7.0,
            weeklyResetAlreadyFiredToday: true,
            resetProvenance: .explicitReset
        )
        let today = TodayValue(pct: -20.0, todayAllowanceOfWeek: 20.0, severity: .overdraft, basis: basis)
        let snapshot = UsageSnapshot(tool: .codex, planName: "prolite", fiveHour: .loading, weekly: .loading, today: today, availability: .available, lastRefresh: now)

        let model = UsageStripModel(snapshot: snapshot, now: now)

        XCTAssertEqual(model.slots[2].value, "-20% · 20.0%/wk · weekly reset included")
    }

    func testUsageStripTreatsNonFiniteTodayValueAsUnavailable() {
        let now = Date(timeIntervalSince1970: 1_000)
        let basis = TodayBasis(
            localDate: "2026-05-16",
            weeklyUsedAtDayStart: 100.0,
            weeklyUsedNow: 100.0,
            todayAllowanceOfWeek: 0.0,
            daysRemainingUntilWeeklyReset: 7.0,
            weeklyResetAlreadyFiredToday: false
        )
        let today = TodayValue(pct: .nan, todayAllowanceOfWeek: 0, severity: .depleted, basis: basis)
        let snapshot = UsageSnapshot(tool: .codex, planName: "prolite", fiveHour: .loading, weekly: .loading, today: today, availability: .available, lastRefresh: now)

        let model = UsageStripModel(snapshot: snapshot, now: now)

        XCTAssertEqual(model.slots[2].value, "Unavailable")
    }

    func testFiveHourSlotUsesCompactFormatWithMinutePrecision() {
        let now = Date(timeIntervalSince1970: 1_000)
        func value(resetIn: TimeInterval) -> String {
            let five = UsageWindowSnapshot(kind: .fiveHour, usedPercent: 10, resetsAt: now.addingTimeInterval(resetIn), windowDurationMins: 300, sourceLabel: "Codex", updatedAt: now)
            let snapshot = UsageSnapshot(tool: .codex, planName: nil, fiveHour: .available(five), weekly: .loading, today: nil, availability: .available, lastRefresh: now)
            return UsageStripModel(snapshot: snapshot, now: now).slots[0].value
        }

        XCTAssertEqual(value(resetIn: 30), "90% · 0m")           // sub-minute floors to 0m (no seconds)
        XCTAssertEqual(value(resetIn: 15 * 60), "90% · 15m")
        XCTAssertEqual(value(resetIn: 60 * 60), "90% · 1h")
        XCTAssertEqual(value(resetIn: 83 * 60), "90% · 1h 23m")
        XCTAssertEqual(value(resetIn: 71 * 3600 + 59 * 60), "90% · 71h 59m")
        XCTAssertEqual(value(resetIn: 4 * 24 * 3600), "90% · 4d")
        XCTAssertEqual(value(resetIn: 4 * 24 * 3600 + 23 * 60), "90% · 4d 23m")
        XCTAssertEqual(value(resetIn: 4 * 24 * 3600 + 5 * 3600), "90% · 4d 5h")
        XCTAssertEqual(value(resetIn: 4 * 24 * 3600 + 5 * 3600 + 23 * 60), "90% · 4d 5h 23m")
    }

    func testWeeklySlotAlwaysUsesFullDayHourMinuteFormat() {
        let now = Date(timeIntervalSince1970: 1_000)
        func value(resetIn: TimeInterval) -> String {
            let week = UsageWindowSnapshot(kind: .weekly, usedPercent: 10, resetsAt: now.addingTimeInterval(resetIn), windowDurationMins: 10080, sourceLabel: "Codex", updatedAt: now)
            let snapshot = UsageSnapshot(tool: .codex, planName: nil, fiveHour: .loading, weekly: .available(week), today: nil, availability: .available, lastRefresh: now)
            return UsageStripModel(snapshot: snapshot, now: now).slots[1].value
        }

        XCTAssertEqual(value(resetIn: 30), "90% · 0d 0h 0m")
        XCTAssertEqual(value(resetIn: 15 * 60), "90% · 0d 0h 15m")
        XCTAssertEqual(value(resetIn: 5 * 3600 + 23 * 60), "90% · 0d 5h 23m")
        XCTAssertEqual(value(resetIn: 25 * 3600), "90% · 1d 1h 0m")
        XCTAssertEqual(value(resetIn: 4 * 24 * 3600), "90% · 4d 0h 0m")
        XCTAssertEqual(value(resetIn: 4 * 24 * 3600 + 5 * 3600 + 23 * 60), "90% · 4d 5h 23m")
    }

    func testUsageStripLabelsStaleValues() {
        let now = Date(timeIntervalSince1970: 1_000)
        let week = UsageWindowSnapshot(kind: .weekly, usedPercent: 58, resetsAt: Date(timeIntervalSince1970: 4_000), windowDurationMins: 10080, sourceLabel: "Codex", updatedAt: Date(timeIntervalSince1970: 100))
        let snapshot = UsageSnapshot(tool: .codex, planName: nil, fiveHour: .loading, weekly: .stale(week, reason: "Usage data is stale"), today: nil, availability: .stale(reason: "Usage data is stale"), lastRefresh: Date(timeIntervalSince1970: 100))

        let model = UsageStripModel(snapshot: snapshot, now: now)

        XCTAssertEqual(model.slots[0].value, "Loading")
        XCTAssertEqual(model.slots[1].value, "42% · 0d 0h 50m · Stale")
        XCTAssertEqual(model.statusLabel, "Stale")
    }

    func testUsageStripLabelsRefreshFailedValues() {
        let now = Date(timeIntervalSince1970: 1_000)
        let week = UsageWindowSnapshot(kind: .weekly, usedPercent: 58, resetsAt: Date(timeIntervalSince1970: 4_000), windowDurationMins: 10080, sourceLabel: "Codex", updatedAt: Date(timeIntervalSince1970: 100))
        let snapshot = UsageSnapshot(tool: .codex, planName: nil, fiveHour: .loading, weekly: .stale(week, reason: "Refresh failed"), today: nil, availability: .stale(reason: "Refresh failed"), lastRefresh: Date(timeIntervalSince1970: 100))

        let model = UsageStripModel(snapshot: snapshot, now: now)

        XCTAssertEqual(model.slots[1].value, "42% · 0d 0h 50m · Refresh failed")
        XCTAssertEqual(model.statusLabel, "Refresh failed")
    }

    func testUsageStripFormatsUnavailableClaudeWithoutPercentages() {
        let snapshot = UsageSnapshot.claudeUnavailable(now: Date(timeIntervalSince1970: 100))
        let model = UsageStripModel(snapshot: snapshot, now: Date(timeIntervalSince1970: 200))
        // UI-03: three-slot layout — 5h, Week, Today all show Unavailable when Claude data is absent.
        XCTAssertEqual(model.slots.map(\.value), ["Unavailable", "Unavailable", "Unavailable"])
    }

    func testUsageStripHidesForInteractiveSurfaces() {
        XCTAssertFalse(UsageStripModel.shouldShow(surface: .approvalCard(sessionId: "s1"), onlySessionId: nil))
        XCTAssertFalse(UsageStripModel.shouldShow(surface: .questionCard(sessionId: "s1"), onlySessionId: nil))
        XCTAssertFalse(UsageStripModel.shouldShow(surface: .collapsed, onlySessionId: nil))
        XCTAssertFalse(UsageStripModel.shouldShow(surface: .sessionList, onlySessionId: "s1"))
        XCTAssertFalse(UsageStripModel.shouldShow(surface: .completionCard(sessionId: "s1"), onlySessionId: "s1"))
        XCTAssertTrue(UsageStripModel.shouldShow(surface: .sessionList, onlySessionId: nil))
        XCTAssertTrue(UsageStripModel.shouldShow(surface: .completionCard(sessionId: "s1"), onlySessionId: nil))
    }

    func testMusicActivityPolicySourceIsUsedByNotchPanelView() throws {
        let source = try sourceFile("Sources/Bough/NotchPanelView.swift")

        XCTAssertTrue(source.contains("@AppStorage(SettingsKey.showMusicControls)"))
        XCTAssertTrue(source.contains("@AppStorage(SettingsKey.compactBarPriority)"))
        XCTAssertTrue(source.contains("@AppStorage(SettingsKey.codingSessionsEnabled)"))
        XCTAssertTrue(source.contains("MusicPanelActivityPolicy.hasVisibleMusicActivity"))
        XCTAssertTrue(source.contains("MusicPanelActivityPolicy.shouldShowBar"))
        XCTAssertTrue(source.contains("MusicPanelActivityPolicy.compactSource"))
        XCTAssertTrue(source.contains("appState.musicStore.setPresentationNeeded"))
        XCTAssertTrue(source.contains("MusicPanelActivityPolicy.presentationNeeded"))
        XCTAssertTrue(source.contains("musicRenderRevision"))
        XCTAssertTrue(source.contains("NotificationCenter.default.publisher"))
        XCTAssertTrue(source.contains("MusicNowPlayingStore.didChangeNotification"))
        XCTAssertFalse(source.contains("IslandSurface.music"))
        XCTAssertFalse(source.contains("struct MusicStrip"))
        XCTAssertFalse(source.contains("struct MusicFigureView"))
    }

    func testOffModePanelRoutesToProductHomeInsteadOfSessionList() throws {
        let source = try sourceFile("Sources/Bough/NotchPanelView.swift")
        let expandedContent = try XCTUnwrap(source.slice(from: "// Below-notch expanded content", to: ".frame(width: panelWidth)"))
        let productBar = try XCTUnwrap(source.slice(from: "private var productBar: some View", to: "// MARK: - Compact Wings"))
        let boughHomePanel = try XCTUnwrap(source.slice(from: "private struct BoughHomePanel: View", to: "private struct ProductModeMusicPanel: View"))
        let productModeMusicPanel = try XCTUnwrap(source.slice(from: "private struct ProductModeMusicPanel: View", to: "// MARK: - Approval Bar"))

        // Routing: coding-off selects the productHome bar mode and the BoughHome below-notch panel.
        XCTAssertTrue(source.contains("private var showProductHome"))
        XCTAssertTrue(source.contains("!codingSessionsEnabled && !hasVisibleMusicActivity && !hideWhenNoSession"))
        XCTAssertTrue(source.contains("if showProductHome { return .productHome }"))
        XCTAssertTrue(expandedContent.contains("if !codingSessionsEnabled"))
        XCTAssertTrue(expandedContent.contains("ProductModeMusicPanel("))
        XCTAssertTrue(expandedContent.contains("BoughHomePanel(appState: appState)"))

        // productHome compact bar: brand mascot + settings/quit (no sound), micro-animated, no session UI.
        XCTAssertTrue(productBar.contains("BoughMascotView(fixedFrame: 0, frameSize: mascotSize)"))
        XCTAssertTrue(productBar.contains(".opacity(expanded ? 1 : 0.9)"))
        XCTAssertTrue(productBar.contains("NotchActionButtons(includeSound: false, spacing: 4)"))
        XCTAssertTrue(productBar.contains(".animation(NotchAnimation.micro, value: expanded)"))
        XCTAssertFalse(productBar.contains("includeSound: true"))
        XCTAssertFalse(productBar.contains("SessionListView("))
        XCTAssertFalse(productBar.contains("UsageStrip("))
        XCTAssertFalse(productBar.contains("SessionCountLabel("))

        // The below-notch home panel is brand-only; action buttons live on the bar, not the panel.
        XCTAssertTrue(boughHomePanel.contains("BoughMascotView(frameSize: 56)"))
        XCTAssertFalse(boughHomePanel.contains("NotchActionButtons("))
        XCTAssertFalse(boughHomePanel.contains("SettingsWindowController.shared.show()"))
        XCTAssertFalse(boughHomePanel.contains("NSApplication.shared.terminate(nil)"))
        XCTAssertFalse(productModeMusicPanel.contains("NotchActionButtons("))
        XCTAssertFalse(productModeMusicPanel.contains("SettingsWindowController.shared.show()"))
    }

    func testCompactMascotPlacementMatchesOriginalAndAllSourcesHaveStableFrames() throws {
        let source = try sourceFile("Sources/Bough/NotchPanelView.swift")
        let mascotRouter = try sourceFile("Sources/Bough/MascotView.swift")
        let leftWing = try XCTUnwrap(source.slice(from: "private struct CompactLeftWing: View", to: "/// Right side: project name"))
        let idleBar = try XCTUnwrap(source.slice(from: "private var idleBar: some View", to: "private var productBar"))
        let productBar = try XCTUnwrap(source.slice(from: "private var productBar: some View", to: "// MARK: - Compact Wings"))

        XCTAssertFalse(source.contains("CompactMascotSlot"))
        XCTAssertTrue(leftWing.contains("HStack(spacing: 6)"))
        XCTAssertTrue(leftWing.contains(".padding(.leading, 6)"))
        XCTAssertFalse(leftWing.contains("let notchHeight: CGFloat"))
        XCTAssertTrue(leftWing.contains("MusicFigureView(snapshot: appState.musicStore.snapshot, size: mascotSize, onlineArtwork: appState.musicStore.onlineArtwork)"))
        XCTAssertTrue(leftWing.contains("CompactToolActivityDot(tool: shownTool)"))

        XCTAssertTrue(idleBar.contains("HStack(spacing: 6)"))
        XCTAssertTrue(idleBar.contains(".padding(.leading, 6)"))
        XCTAssertTrue(productBar.contains("HStack(spacing: 6)"))
        XCTAssertTrue(productBar.contains(".padding(.leading, 6)"))
        XCTAssertTrue(mascotRouter.contains(".frame(width: size, height: size, alignment: .center)"))
        XCTAssertFalse(mascotRouter.contains("TimelineView"))
        XCTAssertFalse(mascotRouter.contains("Timer"))
        XCTAssertFalse(mascotRouter.contains("Task"))
        XCTAssertFalse(mascotRouter.contains("withAnimation"))
        XCTAssertFalse(mascotRouter.contains("matchedGeometryEffect"))

        XCTAssertTrue(mascotRouter.contains("MascotSpriteCatalog.spec(source: source, status: status)"))
        XCTAssertTrue(mascotRouter.contains("MascotSpriteCatalog.fallbackSpec(status: status)"))
        XCTAssertTrue(mascotRouter.contains("SpriteMascotView(spec: spec, size: size, mascotSpeed: speed)"))
        XCTAssertFalse(mascotRouter.contains("LayerBackedMascotView"))
        XCTAssertTrue(leftWing.contains("MascotView(source: source, status: status, size: compactSize)"))
        XCTAssertTrue(idleBar.contains("source: settingsDefaultSource"))
    }

    func testCollapsedNotchToolStatusUsesFixedDotInsteadOfToolText() throws {
        let source = try sourceFile("Sources/Bough/NotchPanelView.swift")
        let width = try XCTUnwrap(source.slice(from: "private var panelWidth: CGFloat", to: "private var expandedContentTransition"))
        let leftWing = try XCTUnwrap(source.slice(from: "private struct CompactLeftWing: View", to: "private enum AIMascotTransitionID"))
        let dot = try XCTUnwrap(source.slice(from: "private struct CompactToolActivityDot: View", to: "// MARK: - Tool Status Helpers"))

        XCTAssertTrue(width.contains("hasNotch ? 13 : screenWidth * 0.04"))
        XCTAssertTrue(leftWing.contains("if hasNotch, showToolStatus {"))
        XCTAssertTrue(leftWing.contains("CompactToolActivityDot(tool: shownTool)"))
        XCTAssertFalse(leftWing.contains("Text(tool)"))
        XCTAssertFalse(leftWing.contains(".fixedSize()"))
        XCTAssertTrue(leftWing.contains(".onAppear {\n            shownTool = liveTool\n        }"))

        XCTAssertTrue(dot.contains("Image(systemName: \"circle.fill\")"))
        XCTAssertTrue(dot.contains("toolStatusColor(tool)"))
        XCTAssertTrue(dot.contains(".symbolEffect(.pulse, options: .repeating)"))
        XCTAssertTrue(dot.contains("Color.clear"))
        XCTAssertTrue(dot.contains(".frame(width: 7, height: 7)"))
        XCTAssertTrue(dot.contains(".accessibilityHidden(true)"))
    }

    func testExpandedPanelShellKeepsContentHeight() throws {
        let source = try sourceFile("Sources/Bough/NotchPanelView.swift")
        let panel = try XCTUnwrap(source.slice(from: "struct NotchPanelView: View", to: "// MARK: - Compact Bar"))
        let shell = try XCTUnwrap(source.slice(from: "CompactBar(", to: ".frame(width: panelWidth)"))
        let expandedContent = try XCTUnwrap(source.slice(from: "// Below-notch expanded content", to: ".fixedSize(horizontal: false, vertical: true)"))
        let activeBar = try XCTUnwrap(source.slice(from: "private var activeBar: some View", to: "private var idleBar"))
        let sessionSurfaces = try XCTUnwrap(source.slice(from: "case .completionCard:", to: "case .collapsed, .airDrop:"))

        XCTAssertTrue(
            shell.contains(".fixedSize(horizontal: false, vertical: true)"),
            "The panel window reserves scroll capacity, but the visible notch shell should stay content-height so a single session does not fill the whole window."
        )
        XCTAssertTrue(activeBar.contains(".background(expanded ? Color.black : Color.clear)"))
        XCTAssertTrue(
            source.contains(".zIndex(compactBarMode.sitsAboveExpandedContent ? 1 : 0)"),
            "The compact bar should stay above collapsing expanded content so session-card mascots never appear to drive the top mascot transition."
        )
        XCTAssertTrue(source.contains("self == .active || self == .idleIndicator"))
        XCTAssertEqual(sessionSurfaces.occurrences(of: ".transition(expandedContentTransition)"), 2)
        // 8 content sites + the Line() divider (which lagged behind the
        // fast-insertion content when it rode the slow-start open spring).
        XCTAssertFalse(sessionSurfaces.contains("if sessionSurfaceContentShouldBeVisible"))
        XCTAssertTrue(panel.contains(".animation(NotchAnimation.open, value: appState.surface)"))
        XCTAssertTrue(panel.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)"))
        XCTAssertFalse(panel.contains("private var panelShellAnimation: Animation?"))
        XCTAssertFalse(panel.contains(".animation(panelShellAnimation, value: panelShellAnimationState)"))
        XCTAssertFalse(source.contains("private struct PanelShellAnimationState: Equatable"))
        XCTAssertTrue(source.contains("private var expandedContentTransition: AnyTransition"))
        XCTAssertEqual(expandedContent.occurrences(of: ".transition(expandedContentTransition)"), 9)
        // The shared .expandedContent transition (NotchAnimation.swift) keeps
        // blurFade + move(edge: .top), with a fast insertion curve so incoming
        // content is visible while the open spring is still growing the panel.
        XCTAssertTrue(source.contains(".expandedContent"))
        let animationSource = try sourceFile("Sources/Bough/NotchAnimation.swift")
        XCTAssertTrue(animationSource.contains("static var expandedContent: AnyTransition"))
        XCTAssertTrue(animationSource.contains(
            "insertion: AnyTransition.blurFade.animation(.easeOut(duration: 0.18))"))
        XCTAssertTrue(animationSource.contains("removal: .blurFade.combined(with: .move(edge: .top))"))
        XCTAssertFalse(expandedContent.contains(".move(edge: .top)"))
        XCTAssertFalse(expandedContent.contains(".scale(scale: 0.96, anchor: .top)"))
        XCTAssertFalse(source.contains("@State private var sessionSurfaceContentVisible = true"))
        XCTAssertFalse(source.contains("@State private var sessionSurfaceRevealTask: Task<Void, Never>?"))
        XCTAssertFalse(source.contains("@State private var sessionSurfaceCollapseTask: Task<Void, Never>?"))
        XCTAssertFalse(source.contains("private var sessionSurfaceContentShouldBeVisible"))
        XCTAssertFalse(source.contains("collapseSessionSurfaceAfterContentExit()"))
        XCTAssertFalse(source.contains("scheduleSessionSurfaceContentReveal()"))
        XCTAssertFalse(source.contains("private extension IslandSurface"))
        XCTAssertFalse(source.contains("var isSessionContentSurface: Bool"))
        XCTAssertFalse(source.contains("suppressSessionCardMascots"))
        XCTAssertFalse(source.contains("hideSessionMascots"))
        XCTAssertFalse(source.contains("hideMascot"))
    }

    func testExpandedSessionScrollHeightIsCappedByAvailablePanelHeight() {
        let cappedHeight = NotchPanelLayoutMetrics.sessionScrollMaxHeight(
            maxVisibleSessions: 20,
            availablePanelHeight: 640,
            notchHeight: 42,
            hasUsageStrip: true,
            hasAuxiliaryRow: true
        )

        XCTAssertEqual(cappedHeight, 409)
        XCTAssertLessThan(cappedHeight, CGFloat(20 * 90))
    }

    func testExpandedSessionScrollHeightKeepsConfiguredRowsWhenThereIsRoom() {
        let height = NotchPanelLayoutMetrics.sessionScrollMaxHeight(
            maxVisibleSessions: 5,
            availablePanelHeight: 900,
            notchHeight: 42,
            hasUsageStrip: true,
            hasAuxiliaryRow: true
        )

        XCTAssertEqual(height, 450)
    }

    func testCompactMusicSourceWiresMusicFigureAndPlayPauseOnly() throws {
        let source = try sourceFile("Sources/Bough/NotchPanelView.swift")
        let width = try XCTUnwrap(source.slice(from: "private var panelWidth: CGFloat", to: "var body: some View"))
        let leftWing = try XCTUnwrap(source.slice(from: "private struct CompactLeftWing: View", to: "/// Right side: project name"))
        let rightWing = try XCTUnwrap(source.slice(from: "private struct CompactRightWing: View", to: "// MARK: - Tool Status Helpers"))

        XCTAssertTrue(width.contains("compactActivitySource == .music || appState.status == .idle"))
        XCTAssertTrue(width.contains("displayedToolStatus && compactActivitySource != .music"))
        XCTAssertTrue(leftWing.contains("compactActivitySource == .music"))
        XCTAssertTrue(leftWing.contains("MusicFigureView(snapshot: appState.musicStore.snapshot"))
        XCTAssertTrue(source.contains("@Namespace private var musicArtworkNamespace"))
        XCTAssertTrue(leftWing.contains("musicArtworkNamespace: Namespace.ID"))
        XCTAssertTrue(leftWing.contains(".matchedGeometryEffect(id: MusicArtworkTransitionID.artwork, in: musicArtworkNamespace)"))
        XCTAssertTrue(leftWing.contains(".zIndex(MusicArtworkTransitionID.zIndex)"))
        XCTAssertTrue(rightWing.contains("compactActivitySource == .music"))
        XCTAssertTrue(rightWing.contains("musicArtworkNamespace: Namespace.ID"))
        XCTAssertTrue(rightWing.contains("CompactMusicPlayPauseControl("))
        XCTAssertTrue(rightWing.contains("musicArtworkNamespace: musicArtworkNamespace"))
        XCTAssertTrue(rightWing.contains("onHoverChanged: onMusicControlHoverChanged"))
        XCTAssertTrue(source.contains("@State private var compactMusicControlHovered"))
        XCTAssertTrue(source.contains("musicArtworkNamespace: musicArtworkNamespace"))
        XCTAssertTrue(source.contains("MusicStrip(appState: appState, musicArtworkNamespace: musicArtworkNamespace)"))
        XCTAssertTrue(source.contains(".zIndex(MusicArtworkTransitionID.zIndex)"))
        XCTAssertTrue(source.contains("private var expandedContentTransition: AnyTransition"))
        XCTAssertTrue(source.contains(".expandedContent"))
        XCTAssertFalse(source.contains("private var collapsedCompactActivitySource: MusicPanelActivitySource?"))
        XCTAssertFalse(source.contains("private var shouldPreserveMusicArtworkTransition: Bool"))
        XCTAssertFalse(source.contains("let sessionSurfaceTransition: AnyTransition = shouldPreserveMusicArtworkTransition"))
        XCTAssertFalse(source.contains("? .blurFade.combined(with: .move(edge: .top))"))
        XCTAssertFalse(source.contains("if !shouldPreserveMusicArtworkTransition"))
        XCTAssertFalse(source.contains("if shouldPreserveMusicArtworkTransition"))
        XCTAssertFalse(source.contains("musicPlayPauseMotionBlur"))
        XCTAssertFalse(source.contains("compactMusicFigureGhost"))
        XCTAssertFalse(source.contains("compactMusicFigureRevealMask"))
        XCTAssertFalse(source.contains("startCompactMusicFigureFadeOutIfNeeded()"))
        XCTAssertFalse(source.contains("startCompactMusicFigureRevealOnCollapseIfNeeded()"))
        XCTAssertTrue(source.contains("handleCompactMusicControlHover"))
        XCTAssertTrue(source.contains("guard isHovered, !compactMusicControlHovered else { return }"))
        XCTAssertTrue(source.contains("!expanded && showToolStatus && compactActivitySource != .music"))
        XCTAssertFalse(rightWing.contains("backward.fill"))
        XCTAssertFalse(rightWing.contains("forward.fill"))
    }

    func testExpandedMusicStripOrderingAndSettingsOffBoundary() throws {
        let source = try sourceFile("Sources/Bough/NotchPanelView.swift")
        let sessionList = try XCTUnwrap(source.slice(from: "private struct SessionListView: View", to: "/// Pure-SwiftUI scroll container"))
        let airDropMusicLayout = try XCTUnwrap(source.slice(from: "private struct AirDropMusicEntryLayout: View", to: "// MARK: - Approval Bar"))

        XCTAssertTrue(sessionList.contains("@AppStorage(SettingsKey.showMusicControls)"))
        XCTAssertTrue(sessionList.contains("MusicStripModel.shouldShowExpanded"))
        XCTAssertTrue(sessionList.contains("musicControlsEnabled: showMusicControls"))
        XCTAssertTrue(sessionList.contains("if showsMusicStrip"))
        XCTAssertTrue(sessionList.contains("MusicStrip(appState: appState, musicArtworkNamespace: musicArtworkNamespace)"))

        let usage = try XCTUnwrap(sessionList.range(of: "UsageStrip(appState: appState)"))
        let music = try XCTUnwrap(sessionList.range(of: "MusicStrip(appState: appState, musicArtworkNamespace: musicArtworkNamespace)"))
        let sessions = try XCTUnwrap(sessionList.range(of: "if usageStripLayout.sessionContentPlacement"))

        XCTAssertLessThan(usage.lowerBound, music.lowerBound)
        XCTAssertLessThan(music.lowerBound, sessions.lowerBound)

        let wideBranch = try XCTUnwrap(airDropMusicLayout.slice(from: "HStack(alignment: .top, spacing: 6) {", to: "\n            }\n        }\n    }\n}"))
        let wideMusic = try XCTUnwrap(wideBranch.range(of: "MusicStrip(appState: appState, musicArtworkNamespace: musicArtworkNamespace)"))
        let wideAirDrop = try XCTUnwrap(wideBranch.range(of: "AirDropEntryButton(layout: .square)"))
        XCTAssertLessThan(wideMusic.lowerBound, wideAirDrop.lowerBound)
        XCTAssertTrue(wideBranch.contains(".padding(.trailing, 6)"))
        XCTAssertFalse(wideBranch.contains(".padding(.leading, 6)"))
    }

    func testSessionListAlwaysScrollsFullListAndSessionScrollViewSelfSizes() throws {
        let source = try sourceFile("Sources/Bough/NotchPanelView.swift")
        let sessionList = try XCTUnwrap(source.slice(from: "private struct SessionListView: View", to: "/// Pure-SwiftUI scroll container"))
        let scroll = try XCTUnwrap(source.slice(from: "/// Pure-SwiftUI scroll container", to: "private struct SessionIdentityLine: View"))

        XCTAssertTrue(
            sessionList.contains("let needsScroll = onlySessionId == nil"),
            "Card heights vary with message content, so a session-count heuristic either clips the plain layout at the window edge or hides everything; the full list must always use the capped scroll container."
        )
        XCTAssertFalse(sessionList.contains("totalSessionCount > maxVisibleSessions"))
        XCTAssertTrue(sessionList.contains("SessionScrollView(maxHeight: scrollMaxHeight)"))

        XCTAssertTrue(
            scroll.contains(".frame(maxHeight: maxHeight)"),
            "Inside the panel's fixedSize layout the ScrollView adopts its content's ideal height; maxHeight alone caps it."
        )
        // Two mechanisms are banned here because each blanked the WHOLE panel
        // window for 1-2 frames when inserted mid-expand on macOS 26 (the
        // "island vanishes, then pops expanded" flicker): NSScrollView with a
        // nested NSHostingView, and a GeometryReader + preference height
        // feedback loop.
        XCTAssertFalse(scroll.contains("NSScrollView()"))
        XCTAssertFalse(scroll.contains("NSHostingView(rootView:"))
        XCTAssertFalse(scroll.contains(": NSViewRepresentable"))
        XCTAssertFalse(scroll.contains("GeometryReader"))
        XCTAssertFalse(scroll.contains("onPreferenceChange"))
        XCTAssertTrue(scroll.contains(".scrollIndicators(.never)"))
    }

    func testUsageStripLayoutKeepsStripOutsideScrollableSessionContent() {
        let scrollable = UsageStripLayout(showsStrip: true, needsScroll: true)
        let plain = UsageStripLayout(showsStrip: true, needsScroll: false)
        let hidden = UsageStripLayout(showsStrip: false, needsScroll: true)

        XCTAssertEqual(scrollable.stripPlacement, .outsideScrollableContent)
        XCTAssertEqual(scrollable.sessionContentPlacement, .scrollable)
        XCTAssertEqual(plain.stripPlacement, .outsideScrollableContent)
        XCTAssertEqual(plain.sessionContentPlacement, .plain)
        XCTAssertEqual(hidden.stripPlacement, .hidden)
        XCTAssertEqual(hidden.sessionContentPlacement, .scrollable)
    }

    func testUsageStripDoesNotUseNativeSegmentedPickerOnDarkSurface() throws {
        let source = try sourceFile("Sources/Bough/Notch/UsageStrip.swift")
        let usageStrip = try XCTUnwrap(source.slice(from: "struct UsageStrip: View", to: "private struct UsageStripSlot: View"))

        XCTAssertFalse(
            usageStrip.contains(".pickerStyle(.segmented)"),
            "The native segmented picker renders unreadable black unselected labels on Bough's dark notch surface. UsageStrip should use the custom dark selector instead."
        )
        XCTAssertTrue(
            usageStrip.contains(".onMoveCommand"),
            "The custom usage selector should preserve keyboard move handling expected from segmented controls."
        )
    }

    func testUsageStripSourceIsExtractedFromNotchPanelView() throws {
        let panelSource = try sourceFile("Sources/Bough/NotchPanelView.swift")
        let usageSource = try sourceFile("Sources/Bough/Notch/UsageStrip.swift")

        XCTAssertTrue(usageSource.contains("struct UsageStripModel: Equatable"))
        XCTAssertTrue(usageSource.contains("struct UsageStripLayout: Equatable"))
        XCTAssertTrue(usageSource.contains("struct UsageStrip: View"))
        XCTAssertTrue(usageSource.contains("private struct UsageStripSlot: View"))
        XCTAssertFalse(panelSource.contains("struct UsageStripModel: Equatable"))
        XCTAssertFalse(panelSource.contains("struct UsageStripLayout: Equatable"))
        XCTAssertFalse(panelSource.contains("struct UsageStrip: View"))
        XCTAssertFalse(panelSource.contains("private struct UsageStripSlot: View"))
    }

    func testJumpFeedbackSourceIsExtractedFromNotchPanelView() throws {
        let panelSource = try sourceFile("Sources/Bough/NotchPanelView.swift")
        let jumpSource = try sourceFile("Sources/Bough/Notch/JumpFeedback.swift")

        XCTAssertTrue(jumpSource.contains("func shouldTriggerJumpFailureFeedback"))
        XCTAssertTrue(jumpSource.contains("enum JumpAnimationHelper"))
        XCTAssertTrue(jumpSource.contains("enum JumpValidationOutcome"))
        XCTAssertTrue(jumpSource.contains("func evaluateJumpValidation"))
        XCTAssertFalse(panelSource.contains("func shouldTriggerJumpFailureFeedback"))
        XCTAssertFalse(panelSource.contains("enum JumpAnimationHelper"))
        XCTAssertFalse(panelSource.contains("enum JumpValidationOutcome"))
        XCTAssertFalse(panelSource.contains("func evaluateJumpValidation"))
    }

    func testExpandedLeftWingDoesNotUseLegacyCanvasLogo() throws {
        let source = try sourceFile("Sources/Bough/NotchPanelView.swift")

        XCTAssertFalse(
            source.contains("AppLogoView(size: 36, showBackground: false)"),
            "The expanded notch left wing should use the current Bough asset, not the pre-rebrand Canvas logo."
        )
    }

    func testCompactAIMascotCrossfadesAroundTrajectoryMidpoint() throws {
        let source = try sourceFile("Sources/Bough/NotchPanelView.swift")
        let panel = try XCTUnwrap(source.slice(from: "struct NotchPanelView: View", to: "// MARK: - Compact Wings"))
        let leftWing = try XCTUnwrap(source.slice(from: "private struct CompactLeftWing: View", to: "/// Right side: project name"))
        let musicBranch = try XCTUnwrap(leftWing.slice(from: "if !expanded && compactActivitySource == .music", to: "} else {"))
        let transitionStack = try XCTUnwrap(leftWing.slice(from: "private func mascotTransitionStack() -> some View", to: "\n    }\n\n}"))
        let handoff = try XCTUnwrap(leftWing.slice(from: "private enum AIMascotHandoff", to: "private struct AIMascotHandoffStack"))
        let handoffStack = try XCTUnwrap(source.slice(from: "private struct AIMascotHandoffStack: View", to: "/// Right side: project name"))

        XCTAssertTrue(source.contains("@Namespace private var mascotTransitionNamespace"))
        XCTAssertTrue(source.contains("mascotTransitionNamespace: mascotTransitionNamespace"))
        XCTAssertTrue(panel.contains("@State private var topMascotHandoffPhase = 0.0"))
        XCTAssertTrue(panel.contains("private var topMascotExpanded: Bool"))
        XCTAssertTrue(panel.contains("showIdleIndicator ? idleIndicatorExpanded : shouldShowExpanded"))
        XCTAssertTrue(panel.contains("mascotHandoffPhase: topMascotHandoffPhase"))
        XCTAssertTrue(panel.contains("topMascotHandoffPhase = topMascotExpanded ? 1 : 0"))
        XCTAssertTrue(panel.contains("withAnimation(AIMascotHandoff.animation(expanded: newValue))"))
        XCTAssertTrue(panel.contains("topMascotHandoffPhase = newValue ? 1 : 0"))
        XCTAssertTrue(leftWing.contains("let mascotHandoffPhase: Double"))
        XCTAssertTrue(leftWing.contains("private var aiMascotView: some View"))
        XCTAssertTrue(leftWing.contains("private func mascotTransitionStack() -> some View"))
        XCTAssertTrue(leftWing.contains("let mascotTransitionNamespace: Namespace.ID"))
        XCTAssertTrue(leftWing.contains("private enum AIMascotTransitionID"))
        XCTAssertTrue(leftWing.contains("private enum AIMascotHandoff"))
        XCTAssertTrue(leftWing.contains("private struct AIMascotHandoffStack: View"))
        XCTAssertTrue(leftWing.contains("mascotTransitionStack()"))
        XCTAssertTrue(transitionStack.contains("AIMascotHandoffStack("))
        XCTAssertTrue(transitionStack.contains("source: displaySource"))
        XCTAssertTrue(transitionStack.contains("status: displayStatus"))
        XCTAssertTrue(transitionStack.contains("compactSize: mascotSize"))
        XCTAssertTrue(transitionStack.contains("expandedSize: mascotExpandedSize"))
        XCTAssertTrue(transitionStack.contains("phase: mascotHandoffPhase"))
        XCTAssertTrue(leftWing.contains("let mascotExpandedSize: CGFloat"))
        XCTAssertFalse(transitionStack.contains("if displayStatus == .idle"))
        XCTAssertFalse(transitionStack.contains("switch displayStatus"))
        XCTAssertEqual(transitionStack.occurrences(of: "id: AIMascotTransitionID.mascot"), 1)
        XCTAssertEqual(transitionStack.occurrences(of: "in: mascotTransitionNamespace"), 1)
        XCTAssertEqual(transitionStack.occurrences(of: "properties: .position"), 1)
        XCTAssertFalse(transitionStack.contains("properties: .frame"))
        XCTAssertFalse(leftWing.contains("@State private var mascotHandoffPhase"))
        XCTAssertFalse(leftWing.contains("withAnimation(AIMascotHandoff.animation(expanded: newValue))"))
        XCTAssertTrue(handoff.contains("static let travelAnimation = NotchAnimation.open"))
        XCTAssertTrue(handoff.contains("static func animation(expanded _: Bool) -> Animation"))
        XCTAssertTrue(handoff.contains("travelAnimation"))
        XCTAssertFalse(handoff.contains("NotchAnimation.close"))
        XCTAssertFalse(handoff.contains("static let halfWidth"))
        XCTAssertTrue(handoff.contains("static func size(forPhase phase: Double, compactSize: CGFloat, expandedSize: CGFloat) -> CGFloat"))
        // Continuous container size + tight SEQUENTIAL fade windows around the
        // midpoint. The former step functions at exactly 0.5 swapped sprite
        // AND container size in a single mid-spring frame — a per-expand
        // flicker; a full-range overlapping crossfade double-exposes the
        // sprites (muddy — reverted once already).
        XCTAssertTrue(handoff.contains("compactSize + (expandedSize - compactSize) * CGFloat(progress)"))
        XCTAssertTrue(handoff.contains("static let travelingFadeWindow = (start: 0.38, end: 0.50)"))
        XCTAssertTrue(handoff.contains("static let brandFadeWindow = (start: 0.55, end: 0.72)"))
        XCTAssertTrue(handoff.contains("1 - fadeProgress(clampedPhase(phase), window: travelingFadeWindow)"))
        XCTAssertTrue(handoff.contains("fadeProgress(clampedPhase(phase), window: brandFadeWindow)"))
        XCTAssertFalse(handoff.contains("clampedPhase(phase) < 0.5 ? compactSize : expandedSize"))
        XCTAssertFalse(handoff.contains("clampedPhase(phase) < 0.5 ? 1 : 0"))
        XCTAssertFalse(handoff.contains("clampedPhase(phase) >= 0.5 ? 1 : 0"))
        XCTAssertFalse(handoff.contains("compactSize + (expandedSize - compactSize) * t"))
        XCTAssertFalse(handoff.contains("midpointHandoff(forPhase: phase)"))
        XCTAssertFalse(handoff.contains("let start = 0.5 - halfWidth"))
        XCTAssertFalse(handoff.contains("let end = 0.5 + halfWidth"))
        XCTAssertFalse(handoff.contains("return t * t * (3 - 2 * t)"))
        XCTAssertTrue(handoff.contains("private static func clampedPhase(_ phase: Double) -> Double"))
        XCTAssertTrue(handoffStack.contains("private struct AIMascotHandoffStack: View, Animatable"))
        XCTAssertTrue(handoffStack.contains("let compactSize: CGFloat"))
        XCTAssertTrue(handoffStack.contains("let expandedSize: CGFloat"))
        XCTAssertTrue(handoffStack.contains("var phase: Double"))
        XCTAssertTrue(handoffStack.contains("var animatableData: Double"))
        XCTAssertTrue(handoffStack.contains("AIMascotHandoff.size("))
        XCTAssertFalse(handoffStack.contains("let contentSize = expandedSize"))
        XCTAssertFalse(handoffStack.contains("let renderScale = size / contentSize"))
        XCTAssertTrue(handoffStack.contains("MascotView(source: source, status: status, size: compactSize)"))
        XCTAssertTrue(handoffStack.contains("BoughMascotView(fixedFrame: 0, frameSize: expandedSize)"))
        XCTAssertTrue(handoffStack.contains(".frame(width: size, height: size)"))
        XCTAssertFalse(handoffStack.contains(".scaleEffect(renderScale)"))
        XCTAssertTrue(handoffStack.contains(".opacity(AIMascotHandoff.travelingOpacity(forPhase: phase))"))
        XCTAssertTrue(handoffStack.contains(".opacity(AIMascotHandoff.brandOpacity(forPhase: phase))"))
        XCTAssertFalse(handoffStack.contains(".id(source)"))
        XCTAssertFalse(leftWing.contains("1 - blend * 2"))
        XCTAssertFalse(leftWing.contains("(blend - 0.5) * 2"))
        XCTAssertFalse(leftWing.contains("expanded ? 36 : mascotSize"))
        // Always-present full-range opacity crossfade was muddy; assert the regression
        // doesn't return. The intended handoff is a tight midpoint crossfade.
        XCTAssertFalse(leftWing.contains(".opacity(expanded ? 1 : 0)"))
        XCTAssertFalse(leftWing.contains(".opacity(expanded ? 0 : 1)"))
        XCTAssertFalse(leftWing.contains("width: expanded ? 36 : mascotSize"))
        XCTAssertFalse(leftWing.contains("height: expanded ? 36 : mascotSize"))
        XCTAssertFalse(leftWing.contains(".id(\"expanded-bough-mascot\")"))
        XCTAssertFalse(leftWing.contains("private static let mascotCrossFadeAnimation"))
        XCTAssertFalse(leftWing.contains("brandMascotSwapDelay"))
        XCTAssertFalse(leftWing.contains("brandSwapTask"))
        XCTAssertFalse(leftWing.contains("scheduleBrandMascotSwap"))
        XCTAssertFalse(leftWing.contains(".animation(Self.mascotCrossFadeAnimation, value: expanded)"))
        XCTAssertFalse(musicBranch.contains("aiMascotView"))
    }

    func testIdleIndicatorHandsOffToBrandMascotAndFiresHaptic() throws {
        let source = try sourceFile("Sources/Bough/NotchPanelView.swift")
        let panel = try XCTUnwrap(source.slice(from: "struct NotchPanelView: View", to: "// MARK: - Compact Bar"))
        let hoverHandling = try XCTUnwrap(source.slice(from: "private func handlePanelHover(_ hovering: Bool)", to: "switch appState.surface"))
        let idleBar = try XCTUnwrap(source.slice(from: "private var idleBar: some View", to: "private var productBar"))

        XCTAssertTrue(hoverHandling.contains("withAnimation(NotchAnimation.open)"))
        XCTAssertTrue(hoverHandling.contains("idleHovered = true"))
        XCTAssertTrue(hoverHandling.contains("withAnimation(NotchAnimation.close)"))
        XCTAssertTrue(hoverHandling.contains("idleHovered = false"))
        // Haptic must fire on the idle collapsed→expanded transition, matching the active bar.
        XCTAssertTrue(hoverHandling.contains("let wasCollapsed = appState.surface == .collapsed"))
        XCTAssertTrue(hoverHandling.contains("if wasCollapsed { performHoverHaptic() }"))
        XCTAssertTrue(source.contains("private func performHoverHaptic()"))

        // Idle maps to the idleIndicator bar mode and expands on hover via idleIndicatorExpanded.
        XCTAssertTrue(source.contains("if showIdleIndicator { return .idleIndicator }"))
        XCTAssertTrue(panel.contains("compactBarMode == .idleIndicator ? idleIndicatorExpanded : shouldShowExpanded"))
        XCTAssertTrue(panel.contains("private var topMascotExpanded: Bool"))
        XCTAssertTrue(panel.contains("private var idleIndicatorExpanded: Bool"))
        XCTAssertTrue(panel.contains("showIdleIndicator && (idleHovered || appState.surface.isExpanded)"))
        XCTAssertTrue(panel.contains("showIdleIndicator ? idleIndicatorExpanded : shouldShowExpanded"))

        // Idle bar hands the default-source mascot off to the Bough brand, with 0 + actions on expand.
        XCTAssertTrue(idleBar.contains("AIMascotHandoffStack("))
        XCTAssertTrue(idleBar.contains("source: settingsDefaultSource"))
        XCTAssertTrue(idleBar.contains("status: .idle"))
        XCTAssertTrue(idleBar.contains("compactSize: mascotSize"))
        XCTAssertTrue(idleBar.contains("expandedSize: min(36, notchHeight)"))
        XCTAssertTrue(idleBar.contains("phase: mascotHandoffPhase"))
        XCTAssertTrue(idleBar.contains("NotchActionButtons(includeSound: true, spacing: 4)"))
        XCTAssertTrue(idleBar.contains(".background(expanded ? Color.black : Color.clear)"))
        XCTAssertTrue(idleBar.contains(".transition(.opacity)"))
        // No static coding-agent mascot that never reaches the brand; the old struct is gone.
        XCTAssertFalse(idleBar.contains("MascotView("))
        XCTAssertFalse(source.contains("private struct IdleIndicatorBar"))
        XCTAssertFalse(source.contains("private struct ProductHomeCompactBar"))
    }

    func testIdleExpandedPanelShowsUsageAndAirDropContent() throws {
        let source = try sourceFile("Sources/Bough/NotchPanelView.swift")
        let panel = try XCTUnwrap(source.slice(from: "struct NotchPanelView: View", to: "// MARK: - Compact Bar"))
        let width = try XCTUnwrap(source.slice(from: "private var panelWidth: CGFloat", to: "var body: some View"))
        let hoverHandling = try XCTUnwrap(source.slice(from: "private func handlePanelHover(_ hovering: Bool)", to: "switch appState.surface"))
        let sessionList = try XCTUnwrap(source.slice(from: "private struct SessionListView: View", to: "/// Pure-SwiftUI scroll container"))

        XCTAssertTrue(panel.contains("(showBar || showProductHome || showIdleIndicator) && appState.surface.isExpanded"))
        XCTAssertTrue(width.contains("if showIdleIndicator {"))
        XCTAssertTrue(width.contains("if shouldShowExpanded { return min(max(nw + 200, 580), maxWidth) }"))
        XCTAssertTrue(panel.contains("compactBarMode == .idleIndicator ? idleIndicatorExpanded : shouldShowExpanded"))
        XCTAssertTrue(hoverHandling.contains("appState.surface = .sessionList"))
        XCTAssertTrue(hoverHandling.contains("appState.surface = .collapsed"))
        XCTAssertTrue(sessionList.contains("UsageStrip(appState: appState)"))
        XCTAssertTrue(sessionList.contains("AirDropEntryButton(layout: .row)"))
    }

    /// Locks the per-mode chrome/animation equivalence matrix the bar unification must preserve
    /// (spec `.planning/specs/2026-06-17-compact-bar-unification-design.md` §5).
    func testCompactBarPreservesPerModeChromeAndAnimations() throws {
        let source = try sourceFile("Sources/Bough/NotchPanelView.swift")
        let compactBar = try XCTUnwrap(source.slice(from: "private struct CompactBar: View", to: "// MARK: - Compact Wings"))
        let activeBar = try XCTUnwrap(source.slice(from: "private var activeBar: some View", to: "private var idleBar"))
        let idleBar = try XCTUnwrap(source.slice(from: "private var idleBar: some View", to: "private var productBar"))
        let productBar = try XCTUnwrap(source.slice(from: "private var productBar: some View", to: "// MARK: - Compact Wings"))
        let rightWing = try XCTUnwrap(source.slice(from: "private struct CompactRightWing: View", to: "// MARK: - Tool Status Helpers"))

        // Mode switches are view replacements (matching the old distinct-struct behavior), and the
        // shell mode renders only the bare notch-height spacer.
        XCTAssertTrue(source.contains("enum CompactBarMode"))
        XCTAssertTrue(compactBar.contains("content.id(mode)"))
        XCTAssertTrue(compactBar.contains("case .shell:"))
        XCTAssertTrue(compactBar.contains("Spacer().frame(height: notchHeight)"))

        // Background black on expand: active + idle yes; product-home + shell no.
        XCTAssertTrue(activeBar.contains(".background(expanded ? Color.black : Color.clear)"))
        XCTAssertTrue(idleBar.contains(".background(expanded ? Color.black : Color.clear)"))
        XCTAssertFalse(productBar.contains("Color.black"))

        // The micro animation belongs to product-home only.
        XCTAssertTrue(productBar.contains(".animation(NotchAnimation.micro, value: expanded)"))
        XCTAssertFalse(activeBar.contains("NotchAnimation.micro"))
        XCTAssertFalse(idleBar.contains("NotchAnimation.micro"))

        // The opacity transition belongs to the resting modes' right content; the active bar relies
        // on the container animation and must NOT gain one.
        XCTAssertTrue(idleBar.contains(".transition(.opacity)"))
        XCTAssertTrue(productBar.contains(".transition(.opacity)"))
        XCTAssertFalse(activeBar.contains(".transition(.opacity)"))

        // Leading mascot slot is clipped on idle, not on product-home (matches the originals).
        XCTAssertTrue(idleBar.contains(".clipped()"))
        XCTAssertFalse(productBar.contains(".clipped()"))

        // Shared action trio: sound on active (spacing 6) and idle (spacing 4), dropped on product-home.
        XCTAssertTrue(rightWing.contains("NotchActionButtons(includeSound: true, spacing: 6)"))
        XCTAssertTrue(idleBar.contains("NotchActionButtons(includeSound: true, spacing: 4)"))
        XCTAssertTrue(productBar.contains("NotchActionButtons(includeSound: false, spacing: 4)"))

        // Shared leaves exist and the active count label is parameterized by font, not duplicated.
        XCTAssertTrue(source.contains("private struct NotchActionButtons: View"))
        XCTAssertTrue(source.contains("private struct SessionCountLabel: View"))
        XCTAssertTrue(rightWing.contains("SessionCountLabel("))
    }

    func testSessionGroupingDefaultsToStatusAndNormalizesLegacyValues() {
        XCTAssertEqual(SettingsDefaults.sessionGroupingMode, "status")
        XCTAssertEqual(SessionGroupingMode.normalized(nil), "status")
        XCTAssertEqual(SessionGroupingMode.normalized(""), "status")
        XCTAssertEqual(SessionGroupingMode.normalized("all"), "status")
        XCTAssertEqual(SessionGroupingMode.normalized("status"), "status")
        XCTAssertEqual(SessionGroupingMode.normalized("unknown"), "status")
        XCTAssertEqual(SessionGroupingMode.normalized(" status "), "status")
        XCTAssertEqual(SessionGroupingMode.normalized("cli"), "cli")
        XCTAssertEqual(SessionGroupingMode.normalized(" CLI "), "cli")
    }

    func testSessionGroupingSettingsManagerNormalizesAccessors() throws {
        let source = try sourceFile("Sources/Bough/Settings.swift")
        let accessor = try XCTUnwrap(source.slice(from: "var sessionGroupingMode: String {", to: "var defaultSource: String {"))

        XCTAssertTrue(source.contains("static let sessionGroupingMode = \"status\""))
        XCTAssertTrue(source.contains("enum SessionGroupingMode"))
        XCTAssertTrue(source.contains("static func normalized(_ rawValue: String?) -> String"))
        XCTAssertTrue(accessor.contains("get { SessionGroupingMode.normalized(defaults.string(forKey: SettingsKey.sessionGroupingMode)) }"))
        XCTAssertTrue(accessor.contains("set { defaults.set(SessionGroupingMode.normalized(newValue), forKey: SettingsKey.sessionGroupingMode) }"))
    }

    func testSessionGroupingSelectorOnlyOffersStatusAndCli() throws {
        let source = try sourceFile("Sources/Bough/NotchPanelView.swift")
        let selector = try XCTUnwrap(source.slice(from: "private struct CompactLeftWing: View", to: "private struct CompactRightWing: View"))
        let statusRange = try XCTUnwrap(selector.range(of: "(\"status\", \"STA\")"))
        let cliRange = try XCTUnwrap(selector.range(of: "(\"cli\", \"CLI\")"))

        XCTAssertFalse(selector.contains("(\"all\", \"ALL\")"))
        XCTAssertLessThan(statusRange.lowerBound, cliRange.lowerBound)
        XCTAssertTrue(selector.contains("if appState.sessions.count > 1"))
        XCTAssertTrue(selector.contains("HStack(spacing: 1)"))
        XCTAssertTrue(selector.contains("SessionGroupingMode.normalized(groupingMode) == tag"))
        XCTAssertTrue(selector.contains("PixelText("))
        XCTAssertTrue(selector.contains("pixelSize: 1.3"))
        XCTAssertTrue(selector.contains(".padding(.horizontal, 5)"))
        XCTAssertTrue(selector.contains(".padding(.vertical, 4)"))
        XCTAssertTrue(selector.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(selector.contains(".pickerStyle(.segmented)"))
        XCTAssertFalse(selector.contains(".frame(maxWidth: .infinity"))
    }

    func testSessionGroupingListUsesNormalizedMode() throws {
        let source = try sourceFile("Sources/Bough/NotchPanelView.swift")
        let list = try XCTUnwrap(source.slice(from: "private struct SessionListView: View", to: "private struct SessionIdentityLine: View"))

        XCTAssertTrue(list.contains("switch SessionGroupingMode.normalized(groupingMode)"))
        XCTAssertFalse(list.contains("default: // \"all\""))
        XCTAssertFalse(list.contains("return [(\"\", nil, sorted)]"))
        XCTAssertTrue(list.contains("([.running], l10n[\"status_running\"])"))
        XCTAssertTrue(list.contains("(\"claude\", \"Claude\")"))
        XCTAssertTrue(list.contains("(\"codex\", \"Codex\")"))
        XCTAssertTrue(list.contains("(\"gemini\", \"Gemini\")"))
        XCTAssertTrue(list.contains("L10n.shared[\"other\"]"))
    }

    func testShouldTriggerJumpFailureFeedbackWhenAllAttemptsFail() {
        XCTAssertTrue(shouldTriggerJumpFailureFeedback([false, false, false]))
    }

    func testShouldNotTriggerJumpFailureFeedbackWhenAnyAttemptSucceeds() {
        XCTAssertFalse(shouldTriggerJumpFailureFeedback([false, true, false]))
    }

    func testJumpFailureShakeSequenceUsesFastAlternatingOffsets() {
        XCTAssertEqual(JumpAnimationHelper.shakeSequence, [8, -8, 6, -6, 3, -3, 0])
    }

    func testEvaluateJumpValidationReturnsSuccessWhenCheckSucceeds() async {
        var callCount = 0
        let outcome = await evaluateJumpValidation(
            delays: [1, 1, 1],
            isCancelled: { false },
            sleep: { _ in },
            checkSucceeded: {
                callCount += 1
                return callCount == 2
            }
        )

        XCTAssertEqual(outcome, .success)
    }

    func testEvaluateJumpValidationReturnsFailedWhenAllChecksFail() async {
        let outcome = await evaluateJumpValidation(
            delays: [1, 1, 1],
            isCancelled: { false },
            sleep: { _ in },
            checkSucceeded: { false }
        )

        XCTAssertEqual(outcome, .failed)
    }

    func testEvaluateJumpValidationReturnsCancelledBeforeCheckRuns() async {
        var checksRan = 0
        let outcome = await evaluateJumpValidation(
            delays: [1, 1, 1],
            isCancelled: { true },
            sleep: { _ in },
            checkSucceeded: {
                checksRan += 1
                return false
            }
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(checksRan, 0)
    }

    func testClickJumpCollapseTimelineShowsClickRingWhenCursorReachesClickPoint() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.26)

        XCTAssertGreaterThan(timeline.expand, 0.95)
        XCTAssertTrue(timeline.showClickRing)
        XCTAssertEqual(timeline.cursorX, 0, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 0, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineMovesCursorToClickPointFaster() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.08)

        XCTAssertEqual(timeline.cursorX, 0, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 0, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineMovesCursorFullyOffscreenBeforeExpandStarts() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.80)

        XCTAssertEqual(timeline.cursorX, 34, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 28, accuracy: 0.001)
        XCTAssertLessThanOrEqual(timeline.expand, 0.001)
    }

    func testClickJumpCollapseTimelineStartsExpandAfterCursorIsAlreadyOffscreen() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.85)

        XCTAssertGreaterThan(timeline.expand, 0.3)
        XCTAssertEqual(timeline.cursorX, 34, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 28, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineUsesMouseLeaveLikeCollapseSpeed() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.38)

        XCTAssertGreaterThan(timeline.expand, 0.5)
        XCTAssertLessThan(timeline.expand, 0.7)
    }

    func testClickJumpCollapseTimelineUsesMouseLeaveLikeExpandSpeed() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.93)

        XCTAssertGreaterThanOrEqual(timeline.expand, 0.999)
    }

    func testClickJumpCollapseTimelineHoldsCollapsedStateForMiddleWindow() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.60)

        XCTAssertLessThanOrEqual(timeline.expand, 0.001)
        XCTAssertEqual(timeline.cursorX, 0, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 0, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineLoopSeamIsSmooth() {
        let start = clickJumpCollapsePreviewTimeline(progress: 0)
        let end = clickJumpCollapsePreviewTimeline(progress: 1)

        XCTAssertEqual(start.expand, end.expand, accuracy: 0.001)
        XCTAssertEqual(start.cursorX, end.cursorX, accuracy: 0.001)
        XCTAssertEqual(start.cursorY, end.cursorY, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineLowersClickPoint() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.26)
        XCTAssertEqual(timeline.clickPointY, 16.0, accuracy: 0.1)
    }

    func testTypingIndicatorUsesLayerBackedShimmerWithoutChangingVisualParameters() throws {
        let source = try sourceFile("Sources/Bough/NotchPanelView.swift")
        let indicator = try XCTUnwrap(source.slice(from: "private struct TypingIndicator: View", to: "// MARK: - Mini Agent Icon"))

        XCTAssertTrue(indicator.contains("LayerBackedTypingShimmerView("))
        XCTAssertTrue(indicator.contains("CAGradientLayer()"))
        XCTAssertTrue(indicator.contains("CABasicAnimation(keyPath: \"position.x\")"))
        XCTAssertTrue(indicator.contains("animation.repeatCount = .infinity"))
        XCTAssertTrue(indicator.contains("animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)"))

        XCTAssertTrue(indicator.contains("let baseOpacity: Double = bright ? 0.6 : 0.35"))
        XCTAssertTrue(indicator.contains("let peakOpacity: Double = bright ? 0.8 : 0.5"))
        XCTAssertTrue(indicator.contains("let midOpacity: Double = bright ? 0.5 : 0.3"))
        XCTAssertTrue(indicator.contains("let bandWidth: CGFloat = bright ? 80 : 60"))
        XCTAssertTrue(indicator.contains("let duration: Double = 2.5"))
        XCTAssertTrue(indicator.contains("let endPhase: CGFloat = bright ? 100 : 80"))
        XCTAssertTrue(indicator.contains("let startPhase: CGFloat = bright ? -80 : -60"))
        XCTAssertTrue(indicator.contains("let leadingMidLocation: Double = bright ? 0.35 : 0.4"))
        XCTAssertTrue(indicator.contains("let trailingMidLocation: Double = bright ? 0.65 : 0.6"))

        XCTAssertFalse(indicator.contains("repeatForever"))
        XCTAssertFalse(indicator.contains("withAnimation("))
        XCTAssertFalse(indicator.contains("@State private var phase"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = Self.repoRoot
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static let repoRoot = TestHelpers.repoRoot(from: #filePath)
}

private extension String {
    func slice(from start: String, to end: String) -> String? {
        guard let lower = range(of: start)?.lowerBound,
              let upper = self[lower...].range(of: end)?.lowerBound else {
            return nil
        }
        return String(self[lower..<upper])
    }

    func occurrences(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = startIndex
        while let range = self[searchStart...].range(of: needle) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}
