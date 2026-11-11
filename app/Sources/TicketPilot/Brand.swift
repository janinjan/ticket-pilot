import SwiftUI

/// The app icon's palette (`AppIcon.svg`): a navy tile and orange chevrons. No alarm colours.
enum Brand {
    static let navyTop = Color(red: 0x1D / 255, green: 0x2B / 255, blue: 0x4F / 255)
    static let navyBottom = Color(red: 0x0E / 255, green: 0x17 / 255, blue: 0x30 / 255)
    static let orange = Color(red: 0xF2 / 255, green: 0xA9 / 255, blue: 0x3B / 255)
    static let navy = LinearGradient(colors: [navyTop, navyBottom], startPoint: .top, endPoint: .bottom)
}

/// The app icon in small: the navy tile with its three chevrons. `emphasized` adds a soft orange ring,
/// when a run needs the user or the setup must be fixed.
struct BrandMark: View {
    let size: CGFloat
    var emphasized = false

    var body: some View {
        // The tile's corner radius in the icon: 200 for a 896 tile.
        let tile = RoundedRectangle(cornerRadius: size * 200 / 896, style: .continuous)
        tile.fill(Brand.navy)
            .overlay(ChevronsMark(color: Brand.orange, height: size * 0.56))
            .frame(width: size, height: size)
            .padding(emphasized ? 4 : 0)
            .overlay {
                if emphasized {
                    RoundedRectangle(cornerRadius: (size + 8) * 200 / 896, style: .continuous)
                        .strokeBorder(Brand.orange.opacity(0.7), lineWidth: 2)
                }
            }
            .shadow(color: emphasized ? Brand.orange.opacity(0.35) : .black.opacity(0.15), radius: emphasized ? 8 : 2, y: 1)
            .accessibilityHidden(true)
    }
}

/// The panel's buttons: the primary one is a compact navy pill with white text (the brand tile), the
/// secondary one plain, smaller text.
struct BrandButtonStyle: ButtonStyle {
    enum Kind {
        case primary, secondary
    }

    var kind: Kind = .primary
    var large = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        switch kind {
        case .primary:
            configuration.label
                .font((large ? Font.body : Font.callout).weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, large ? 16 : 10)
                .padding(.vertical, large ? 6 : 3)
                .background(Brand.navy, in: Capsule())
                .overlay(Capsule().strokeBorder(Brand.orange.opacity(0.45), lineWidth: 1))
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .contentShape(Capsule())
        case .secondary:
            configuration.label
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
                .contentShape(Rectangle())
        }
    }
}

extension ButtonStyle where Self == BrandButtonStyle {
    static var brand: BrandButtonStyle { BrandButtonStyle() }
    static var brandSecondary: BrandButtonStyle { BrandButtonStyle(kind: .secondary) }
}
