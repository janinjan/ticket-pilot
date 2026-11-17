import CoreGraphics

/// The panel window's frame for its content: `MenuBarExtra` grows its window to fit taller content but
/// never shrinks it, and centres shorter content in it (a gap under the menu bar and a blank band at the
/// bottom). The panel is resized to its content's height, its top edge kept where AppKit put it.
public enum PanelFrame {
    /// The list's height before it scrolls: most of the screen's visible height, the header, the status
    /// and the footer kept in sight; never under 400 points (or the screen unknown).
    public static func maxListHeight(visibleScreenHeight: CGFloat?) -> CGFloat {
        guard let visibleScreenHeight else { return 400 }
        return max(400, (visibleScreenHeight * 0.85 - 180).rounded())
    }

    /// The list's content reaches below the bottom of its scroll view (past a few points of rounding).
    public static func hasMoreBelow(contentBottom: CGFloat, viewportHeight: CGFloat) -> Bool {
        contentBottom > viewportHeight + 4
    }

    /// `frame` with `contentHeight` as its height and the same top edge (AppKit's y axis points up), or
    /// nil when it already fits.
    public static func fitted(_ frame: CGRect, contentHeight: CGFloat) -> CGRect? {
        let height = contentHeight.rounded()
        guard height > 0, abs(frame.height - height) >= 0.5 else { return nil }
        return CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }
}
