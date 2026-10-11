import SwiftUI

enum Layout {
    enum Size: String, CaseIterable {
        case small, medium, large
        var scale: CGFloat { switch self { case .small: 0.8; case .medium: 1; case .large: 1.35 } }
    }
    static var size: Size {
        get { Size(rawValue: UserDefaults.standard.string(forKey: "lineSize") ?? "") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "lineSize") }
    }
    static var photoMaxHeight: CGFloat { (104 * size.scale).rounded() }
    static var baseHeight: CGFloat { photoMaxHeight + 106 }
    /// How much a photo grows while the pointer rests on it, and how far
    /// scrolling over it can take it.
    static let zoom: CGFloat = 2
    static let maxZoom: CGFloat = 3.5
    /// Zooming needs room below the cards. The extra strip is see through
    /// and lets clicks through, like the rest of the panel.
    static var panelHeight: CGFloat { Line.zoomOnHover ? max(baseHeight, photoMaxHeight * maxZoom + 106) : baseHeight }
    static let ropeTop: CGFloat = 10
    static var spacing: CGFloat { cardWidth + 24 }
    static var cardWidth: CGFloat { (150 * size.scale).rounded() }
    static let pinAbove: CGFloat = 9.5

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = min(1, max(0, x / width))
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

    /// How far the neighbours of a zoomed photo step aside to make room.
    static func push(for imageSize: CGSize, zoom: CGFloat) -> CGFloat {
        let zoomed = PeggedView.cardSize(for: imageSize, zoom: zoom).width
        return max(0, zoomed / 2 + cardWidth / 2 + 14 - spacing)
    }

    static func x(index: Int, count: Int, width: CGFloat, visible: Int = 8,
                  scroll: CGFloat = 0, keepsHistory: Bool = false) -> CGFloat {
        if keepsHistory && count > visible {
            let newest = width / 2 + CGFloat(visible - 1) * spacing / 2
            return newest - CGFloat(count - 1 - index) * spacing + scroll
        }
        let gaps = CGFloat(max(count - 1, 0))
        let step = gaps > 0 ? min(spacing, max(0, width - 200) / gaps) : spacing
        return width / 2 - gaps * step / 2 + CGFloat(index) * step
    }

    enum ScrollAction: Equatable { case history, zoom, ignore }
    static func scrollAction(x: CGFloat, y: CGFloat, overPhoto: Bool, zoomEnabled: Bool) -> ScrollAction {
        if abs(x) > abs(y) { return .history }
        return y != 0 && overPhoto && zoomEnabled ? .zoom : .ignore
    }
}

struct LineView: View {
    @ObservedObject var line: Line

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                Rope(width: width)

                if line.items.isEmpty {
                    Hint()
                        .position(x: width / 2, y: Layout.ropeY(x: width / 2, width: width) + 34)
                        .transition(.opacity)
                }

                ForEach(Array(line.items.enumerated()), id: \.element.id) { index, item in
                    let x = line.cardX(at: index, width: width)
                    let ropeY = Layout.ropeY(x: x, width: width)
                    PeggedView(item: item, line: line)
                        .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                        .opacity(min(1, max(0, min(x, width - x) / 90)))
                        .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                        .zIndex(line.zoomedID == item.id ? 1 : 0)
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.id))
            // The neighbours of a zoomed photo slide aside, like the Dock.
            .animation(.spring(response: 0.34, dampingFraction: 0.78), value: line.zoomedID)
            .animation(.spring(response: 0.34, dampingFraction: 0.78), value: line.zoomLevel)
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: line.revealed ? 0 : -(Layout.panelHeight + 12))
            .animation(line.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                     : .easeIn(duration: 0.22), value: line.revealed)
        }
        .onPreferenceChange(HitRectsKey.self) { rects in
            line.hitRects = rects
        }
    }
}

private struct Hint: View {
    var body: some View {
        Text(L("Take a screenshot and it will hang here"))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

/// A thin, neutral line: a mid gray core with a faint highlight and a soft
/// shadow, so it reads on light and dark backgrounds alike. It fades out at
/// both ends so it seems to come from beyond the screen.
struct Rope: View {
    let width: CGFloat

    private var path: Path {
        Path { p in
            let top = Layout.ropeTop
            p.move(to: CGPoint(x: -20, y: top))
            p.addQuadCurve(
                to: CGPoint(x: width + 20, y: top),
                control: CGPoint(x: width / 2, y: top + 2 * Layout.sag(width: width)))
        }
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
