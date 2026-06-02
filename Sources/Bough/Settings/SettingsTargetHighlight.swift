import SwiftUI

extension View {
    func settingsControlHighlight(isHighlighted: Bool) -> some View {
        modifier(SettingsControlHighlightModifier(isHighlighted: isHighlighted))
    }
}

private struct SettingsControlHighlightModifier: ViewModifier {
    let isHighlighted: Bool
    @State private var pulseLow = false

    func body(content: Content) -> some View {
        content
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(pulseLow ? 0.06 : 0.18))
                        .padding(.horizontal, -8)
                        .padding(.vertical, -3)
                        .transition(.opacity)
                }
            }
            .onAppear {
                if isHighlighted {
                    startPulse()
                }
            }
            .onChange(of: isHighlighted) { _, highlighted in
                if highlighted {
                    startPulse()
                } else {
                    pulseLow = false
                }
            }
    }

    private func startPulse() {
        pulseLow = false
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.32).repeatCount(4, autoreverses: true)) {
                pulseLow = true
            }
        }
    }
}
