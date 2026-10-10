import SwiftUI

enum Layout {
    static let panelHeight: CGFloat = 210
    static let ropeTop: CGFloat = 10
    static let spacing: CGFloat = 174
    static let cardWidth: CGFloat = 150
    static let pinAbove: CGFloat = 9.5
    /// Room kept clear at each end for the line's tabs.
    static let tabsReserve: CGFloat = 210

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = x / width
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

    /// The stretch of rope cards may use, between the tabs at either end.
    static func usable(width: CGFloat) -> CGFloat { width - 2 * tabsReserve }

    /// How far a line too long for the screen can slide.
    static func maxScroll(count: Int, width: CGFloat) -> CGFloat {
        let span = CGFloat(max(count - 1, 0)) * spacing + cardWidth
        return max(0, span - usable(width: width))
    }

    /// Where a card hangs. A line that fits is centred; a longer one starts
    /// after the tabs and slides by `scroll`.
    static func x(index: Int, count: Int, width: CGFloat, scroll: CGFloat = 0) -> CGFloat {
        let total = CGFloat(max(count - 1, 0)) * spacing
        guard maxScroll(count: count, width: width) > 0 else {
            return width / 2 - total / 2 + CGFloat(index) * spacing
        }
        return tabsReserve + cardWidth / 2 + CGFloat(index) * spacing - scroll
    }

    /// A card slid past either end of the usable stretch is put away.
    static func isOffLine(x: CGFloat, width: CGFloat) -> Bool {
        x < tabsReserve + cardWidth / 2 - 2 || x > width - tabsReserve - cardWidth / 2 + 2
    }
}

struct LineView: View {
    @ObservedObject var line: Line
    @ObservedObject var bag = Bag.shared

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                Rope(width: width, tint: line.shelf.tint)
                    .animation(.easeInOut(duration: 0.25), value: line.shelf)

                ShelfTabs(line: line, bag: bag)
                    .position(x: 12 + 95, y: Layout.ropeTop + 30)

                if line.visible.isEmpty {
                    Hint(shelf: line.shelf)
                        .position(x: width / 2, y: Layout.ropeY(x: width / 2, width: width) + 34)
                        .transition(.opacity)
                }

                ForEach(Array(line.visible.enumerated()), id: \.element.id) { index, item in
                    let x = Layout.x(index: index, count: line.visible.count, width: width, scroll: line.scroll)
                    let off = Layout.isOffLine(x: x, width: width)
                    let ropeY = Layout.ropeY(x: x, width: width)
                    PeggedView(item: item, line: line, hidden: off)
                        .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                        .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.visible.map(\.id))
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.86), value: line.scroll)
            .animation(.easeInOut(duration: 0.3), value: line.visible.isEmpty)
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

/// The lines you can switch between, as small tags at the left end of the
/// rope: the recent one, then your own groups. Click one, or press Tab after
/// bringing the line down with ⌃⌥T. Drop a card on a tag to keep its text there.
private struct ShelfTabs: View {
    @ObservedObject var line: Line
    @ObservedObject var bag: Bag

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                tab(.recent, title: L("Recent"), count: line.liveCount)
                ForEach(bag.groups, id: \.self) { g in
                    tab(.group(g), title: g, count: bag.pins(in: g).count)
                }
                Button {
                    if let name = askForText(L("New group")) {
                        bag.addGroup(name)
                        line.shelf = .group(name)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .glassFrame(circle: true)
                }
                .buttonStyle(.plain)
            }
            if line.keyboardMode {
                Text(L("⇥ switch line · ⌘1–9 copy · hold ⌥ show keys · esc"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .glassFrame(capsule: true)
                    .transition(.opacity)
            }
        }
        .frame(width: 190, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { g in
                Color.clear.preference(key: HitRectsKey.self, value: [Line.tabsID: g.frame(in: .global)])
            }
        )
    }

    private func tab(_ shelf: Line.Shelf, title: String, count: Int) -> some View {
        let selected = line.shelf == shelf
        return Button {
            line.shelf = shelf
        } label: {
            HStack(spacing: 3) {
                if case .group(Bag.secretGroup) = shelf {
                    Image(systemName: "lock.fill").font(.system(size: 8))
                }
                Text(title).lineLimit(1)
                if count > 0 { Text("\(count)").opacity(selected ? 0.85 : 0.6) }
            }
            .font(.system(size: 11, weight: selected ? .bold : .medium))
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.55))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .modifier(TabChrome(selected: selected, tint: shelf.tint ?? Color(white: 0.4)))
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { texts, _ in
            guard case .group(let g) = shelf else { return false }
            for t in texts {
                let from = line.items.first { Clips.text(of: $0.url) == t }.flatMap { Clips.source(of: $0.url) }
                // Ask once the drop has finished, not in the middle of it.
                DispatchQueue.main.async { bag.pin(t, to: g, source: from) }
            }
            return !texts.isEmpty
        }
        .contextMenu {
            if case .group(let g) = shelf, !Bag.defaultGroups.contains(g), bag.pins(in: g).isEmpty {
                Button(L("Delete group")) { bag.removeGroup(g) }
            }
        }
    }
}

/// The selected tag is solid, in its line's colour; the others stay faint glass.
private struct TabChrome: ViewModifier {
    let selected: Bool
    let tint: Color
    func body(content: Content) -> some View {
        if selected {
            content
                .background(tint, in: Capsule())
                .shadow(color: tint.opacity(0.45), radius: 4, y: 1)
        } else {
            content.glassFrame(capsule: true).opacity(0.85)
        }
    }
}

extension Line.Shelf {
    /// Recent keeps the plain rope; keys are orange, other groups the accent.
    var tint: Color? {
        switch self {
        case .recent: return nil
        case .group(Bag.secretGroup): return .orange
        case .group: return .accentColor
        }
    }
}

private struct Hint: View {
    let shelf: Line.Shelf
    var body: some View {
        Text(shelf == .recent ? L("Take a screenshot and it will hang here")
                              : L("Empty line: right-click a card on Recent › Hang on"))
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
    /// Your own lines are coloured, so it is clear which one is up.
    var tint: Color? = nil

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
            path.stroke(tint ?? Color(white: 0.55), lineWidth: tint == nil ? 1.2 : 2)
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
