import STDesign
import SwiftUI

/// The page's plate: scope picker and Test keys above, the keyboard and mouse, then the tester's line (spec 5.5.2, 5.5.5).
struct KeyboardPlate: View {
    @Bindable var controller: KeyRebinderController
    let layout: KeyboardLayout
    /// Whether the plate shows sTools hotkeys: rings on their keys, their findings' red dots, their names in the
    /// keys' descriptions and the tester's line, and the hotkeys no key here sends. False in the Prologue's trial.
    var showsHotkeys = true

    @Environment(\.stTheme) private var theme
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        STPlate {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    ScopeMenu(controller: controller)
                    Spacer()
                    Text("Test keys").stStyle(.label).foregroundStyle(theme.inkSecondary)
                    STSwitch(isOn: $controller.isTesting, label: "Test keys")
                }
                board
                footer
            }
            .padding(16)
        }
    }

    /// Room around the board for the badges on the top row's and the right edge's keys, which straddle a key's
    /// top-right corner (up to a tenth of a key above it, at the largest key size).
    private static let badgeRoom = EdgeInsets(top: 7, leading: 0, bottom: 0, trailing: 4)

    private var geometry: BoardGeometry {
        BoardGeometry(layout: layout, width: max(availableWidth - Self.badgeRoom.trailing, 1))
    }

    /// Keys stay big enough to read and click; when even that doesn't fit, the board scrolls sideways.
    private var board: some View {
        let geometry = geometry
        let drawing = KeyboardBoard(
            layout: layout,
            geometry: geometry,
            state: state(for:),
            arcTarget: { controller.settings.showsHoverArcs ? arcTarget(for: $0) : nil },
            describe: describe(_:),
            onSelect: { key in controller.selectedKey = controller.selectedKey == key ? nil : key })
        let scrolling = isScrolling(geometry)
        // A scroll view takes the width it's offered whatever its content's size, so measuring it gives the
        // room actually available.
        return ScrollView(.horizontal) {
            drawing.padding(Self.badgeRoom).padding(.bottom, scrolling ? 12 : 0)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollIndicators(scrolling ? .visible : .hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: geometry.size.height + Self.badgeRoom.top + (scrolling ? 12 : 0))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard and mouse")
    }

    private func isScrolling(_ geometry: BoardGeometry) -> Bool {
        availableWidth > 0 && geometry.size.width + Self.badgeRoom.trailing > availableWidth + 0.5
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.isTesting {
                Text(controller.lastTrace?.summary(showsHotkeys: showsHotkeys) ?? "Press any key or mouse button.")
                    .stStyle(.body)
                    .foregroundStyle(STColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
                Text("Shortcuts macOS takes first (\u{2318}-Tab, Spotlight, Mission Control) can\u{2019}t be shown here.")
                    .stStyle(.caption)
                    .foregroundStyle(theme.inkTertiary)
            }
            if isScrolling(geometry) {
                Text("Scroll sideways to see the rest, or make the window wider to see the whole keyboard.")
                    .stStyle(.caption)
                    .foregroundStyle(theme.inkSecondary)
            }
            if !higherButtons.isEmpty {
                Text("Mouse buttons above 8: " + higherButtons.joined(separator: ", "))
                    .stStyle(.caption)
                    .foregroundStyle(theme.inkSecondary)
            }
            if showsHotkeys, let unplaced = controller.unplacedHotkeysText {
                Text(unplaced)
                    .stStyle(.caption)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Self.legend(checkerEnabled: controller.settings.checkerEnabled,
                             drawsHotkeyMarks: showsHotkeys && !controller.derived.hotkeysByKey.isEmpty))
                .stStyle(.caption)
                .foregroundStyle(theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The line explaining the marks, in the badge's order: ◆, the hotkey ring (only while a key wears one), the
    /// red dot (only while the checker is on).
    static func legend(checkerEnabled: Bool, drawsHotkeyMarks: Bool) -> String {
        "Gold is what a key sends now. \u{25C6} a rule drives the key; select it to see the rule."
            + (drawsHotkeyMarks ? " A gold ring is an sTools hotkey; a slashed red ring is one that isn\u{2019}t working." : "")
            + (checkerEnabled ? " A red dot is a checker finding." : "")
    }

    // MARK: Per-key state

    private func state(for event: KarabinerEvent) -> KeyCapState {
        Self.capState(for: event, controller: controller, layout: layout, showsHotkeys: showsHotkeys)
    }

    /// What `event`'s cap shows. Its hotkey ring, and the red dot of a hotkey finding, only when `showsHotkeys`.
    static func capState(
        for event: KarabinerEvent, controller: KeyRebinderController, layout: KeyboardLayout, showsHotkeys: Bool
    ) -> KeyCapState {
        var state = KeyCapState()
        if let binding = controller.binding(for: event) {
            if binding.isDrawable, let output = binding.output {
                state.output = KeyLegend.short(for: output, layout: layout)
            } else {
                state.isRuleDriven = true
            }
        }
        if let output = EffectiveMapping.output(of: event, in: controller.derived.bindings) {
            state.action = controller.minecraftActions(for: output).first
        }
        let aliases = KeyTable.shared.aliases(of: event)
        state.isFlagged = !controller.derived.flaggedKeys.isDisjoint(with: aliases)
            || (showsHotkeys && !controller.derived.hotkeyFlaggedKeys.isDisjoint(with: aliases))
        state.hotkey = showsHotkeys ? controller.hotkeyMark(for: event) : nil
        state.isSelected = controller.selectedKey == event
        let canonical = KeyTable.shared.canonical(event)
        state.isLit = controller.litKeys.contains { KeyTable.shared.canonical($0) == canonical }
        state.isSource = !controller.litKeys.isEmpty && controller.lastTrace?.sources.contains(event) == true
        return state
    }

    private func arcTarget(for event: KarabinerEvent) -> KarabinerEvent? {
        guard let binding = controller.binding(for: event), binding.isDrawable, let output = binding.output, output != event else { return nil }
        return output
    }

    private func describe(_ key: KeyCap) -> String {
        Self.description(of: key.event, controller: controller, showsHotkeys: showsHotkeys)
    }

    /// What the tooltip and VoiceOver say about a key: "Caps Lock. Sends F18. sTools hotkey F18: Crosshair." Its
    /// hotkeys, and their findings, only when `showsHotkeys`.
    static func description(of event: KarabinerEvent, controller: KeyRebinderController, showsHotkeys: Bool) -> String {
        var parts = [KeyNames.name(for: event)]
        if let binding = controller.binding(for: event) {
            if binding.isDrawable, let output = binding.output {
                parts.append("Sends \(KeyNames.name(for: output))")
            } else if case .complex(_, let description) = binding.source {
                parts.append("Driven by the rule \u{201C}\(description)\u{201D}")
            } else {
                parts.append("Sends several keys")
            }
        } else {
            parts.append("Not rebound")
        }
        if let output = EffectiveMapping.output(of: event, in: controller.derived.bindings) {
            let actions = controller.minecraftActions(for: output)
            if !actions.isEmpty { parts.append("In Minecraft: \(actions.joined(separator: ", "))") }
        }
        if showsHotkeys, let hotkeys = controller.hotkeyDescription(for: event) {
            parts.append(hotkeys.hasSuffix(".") ? String(hotkeys.dropLast()) : hotkeys)
        }
        if !controller.findings(for: event).isEmpty || (showsHotkeys && !controller.hotkeyFindings(for: event).isEmpty) {
            parts.append("The checker found a problem")
        }
        return parts.joined(separator: ". ") + "."
    }

    private var higherButtons: [String] {
        controller.derived.rebinds.compactMap { rebind in
            guard let number = MouseLayout.buttonNumber(of: rebind.from), number > MouseLayout.drawnButtonCount else { return nil }
            return "Button \(number) \u{2192} \(KeyNames.name(for: rebind.to))"
        }
    }
}

/// All devices, or one connected keyboard or mouse (spec 5.5.2).
struct ScopeMenu: View {
    let controller: KeyRebinderController
    @Environment(\.stTheme) private var theme

    var body: some View {
        Menu {
            Button("All devices") { controller.setScope(nil) }
            if !controller.devices.isEmpty { Divider() }
            ForEach(controller.devices) { device in
                Button(device.displayName) { controller.setScope(device.identifiers) }
            }
        } label: {
            STMenuLabel("Scope: \(scopeName)")
        }
        .stMenuStyle()
        .accessibilityLabel("Scope: \(scopeName)")
    }

    private var scopeName: String {
        guard let device = controller.settings.scopeDevice else { return "All devices" }
        return controller.devices.first { $0.identifiers == device }?.displayName ?? "A device that isn\u{2019}t connected"
    }
}
