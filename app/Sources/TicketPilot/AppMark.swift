import SwiftUI
import TicketPilotCore

/// The menu bar icon: rendered to a template image, since a menu bar label shows a single image.
struct MenuBarLabel: View {
    let icon: MenuBarIcon

    var body: some View {
        Image(nsImage: render())
            .help("TicketPilot")
            .accessibilityLabel("TicketPilot")
            .accessibilityValue(icon.accessibilityValue)
    }

    private func render() -> NSImage {
        let renderer = ImageRenderer(content: MenuBarGlyph(icon: icon))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}

private struct MenuBarGlyph: View {
    let icon: MenuBarIcon

    var body: some View {
        HStack(spacing: 2) {
            ChevronsMark(color: .black, height: 16)
            if let badge = icon.badge {
                Text(badge)
                    .font(.system(size: 13, weight: .medium))
            }
            if icon.showsProblem {
                Text("!")
                    .font(.system(size: 11, weight: .bold))
            }
        }
        .foregroundStyle(.black)
        .padding(.vertical, 2)
    }
}

/// The app's mark, the three stacked chevrons of `AppIcon.svg`, faded like there.
struct ChevronsMark: View {
    /// The chevrons' bounds in the SVG, round caps included.
    private nonisolated static let bounds = CGRect(x: 290, y: 218, width: 444, height: 574)

    let color: Color
    let height: CGFloat

    var body: some View {
        Canvas { context, size in
            let scale = size.height / Self.bounds.height
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: (x - Self.bounds.minX) * scale, y: (y - Self.bounds.minY) * scale)
            }
            let style = StrokeStyle(lineWidth: 64 * scale, lineCap: .round, lineJoin: .round)
            for (index, opacity) in [0.35, 0.65, 1].enumerated() {
                let top = 250 + CGFloat(index) * 160
                var path = Path()
                path.move(to: point(322, top + 190))
                path.addLine(to: point(512, top))
                path.addLine(to: point(702, top + 190))
                context.stroke(path, with: .color(color.opacity(opacity)), style: style)
            }
        }
        .frame(width: height * Self.bounds.width / Self.bounds.height, height: height)
        .accessibilityHidden(true)
    }
}
