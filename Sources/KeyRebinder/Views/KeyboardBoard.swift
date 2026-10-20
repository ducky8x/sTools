import STDesign
import SwiftUI

/// The keyboard and mouse drawn together in one coordinate space, so a hover arc can run from any key to any
/// other key or button (spec 5.5.2).
struct KeyboardBoard: View {
    let layout: KeyboardLayout
    let geometry: BoardGeometry
    let state: (KarabinerEvent) -> KeyCapState
    /// Where a key's output lives, for its hover arc; nil draws none.
    let arcTarget: (KarabinerEvent) -> KarabinerEvent?
    let describe: (KeyCap) -> String
    /// Nil draws a picture that can't be clicked (the first-use layout preview).
    let onSelect: ((KarabinerEvent) -> Void)?

    @State private var hovered: KarabinerEvent?
    @Environment(\.stTheme) private var theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            let body = geometry.mouseBody
            RoundedRectangle(cornerRadius: body.width * 0.45, style: .continuous)
                .stroke(theme.stroke.opacity(0.5), lineWidth: 1)
                .frame(width: body.width, height: body.height)
                .offset(x: body.minX, y: body.minY)
                .accessibilityHidden(true)
            ForEach(layout.keys) { key in
                cap(key, parts: geometry.rects(forKey: key))
            }
            ForEach(MouseLayout.buttons) { button in
                cap(button, parts: [geometry.rect(forButton: button)])
            }
            arc
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }

    @ViewBuilder private func cap(_ key: KeyCap, parts: [CGRect]) -> some View {
        let bounds = parts.dropFirst().reduce(parts[0]) { $0.union($1) }
        let face = KeyCapView(legend: key.legend, parts: parts, state: state(key.event), unit: geometry.unit)
        Group {
            if let onSelect {
                Button { onSelect(key.event) } label: { face }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside { hovered = key.event } else if hovered == key.event { hovered = nil }
                    }
                    .help(describe(key))
                    .accessibilityLabel(describe(key))
            } else {
                face.accessibilityHidden(true)
            }
        }
        .offset(x: bounds.minX, y: bounds.minY)
    }

    /// A hairline from the hovered key to where its output lives on the board.
    @ViewBuilder private var arc: some View {
        if let hovered, let target = arcTarget(hovered), let start = center(of: hovered), let end = center(of: target), start != end {
            let lift = max(abs(end.x - start.x), abs(end.y - start.y)) * 0.35 + geometry.unit * 0.4
            let control = CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - lift)
            ZStack {
                Path { path in
                    path.move(to: start)
                    path.addQuadCurve(to: end, control: control)
                }
                .stroke(theme.accent, lineWidth: 1)
                Circle().fill(theme.accent).frame(width: 5, height: 5).position(end)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func center(of event: KarabinerEvent) -> CGPoint? {
        let canonical = KeyTable.shared.canonical(event)
        if let key = layout.keys.first(where: { KeyTable.shared.canonical($0.event) == canonical }) {
            let rect = geometry.rects(forKey: key)[0]
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        if let button = MouseLayout.buttons.first(where: { $0.event == event }) {
            let rect = geometry.rect(forButton: button)
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        return nil
    }
}
