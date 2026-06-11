import SwiftUI
import BoughCore

struct UsageStripModel: Equatable {
    /// Re-exposed via type alias so existing call sites (e.g. AlarmState,
    /// UsageStatusDotClassifier, tests) that referenced
    /// `UsageStripModel.TodaySeverity` keep working without churn. The canonical
    /// declaration lives in BoughCore (Phase 5 / D-06 — 5 cases).
    typealias TodaySeverity = BoughCore.TodaySeverity

    struct Slot: Equatable {
        let title: String
        let value: String
        var severity: TodaySeverity = .unknown
    }

    let statusLabel: String
    let availability: UsageAvailability
    let todaySeverity: TodaySeverity
    let slots: [Slot]

    init(snapshot: UsageSnapshot, now: Date = Date()) {
        statusLabel = Self.statusText(for: snapshot.availability)
        availability = snapshot.availability
        let severity = Self.severity(from: snapshot.today)
        todaySeverity = severity
        // UI-03: restore single-row 5h / Week / Today layout (pre-regression per commit 1751130).
        // Today folds back into slots[2] with severity tint. expandedTodayText second row is removed.
        slots = [
            Slot(title: L10n.shared["usage_5h"], value: Self.windowText(for: snapshot.fiveHour, now: now, format: .compact)),
            Slot(title: L10n.shared["usage_week"], value: Self.windowText(for: snapshot.weekly, now: now, format: .fullDHM)),
            Slot(title: L10n.shared["today_safe"], value: Self.todaySlotText(for: snapshot.today), severity: severity),
        ]
    }

    /// Passthrough — TodayValue.severity is already computed in BoughCore
    /// (D-05). This helper handles the nil case the same way the legacy
    /// `TodaySeverity.from(forecast:)` did.
    static func severity(from today: TodayValue?) -> TodaySeverity {
        today?.severity ?? .unknown
    }

    static func shouldShow(surface: IslandSurface, onlySessionId: String?) -> Bool {
        guard onlySessionId == nil else { return false }
        switch surface {
        case .completionCard, .sessionList:
            return true
        case .airDrop, .approvalCard, .collapsed, .questionCard:
            return false
        }
    }

    private static func statusText(for availability: UsageAvailability) -> String {
        switch availability {
        case .loading:
            return L10n.shared["loading"]
        case .available:
            return L10n.shared["available"]
        case .partial:
            return L10n.shared["partial"]
        case .stale(let reason):
            return staleLabel(for: reason)
        case .unavailable:
            return L10n.shared["unavailable"]
        }
    }

    private static func windowText(for slot: UsageWindowSlot, now: Date, format: DurationFormat) -> String {
        switch slot {
        case .loading:
            return L10n.shared["loading"]
        case .available(let snapshot):
            return windowText(snapshot, now: now, format: format)
        case .stale(let snapshot, let reason):
            return "\(windowText(snapshot, now: now, format: format)) · \(staleLabel(for: reason))"
        case .unavailable:
            return L10n.shared["unavailable"]
        }
    }

    private static func staleLabel(for reason: String) -> String {
        reason == L10n.shared["usage_refresh_failed"] ? reason : L10n.shared["stale"]
    }

    private static func windowText(_ snapshot: UsageWindowSnapshot, now: Date, format: DurationFormat) -> String {
        let percent = Int(floor(100 - snapshot.usedPercent))
        let reset = DurationFormat.format(until: snapshot.resetsAt, now: now, format)
        return "\(percent)% · \(reset)"
    }

    /// UI-03: compact Today slot value — `"<pct>% · <allowance>%/wk"`.
    /// Signed-integer formatting preserves the leading `-` for overdraft.
    /// Returns the L10n unavailable string when today is nil.
    private static func todaySlotText(for today: TodayValue?) -> String {
        guard let today else { return L10n.shared["unavailable"] }
        guard today.pct.isFinite, today.todayAllowanceOfWeek.isFinite else {
            return L10n.shared["unavailable"]
        }
        let signedIntPct = Int(today.pct.rounded())  // Int preserves sign; rounds half-to-even
        let allowance = String(format: "%.1f", today.todayAllowanceOfWeek)
        let base = "\(signedIntPct)% · \(allowance)%/wk"
        guard let resetExplanation = todayResetExplanation(for: today.basis.resetProvenance) else {
            return base
        }
        return "\(base) · \(resetExplanation)"
    }

    private static func todayResetExplanation(for provenance: UsageResetProvenance) -> String? {
        switch provenance {
        case .explicitReset:
            return L10n.shared["today_reset_explicit_compact"]
        case .implicitReset:
            return L10n.shared["today_reset_implicit_compact"]
        case .ordinaryProgress, .correctionIgnored:
            return nil
        }
    }

}

struct UsageStripLayout: Equatable {
    enum StripPlacement: Equatable {
        case hidden
        case outsideScrollableContent
    }

    enum SessionContentPlacement: Equatable {
        case plain
        case scrollable
    }

    let stripPlacement: StripPlacement
    let sessionContentPlacement: SessionContentPlacement

    init(showsStrip: Bool, needsScroll: Bool) {
        stripPlacement = showsStrip ? .outsideScrollableContent : .hidden
        sessionContentPlacement = needsScroll ? .scrollable : .plain
    }
}

struct UsageStrip: View {
    @ObservedObject private var l10n = L10n.shared
    var appState: AppState

    var body: some View {
        @Bindable var usageStore = appState.usageStore
        if let selectedTool = usageStore.selectedDisplayTool {
            let snapshot = usageStore.snapshot(for: selectedTool)
            let model = UsageStripModel(snapshot: snapshot)

            let borderColor = UsageStrip.borderColor(for: model.todaySeverity)
            // .depleted and .overdraft share the same 1.5pt thick border per
            // 05-UI-SPEC Spacing inherited table (both are the "alarm" tier).
            let wantsThickBorder = model.todaySeverity == .depleted || model.todaySeverity == .overdraft
            let borderWidth: CGFloat = wantsThickBorder ? 1.5 : 1

            HStack(spacing: 8) {
                UsageProviderSelector(
                    tools: usageStore.selectableTools,
                    selection: $usageStore.selectedTool
                )

                ForEach(model.slots, id: \.title) { slot in
                    UsageStripSlot(slot: slot)
                }

                UsageStatusDot(
                    availability: model.availability,
                    severity: model.todaySeverity,
                    isRefreshing: usageStore.isRefreshing
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .onAppear {
                appState.refreshUsageForPanelOpen()
            }
        }
    }

    /// Color for the TODAY-15 expanded-panel Today row. Mirrors
    /// `UsageStripSlot.valueColor` token table: .depleted and .overdraft share
    /// the depleted red tint; .caution uses amber; .healthy / .unknown render
    /// at full white opacity.
    static func todayRowColor(for severity: UsageStripModel.TodaySeverity) -> Color {
        switch severity {
        case .depleted, .overdraft: return Color(red: 1.0, green: 0.42, blue: 0.42)
        case .caution: return Color(red: 0.95, green: 0.70, blue: 0.32)
        case .healthy, .unknown: return .white.opacity(0.82)
        }
    }

    static func borderColor(for severity: UsageStripModel.TodaySeverity) -> Color {
        switch severity {
        // Per 05-UI-SPEC Color section: .overdraft reuses the depleted red border
        // to signal "alarm tier" without adding a new color token. The pulsing
        // dot (D-07) discriminates overdraft from depleted at the dot level.
        case .depleted, .overdraft: return Color.red.opacity(0.55)
        case .caution: return Color(red: 0.91, green: 0.612, blue: 0.227).opacity(0.45)
        case .healthy, .unknown: return .white.opacity(0.08)
        }
    }
}

private struct UsageStatusDot: View {
    let availability: UsageAvailability
    let severity: UsageStripModel.TodaySeverity
    let isRefreshing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var alarmState = AlarmState()

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: timelinePaused)) { context in
            let now = context.date

            // Step the alarm reducer and persist next state. The reducer
            // is pure; only first observation + transitions allocate new
            // alarmStartedAt values, so most renders return the same
            // AlarmState (Equatable check inside SwiftUI prevents churn).
            let result = AlarmReducer.step(
                previous: alarmState,
                currentSeverity: severity,
                now: now
            )

            // Classify the dot.
            let classification = UsageStatusDotClassifier.classify(
                severity: severity,
                availability: availability,
                isRefreshing: isRefreshing,
                alarmActive: result.alarmActive,
                reduceMotion: reduceMotion
            )

            let opacity = animationOpacity(
                animation: classification.animation,
                state: classification.state,
                alarmStartedAt: result.next.alarmStartedAt,
                now: now
            )

            dotView(
                color: dotColor(for: classification.state),
                opacity: opacity,
                accessibilityLabel: UsageStatusDotClassifier.accessibilityLabel(
                    for: classification.state,
                    availability: availability,
                    severity: severity
                )
            )
            // Persist the new alarm state outside the render closure.
            // `initial: true` is CRITICAL: the first render's reducer
            // call produces a seed (AlarmState with lastSeverity = current,
            // alarmStartedAt = nil). Without `initial: true`, onChange
            // wouldn't fire on first render, so alarmState would stay at
            // its initial AlarmState() with nil lastSeverity. The next
            // severity transition (e.g., direct healthy → depleted between
            // two 5-minute Codex refreshes) would re-seed instead of
            // firing the alarm — silently swallowing the headline
            // attention signal. Eagerly persisting the seed on first
            // render ensures every subsequent transition is real.
            //
            // Do NOT try to "optimize" this by writing alarmState directly
            // inside the body closure (forbidden by SwiftUI render-loop
            // rules — would crash on @State write during view update).
            .onChange(of: result.next, initial: true) { _, newValue in
                if alarmState != newValue {
                    alarmState = newValue
                }
            }
        }
    }

    private var timelinePaused: Bool {
        if reduceMotion { return true }
        if isRefreshing { return false }
        if case .stale = availability { return false }
        if case .loading = availability { return false }
        if severity == .overdraft { return false }
        if alarmState.alarmStartedAt != nil { return false }
        return true
    }

    // MARK: - Rendering helpers

    private func dotView(color: Color, opacity: Double, accessibilityLabel: String) -> some View {
        Circle()
            .fill(color)
            .opacity(opacity)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    .opacity(opacity)
            )
            .frame(width: 24, height: 28)
            .help(tooltip(for: accessibilityLabel))
            // Merge the fill + stroke circles into one VoiceOver element
            // so the dot reads as a single "Status: ..." announcement
            // instead of potentially navigating into the inner overlay.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }

    private func dotColor(for state: DotState) -> Color {
        switch state {
        case .greenSteady, .greenBlink:
            return Color(red: 0.32, green: 0.78, blue: 0.42)
        case .yellowSteady, .yellowBlink:
            return Color(red: 0.91, green: 0.612, blue: 0.227)
        case .redSteady, .redBlink:
            return .red
        case .graySteady, .grayBlink:
            return .white.opacity(0.35)
        }
    }

    /// Compute opacity given the animation kind.
    /// - .steady → 1.0
    /// - .breathe → sinusoidal 0.4 ↔ 1.0 with 1.5s cycle
    /// - .pulse → square wave 0.0 ↔ 1.0 for 3 cycles of 0.3s on/off
    ///   from alarmStartedAt; full opacity after 1.8s.
    private func animationOpacity(
        animation: DotAnimation,
        state: DotState,
        alarmStartedAt: Date?,
        now: Date
    ) -> Double {
        switch animation {
        case .steady:
            return 1.0
        case .breathe:
            // 1.5s sinusoid mapped to opacity 0.4 ↔ 1.0
            let phase = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5
            let sine = sin(phase * 2 * .pi)
            return 0.7 + 0.3 * sine  // ranges 0.4 ↔ 1.0
        case .pulse:
            guard let started = alarmStartedAt else { return 1.0 }
            let elapsed = now.timeIntervalSince(started)
            if elapsed >= 1.8 { return 1.0 }
            // 3 cycles of 0.3s on / 0.3s off = 1.8s total. Each 0.6s
            // cycle: 0..0.3 → on (1.0), 0.3..0.6 → off (0.0).
            let cyclePhase = elapsed.truncatingRemainder(dividingBy: 0.6)
            return cyclePhase < 0.3 ? 1.0 : 0.0
        }
    }

    /// Tooltip carries the accessibility label as the on-hover text.
    /// Two surfaces, one source of truth.
    private func tooltip(for accessibilityLabel: String) -> String {
        accessibilityLabel
    }
}

private struct UsageProviderSelector: View {
    @ObservedObject private var l10n = L10n.shared
    let tools: [UsageTool]
    @Binding var selection: UsageTool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tools, id: \.self) { tool in
                let selected = selection == tool
                Text(label(for: tool))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? .white.opacity(0.92) : .white.opacity(0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selected ? .white.opacity(0.12) : .clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selection = tool }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label(for: tool))
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .frame(width: tools.count > 1 ? 150 : 72, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.black.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        // Keyboard arrow-key navigation between tools is preserved via
        // .onMoveCommand, but no visible focus indicator is rendered. The
        // previous Button-based implementation surfaced macOS Tahoe's
        // focus container ring on the inner selected button (see PR #52
        // bug report); .focusEffectDisabled() suppresses that ring on
        // this HStack. A custom focus indicator could be added here, but
        // it would re-introduce the same visual that was reported as a
        // bug. Power users who tab to this control discover arrow nav
        // works; sighted users without keyboard interaction are unaffected.
        .focusable(tools.count > 1)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left, .up:
                moveSelection(by: -1)
            case .right, .down:
                moveSelection(by: 1)
            default:
                break
            }
        }
    }

    private func label(for tool: UsageTool) -> String {
        switch tool {
        case .codex:
            return l10n["usage_provider_codex"]
        case .claudeCode:
            return l10n["usage_provider_claude_code"]
        }
    }

    private func moveSelection(by offset: Int) {
        guard tools.count > 1,
              let index = tools.firstIndex(of: selection) else {
            return
        }

        let nextIndex = (index + offset + tools.count) % tools.count
        selection = tools[nextIndex]
    }
}

private struct UsageStripSlot: View {
    let slot: UsageStripModel.Slot

    // Per 05-UI-SPEC Color section: .overdraft and .depleted share the same
    // red color tokens (alarm tier). The fallthrough makes the visual
    // equivalence explicit so a future split is a deliberate edit.
    private var valueColor: Color {
        switch slot.severity {
        case .depleted, .overdraft: return Color(red: 1.0, green: 0.42, blue: 0.42)
        case .caution: return Color(red: 0.95, green: 0.70, blue: 0.32)
        case .healthy, .unknown: return .white.opacity(0.82)
        }
    }

    private var titleColor: Color {
        switch slot.severity {
        case .depleted, .overdraft: return Color(red: 1.0, green: 0.42, blue: 0.42).opacity(0.75)
        case .caution: return Color(red: 0.95, green: 0.70, blue: 0.32).opacity(0.7)
        case .healthy, .unknown: return .white.opacity(0.38)
        }
    }

    private var backgroundFill: Color {
        switch slot.severity {
        case .depleted, .overdraft: return Color.red.opacity(0.16)
        case .caution: return Color.clear
        case .healthy, .unknown: return Color.clear
        }
    }

    private var backgroundStroke: Color {
        switch slot.severity {
        case .depleted, .overdraft: return Color.red.opacity(0.55)
        case .caution: return Color.clear
        case .healthy, .unknown: return Color.clear
        }
    }

    /// Floor that prevents the slot from collapsing past readability when the
    /// strip is squeezed; the maxWidth=infinity allows it to grow and split
    /// remaining width evenly across the three slots.
    static let slotMinWidth: CGFloat = 88

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(slot.title.uppercased())
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(titleColor)
            Text(slot.value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(valueColor)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .padding(.horizontal, 6)
        .frame(minWidth: Self.slotMinWidth, maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(backgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(backgroundStroke, lineWidth: 1)
        )
    }
}
