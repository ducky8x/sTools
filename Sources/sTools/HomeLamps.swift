import KeyRebinder
import STDesign
import STPlatform
import SwiftUI

/// How a status visual on Home looks (spec 3.5): lit in the accent when its companion is ready or linked, dim when it
/// isn't, and red only for a real problem.
enum HomeLampState: Equatable, Sendable {
    case lit, dim, problem
}

/// What one status visual on Home shows and says.
struct HomeLamp: Equatable, Sendable {
    var state: HomeLampState
    /// The whole sentence, for the help tag and VoiceOver.
    var sentence: String
    /// How many Minecraft windows are open, when it's more than one.
    var count: Int?

    init(state: HomeLampState, sentence: String, count: Int? = nil) {
        self.state = state
        self.sentence = sentence
        self.count = count
    }
}

/// The three companions Home shows as visuals, in the order of the tool rows beside them: Minecraft by the overlays,
/// Ninjabrain Bot by the NBB Overlay and Karabiner-Elements by the Key Rebinder.
enum HomeLampKind: CaseIterable, Sendable {
    case minecraft, ninjabrainBot, karabiner

    /// The small-caps name under the visual.
    var name: String {
        switch self {
        case .minecraft: "Minecraft"
        case .ninjabrainBot: "Ninjabrain Bot"
        case .karabiner: "Karabiner"
        }
    }

    /// What VoiceOver calls it.
    var spokenName: String {
        self == .karabiner ? "Karabiner-Elements" : name
    }

    /// The page where it's set up: the Key Rebinder for Karabiner-Elements, the NBB Overlay for Ninjabrain Bot. Minecraft
    /// has none.
    var destination: Route? {
        switch self {
        case .minecraft: nil
        case .ninjabrainBot: .tool(.nbbOverlay)
        case .karabiner: .tool(.keyRebinder)
        }
    }
}

/// The states and sentences of Home's status visuals, in the words the app already uses for each.
enum HomeLamps {
    /// Lit while the game runs, with a count when several windows are open; red while sTools can't look for it.
    static func minecraft(active: MinecraftInstance?, others: [MinecraftInstance], conflict: InstanceConflict,
                          displays: [DisplayInfo], accessibilityGranted: Bool) -> HomeLamp {
        let sentence = MinecraftStatusText.make(active: active, others: others, conflict: conflict, displays: displays,
                                                accessibilityGranted: accessibilityGranted)
        guard accessibilityGranted else { return HomeLamp(state: .problem, sentence: sentence) }
        guard active != nil else { return HomeLamp(state: .dim, sentence: sentence) }
        if case .multiple(let count, _) = conflict { return HomeLamp(state: .lit, sentence: sentence, count: count) }
        return HomeLamp(state: .lit, sentence: sentence)
    }

    /// Lit while Ninjabrain Bot is linked: the running NBB Overlay reads its API or its window, or, while the overlay is
    /// off, its API answered Home's last look (`answers`, nil before the first).
    static func ninjabrainBot(overlayIsOn: Bool, reachable: Bool, readsWindow: Bool, answers: Bool?) -> HomeLamp {
        if overlayIsOn {
            guard reachable else { return HomeLamp(state: .dim, sentence: PrologueCopy.ninjabrainSilent) }
            return HomeLamp(state: .lit, sentence: readsWindow
                ? "Ninjabrain Bot is linked through its window."
                : "Ninjabrain Bot is linked through its API.")
        }
        switch answers {
        case true?: return HomeLamp(state: .lit, sentence: PrologueCopy.ninjabrainAnswers)
        case false?: return HomeLamp(state: .dim, sentence: PrologueCopy.ninjabrainSilent)
        case nil: return HomeLamp(state: .dim, sentence: "Looking for Ninjabrain Bot\u{2026}")
        }
    }

    /// Lit when Karabiner-Elements is ready, dim while it isn't installed (it's needed only to edit rebinds), and red
    /// when it's installed but can't be used, with the Key Rebinder's sentence for the fix.
    static func karabiner(_ requirement: KarabinerRequirement?, profile: String?) -> HomeLamp {
        switch requirement {
        case nil:
            return HomeLamp(state: .dim, sentence: "Looking for Karabiner-Elements\u{2026}")
        case .ready?:
            return HomeLamp(state: .lit, sentence: profile.map { "Karabiner-Elements is ready, using the \($0) profile." }
                ?? "Karabiner-Elements is ready.")
        case .notInstalled?:
            return HomeLamp(state: .dim, sentence: KarabinerRequirement.notInstalled.fixText)
        case let problem?:
            return HomeLamp(state: .problem, sentence: problem.fixText)
        }
    }
}

// MARK: - Views

/// One status visual: the drawn pictogram in its state, and, in the column beside the tools, its name in small caps
/// under it. Karabiner-Elements and Ninjabrain Bot open the page where they're set up; the help tag and VoiceOver say the
/// whole sentence.
struct HomeLampView: View {
    let model: AppModel
    let kind: HomeLampKind
    /// In the column beside the tools, with its name; in the strip beside the title, without.
    let showsName: Bool

    @Environment(\.stTheme) private var theme

    /// The pictogram's size, at a text scale of 1, in the column and in the strip.
    static let columnSize: CGFloat = 40
    static let stripSize: CGFloat = 26

    var body: some View {
        let lamp = model.homeLamp(kind)
        if let destination = kind.destination {
            Button { model.navigate(to: destination) } label: { content(lamp) }
                .buttonStyle(HomeLampButtonStyle())
                .focusEffectDisabled()
                .help(lamp.sentence)
                .accessibilityLabel(kind.spokenName)
                .accessibilityValue(lamp.sentence)
                .accessibilityHint("Opens the \(destinationTitle(destination)) page")
        } else {
            content(lamp)
                .help(lamp.sentence)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(kind.spokenName)
                .accessibilityValue(lamp.sentence)
        }
    }

    private func destinationTitle(_ route: Route) -> String {
        if case .tool(let tool) = route { return tool.title }
        return ""
    }

    private func content(_ lamp: HomeLamp) -> some View {
        let size = (showsName ? Self.columnSize : Self.stripSize) * theme.textScale
        return VStack(spacing: 6 * theme.textScale) {
            HomePictogram(kind: kind, state: lamp.state)
                .frame(width: size, height: size)
                .overlay(alignment: .topTrailing) { badge(lamp, size: size) }
            if showsName {
                if kind == .minecraft, lamp.state == .lit, model.displays.displays.count > 1 {
                    HomeDisplayMap(displays: model.displays.displays, highlighted: model.minecraft.active?.displayID)
                        .frame(width: size * 1.1, height: size * 0.32)
                }
                Text(kind.name)
                    .stStyle(.label)
                    .foregroundStyle(lamp.state == .lit ? theme.inkSecondary : theme.inkTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .contentShape(Rectangle())
    }

    /// A count of Minecraft windows when several are open, or a mark for a problem, so the state isn't told by color alone.
    @ViewBuilder private func badge(_ lamp: HomeLamp, size: CGFloat) -> some View {
        let diameter = max(14, size * 0.42)
        if let count = lamp.count {
            Text("\(count)")
                .font(STFont.figures(diameter * 0.68, weight: .bold))
                .foregroundStyle(STColor.background)
                .frame(width: diameter, height: diameter)
                .background(theme.accent, in: Circle())
                .offset(x: diameter * 0.35, y: -diameter * 0.25)
        } else if lamp.state == .problem {
            Text("!")
                .font(STFont.text(diameter * 0.72, weight: .bold))
                .foregroundStyle(STColor.background)
                .frame(width: diameter, height: diameter)
                .background(STColor.danger, in: Circle())
                .offset(x: diameter * 0.35, y: -diameter * 0.25)
        }
    }
}

/// The three visuals in a row beside Home's title, without their names: where the window is too narrow for a column.
struct HomeLampStrip: View {
    let model: AppModel
    @Environment(\.stTheme) private var theme

    var body: some View {
        HStack(spacing: 16 * theme.textScale) {
            ForEach(HomeLampKind.allCases, id: \.self) { kind in
                HomeLampView(model: model, kind: kind, showsName: false)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A clickable visual: a little lift and the accent focus ring, with the house press dip.
private struct HomeLampButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HomeLampButtonBody(configuration: configuration)
    }
}

private struct HomeLampButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.stTheme) private var theme
    @Environment(\.isFocused) private var isFocused
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .offset(y: isHovering ? -1 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .stAnimation(STMotion.press, value: configuration.isPressed)
            .stAnimation(STMotion.quick, value: isHovering)
            .padding(4)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.accentStroke, lineWidth: 2)
                    .opacity(isFocused ? 1 : 0)
            }
            .onHover { isHovering = $0 }
    }
}

// MARK: - Pictograms

/// A companion drawn in hairlines, in its state's colors: Minecraft as a block, Ninjabrain Bot as an ender eye and
/// Karabiner-Elements as a key cap.
struct HomePictogram: View {
    let kind: HomeLampKind
    let state: HomeLampState
    @Environment(\.stTheme) private var theme

    private var ink: Color {
        switch state {
        case .lit: theme.accent
        case .dim: theme.inkTertiary.opacity(0.75)
        case .problem: STColor.danger
        }
    }

    /// How strongly a face is filled: none while dim.
    private func wash(_ strength: Double) -> Color {
        state == .dim ? .clear : ink.opacity(strength)
    }

    var body: some View {
        GeometryReader { proxy in
            let line = max(1, proxy.size.width / 24)
            switch kind {
            case .minecraft:
                ZStack {
                    BlockShape(face: .top).fill(wash(0.5))
                    BlockShape(face: .left).fill(wash(0.22))
                    BlockShape(face: .right).fill(wash(0.1))
                    BlockShape(face: .edges).stroke(ink, style: StrokeStyle(lineWidth: line, lineJoin: .round))
                }
            case .ninjabrainBot:
                ZStack {
                    EyeShape(part: .lids).fill(wash(0.1))
                    EyeShape(part: .lids).stroke(ink, style: StrokeStyle(lineWidth: line, lineJoin: .round))
                    EyeShape(part: .iris).fill(wash(0.35))
                    EyeShape(part: .iris).stroke(ink, lineWidth: line)
                    EyeShape(part: .pupil).fill(state == .dim ? ink.opacity(0.6) : ink)
                }
            case .karabiner:
                ZStack {
                    KeyCapShape(part: .base).fill(wash(0.12))
                    KeyCapShape(part: .top).fill(wash(0.36))
                    KeyCapShape(part: .base).stroke(ink, lineWidth: line)
                    KeyCapShape(part: .top).stroke(ink, lineWidth: line)
                    KeyCapShape(part: .bevels).stroke(ink, style: StrokeStyle(lineWidth: line * 0.8, lineCap: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// An isometric block, the shape everyone knows Minecraft by.
private struct BlockShape: Shape {
    enum Face { case top, left, right, edges }
    let face: Face

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height) * 0.94
        let half = side * 0.433
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let top = CGPoint(x: center.x, y: center.y - side / 2)
        let bottom = CGPoint(x: center.x, y: center.y + side / 2)
        let upperLeft = CGPoint(x: center.x - half, y: center.y - side / 4)
        let upperRight = CGPoint(x: center.x + half, y: center.y - side / 4)
        let lowerLeft = CGPoint(x: center.x - half, y: center.y + side / 4)
        let lowerRight = CGPoint(x: center.x + half, y: center.y + side / 4)
        var path = Path()
        switch face {
        case .top: path.addLines([top, upperRight, center, upperLeft, top])
        case .left: path.addLines([upperLeft, center, bottom, lowerLeft, upperLeft])
        case .right: path.addLines([center, upperRight, lowerRight, bottom, center])
        case .edges:
            path.addLines([top, upperRight, lowerRight, bottom, lowerLeft, upperLeft, top])
            path.move(to: upperLeft)
            path.addLine(to: center)
            path.addLine(to: upperRight)
            path.move(to: center)
            path.addLine(to: bottom)
        }
        return path
    }
}

/// An ender eye: almond lids, a round iris and a slit pupil.
private struct EyeShape: Shape {
    enum Part { case lids, iris, pupil }
    let part: Part

    func path(in rect: CGRect) -> Path {
        let width = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        switch part {
        case .lids:
            let left = CGPoint(x: center.x - width * 0.48, y: center.y)
            let right = CGPoint(x: center.x + width * 0.48, y: center.y)
            path.move(to: left)
            path.addQuadCurve(to: right, control: CGPoint(x: center.x, y: center.y - width * 0.56))
            path.addQuadCurve(to: left, control: CGPoint(x: center.x, y: center.y + width * 0.56))
            path.closeSubpath()
        case .iris:
            let radius = width * 0.2
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        case .pupil:
            path.addEllipse(in: CGRect(x: center.x - width * 0.035, y: center.y - width * 0.15, width: width * 0.07, height: width * 0.3))
        }
        return path
    }
}

/// A key cap seen from above and a little in front: its top raised over its base, and the bevels between them.
private struct KeyCapShape: Shape {
    enum Part { case base, top, bevels }
    let part: Part

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let base = CGRect(x: rect.midX - side * 0.46, y: rect.midY - side * 0.42, width: side * 0.92, height: side * 0.84)
        let top = CGRect(x: base.minX + side * 0.14, y: base.minY + side * 0.08, width: base.width - side * 0.28,
                         height: base.height - side * 0.3)
        let baseRadius = side * 0.16
        let topRadius = side * 0.1
        switch part {
        case .base:
            return Path(roundedRect: base, cornerRadius: baseRadius, style: .continuous)
        case .top:
            return Path(roundedRect: top, cornerRadius: topRadius, style: .continuous)
        case .bevels:
            // From each corner of the top to the same corner of the base, where a rounded corner is at 45°.
            func corners(of frame: CGRect, radius: CGFloat) -> [CGPoint] {
                let inset = radius * 0.293
                return [CGPoint(x: frame.minX + inset, y: frame.minY + inset), CGPoint(x: frame.maxX - inset, y: frame.minY + inset),
                        CGPoint(x: frame.maxX - inset, y: frame.maxY - inset), CGPoint(x: frame.minX + inset, y: frame.maxY - inset)]
            }
            var path = Path()
            for (from, to) in zip(corners(of: top, radius: topRadius), corners(of: base, radius: baseRadius)) {
                path.move(to: from)
                path.addLine(to: to)
            }
            return path
        }
    }
}

/// The displays as they're arranged, small, with the one Minecraft is on lit: which display it's on, at a glance.
struct HomeDisplayMap: View {
    let displays: [DisplayInfo]
    let highlighted: UInt32?
    @Environment(\.stTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            let union = displays.dropFirst().reduce(displays.first?.frame ?? .zero) { $0.union($1.frame) }
            let scale = min(proxy.size.width / max(union.width, 1), proxy.size.height / max(union.height, 1))
            let offsetX = (proxy.size.width - union.width * scale) / 2
            let offsetY = (proxy.size.height - union.height * scale) / 2
            ZStack(alignment: .topLeading) {
                ForEach(displays) { display in
                    // AppKit's frames grow upward; the drawing grows downward.
                    let frame = CGRect(x: offsetX + (display.frame.minX - union.minX) * scale,
                                       y: offsetY + (union.maxY - display.frame.maxY) * scale,
                                       width: display.frame.width * scale, height: display.frame.height * scale)
                        .insetBy(dx: 1, dy: 1)
                    let isLit = display.id == highlighted
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(isLit ? theme.accent.opacity(0.5) : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(isLit ? theme.accent : theme.inkTertiary, lineWidth: 1))
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
