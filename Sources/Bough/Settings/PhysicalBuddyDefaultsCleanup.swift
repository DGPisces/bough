import Foundation

enum PhysicalBuddyDefaultsCleanup {
    private static let sentinelKey = "physicalBuddyDefaultsCleanup"

    private static let legacyKeys = [
        "esp32BridgeEnabled",
        "esp32HeartbeatSeconds",
        "buddyScreenBrightnessPercent",
        "buddyScreenOrientation",
        "selectedBuddyIdentifier",
        "selectedBuddyName",
    ]

    static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: sentinelKey) else {
            return
        }

        for key in legacyKeys {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: sentinelKey)
    }
}
