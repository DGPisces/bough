import SwiftUI
import BoughCore

// MARK: - Mascot Animation Speed Environment

private struct MascotSpeedKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var mascotSpeed: Double {
        get { self[MascotSpeedKey.self] }
        set { self[MascotSpeedKey.self] = newValue }
    }
}

/// Routes a CLI source identifier to the correct pixel mascot view.
struct MascotView: View {
    let source: String
    let status: AgentStatus
    var size: CGFloat = 27
    @AppStorage(SettingsKey.mascotSpeed) private var speedPct = SettingsDefaults.mascotSpeed

    var body: some View {
        let speed = Double(speedPct) / 100.0

        Group {
            if let spec = MascotSpriteCatalog.spec(source: source, status: status)
                ?? MascotSpriteCatalog.fallbackSpec(status: status) {
                SpriteMascotView(spec: spec, size: size, mascotSpeed: speed)
            }
        }
            .frame(width: size, height: size, alignment: .center)
            .environment(\.mascotSpeed, speed)
    }
}
