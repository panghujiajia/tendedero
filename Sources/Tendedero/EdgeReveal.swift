import Foundation

enum EdgeReveal {
    /// At a shared upper edge the pointer cannot stop, so use the menu bar
    /// only on the horizontal portion covered by the display above it.
    static func zone(screen: CGRect, menuBar: CGRect, displays: [CGRect], x: CGFloat) -> CGRect {
        let above = displays.contains { other in
            other != screen && abs(other.minY - screen.maxY) < 1 && other.minX <= x && x < other.maxX
        }
        if above { return menuBar }
        return CGRect(x: screen.minX, y: screen.maxY - 2, width: screen.width, height: 2)
    }
}
