import CoreGraphics

/// The panel window's frame for its content: `MenuBarExtra` grows its window to fit taller content but
/// never shrinks it, and centres shorter content in it (a gap under the menu bar and a blank band at the
/// bottom). The panel is resized to its content's height, its top edge kept where AppKit put it.
public enum PanelFrame {
    /// `frame` with `contentHeight` as its height and the same top edge (AppKit's y axis points up), or
    /// nil when it already fits.
    public static func fitted(_ frame: CGRect, contentHeight: CGFloat) -> CGRect? {
        let height = contentHeight.rounded()
        guard height > 0, abs(frame.height - height) >= 0.5 else { return nil }
        return CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }
}
