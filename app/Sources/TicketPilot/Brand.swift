import AppKit
import SwiftUI

/// The app icon's orange (`AppIcon.svg`), on the system's neutral backgrounds. No alarm colours.
enum Brand {
    static let orange = Color(red: 0xF2 / 255, green: 0xA9 / 255, blue: 0x3B / 255)
    /// Orange text on an orange-tinted background, at least 4.5:1 in light and dark.
    static let orangeText = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark
            ? NSColor(red: 0xF5 / 255, green: 0xBE / 255, blue: 0x68 / 255, alpha: 1)
            : NSColor(red: 0x7A / 255, green: 0x4A / 255, blue: 0x00 / 255, alpha: 1)
    })
    static let tint = orange.opacity(0.18)
}

/// The panel's buttons: the primary one a compact orange-tinted pill on the neutral background, the
/// secondary one a smaller, outlined pill that lights up under the pointer.
struct BrandButtonStyle: ButtonStyle {
    enum Kind {
        case primary, secondary
    }

    var kind: Kind = .primary

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        switch kind {
        case .primary:
            configuration.label
                .font(.callout.weight(.semibold))
                .foregroundStyle(Brand.orangeText)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Brand.tint, in: Capsule())
                .overlay(Capsule().strokeBorder(Brand.orange.opacity(0.35), lineWidth: 1))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
                .contentShape(Capsule())
        case .secondary:
            SecondaryButtonBody(configuration: configuration, isEnabled: isEnabled)
        }
    }
}

extension ButtonStyle where Self == BrandButtonStyle {
    static var brand: BrandButtonStyle { BrandButtonStyle() }
    static var brandSecondary: BrandButtonStyle { BrandButtonStyle(kind: .secondary) }
}

/// The secondary button: outlined so it reads as a button, highlighted with the pointing hand on hover.
private struct SecondaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isEnabled: Bool

    @State private var hovering = false
    /// The pointing hand is pushed once and always popped, even if the panel closes under the pointer.
    @State private var pushedCursor = false

    var body: some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(hovering && isEnabled ? 0.1 : 0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .contentShape(Capsule())
            .onHover { inside in
                hovering = inside
                setPointingHand(inside && isEnabled)
            }
            .onDisappear { setPointingHand(false) }
    }

    private func setPointingHand(_ on: Bool) {
        guard on != pushedCursor else { return }
        if on { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        pushedCursor = on
    }
}
