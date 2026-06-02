import AppKit

extension UserDefaults {
    @objc dynamic var hideWhenNoSession: Bool {
        bool(forKey: SettingsKey.hideWhenNoSession)
    }
}

enum StatusItemVisibilityPolicy {
    static func shouldShowStatusItem(
        hideWhenNoSession: Bool,
        codingSessionsEnabled _: Bool = CodingSessionsSettings.isEnabled()
    ) -> Bool {
        hideWhenNoSession
    }
}

enum StatusItemMenuModel {
    static func codingSessionsTitleKey(isEnabled: Bool = CodingSessionsSettings.isEnabled()) -> String {
        isEnabled ? "turn_off_coding_sessions" : "turn_on_coding_sessions"
    }

    static func toggledCodingSessionsValue(isEnabled: Bool) -> Bool {
        !isEnabled
    }

    @discardableResult
    static func toggleCodingSessions(defaults: UserDefaults = .standard) -> Bool {
        let nextValue = toggledCodingSessionsValue(
            isEnabled: CodingSessionsSettings.isEnabled(defaults: defaults)
        )
        CodingSessionsSettings.setEnabled(nextValue, defaults: defaults)
        return nextValue
    }
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private var observation: NSKeyValueObservation?
    private var codingSessionsItem: NSMenuItem?
    private lazy var menu: NSMenu = makeMenu()

    func startObserving() {
        syncVisibility()
        observation = UserDefaults.standard.observe(
            \.hideWhenNoSession, options: [.new]
        ) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor [self] in self.syncVisibility() }
        }
    }

    private func syncVisibility() {
        if StatusItemVisibilityPolicy.shouldShowStatusItem(
            hideWhenNoSession: SettingsManager.shared.hideWhenNoSession
        ) {
            showStatusItem()
        } else {
            hideStatusItem()
        }
    }

    private func showStatusItem() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                let icon = SettingsWindowController.bundleAppIcon()
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
                button.imageScaling = .scaleProportionallyDown
                button.toolTip = "Bough"
            }
            updateCodingSessionsMenuItem()
            item.menu = menu
            statusItem = item
        }
    }

    private func hideStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let codingSessionsItem = NSMenuItem(
            title: L10n.shared[StatusItemMenuModel.codingSessionsTitleKey()],
            action: #selector(toggleCodingSessionsMode),
            keyEquivalent: ""
        )
        codingSessionsItem.target = self
        self.codingSessionsItem = codingSessionsItem
        menu.addItem(codingSessionsItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: L10n.shared["settings_ellipsis"],
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.shared["quit"],
            action: #selector(quitApp),
            keyEquivalent: ""
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateCodingSessionsMenuItem()
    }

    private func updateCodingSessionsMenuItem() {
        codingSessionsItem?.title = L10n.shared[StatusItemMenuModel.codingSessionsTitleKey()]
    }

    @objc private func toggleCodingSessionsMode() {
        StatusItemMenuModel.toggleCodingSessions()
        updateCodingSessionsMenuItem()
    }

    @objc private func openSettings() {
        Task { @MainActor in
            SettingsWindowController.shared.show()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
