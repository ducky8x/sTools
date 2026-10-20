import STDesign
import SwiftUI

/// The page's plate: scope picker and Test keys above, the keyboard and mouse, then the tester's line (spec 5.5.2, 5.5.5).
struct KeyboardPlate: View {
    @Bindable var controller: KeyRebinderController
    let layout: KeyboardLayout

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

    /// Keys stay big enough to read and click; when even that doesn't fit, the board scrolls sideways.
    private var board: some View {
        let geometry = BoardGeometry(layout: layout, width: max(availableWidth, 1))
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
            drawing.padding(.bottom, scrolling ? 12 : 0)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollIndicators(scrolling ? .visible : .hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: geometry.size.height + (scrolling ? 12 : 0))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard and mouse")
    }

    private func isScrolling(_ geometry: BoardGeometry) -> Bool {
        availableWidth > 0 && geometry.size.width > availableWidth + 0.5
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.isTesting {
                Text(controller.lastTrace?.summary() ?? "Press any key or mouse button.")
                    .stStyle(.body)
                    .foregroundStyle(STColor.ink)
                    .accessibilityAddTraits(.updatesFrequently)
                Text("Shortcuts macOS takes first (\u{2318}-Tab, Spotlight, Mission Control) can\u{2019}t be shown here.")
                    .stStyle(.caption)
                    .foregroundStyle(theme.inkTertiary)
            }
            if isScrolling(BoardGeometry(layout: layout, width: max(availableWidth, 1))) {
                Text("Scroll sideways to see the rest, or make the window wider to see the whole keyboard.")
                    .stStyle(.caption)
                    .foregroundStyle(theme.inkSecondary)
            }
            if !higherButtons.isEmpty {
                Text("Mouse buttons above 8: " + higherButtons.joined(separator: ", "))
                    .stStyle(.caption)
                    .foregroundStyle(theme.inkSecondary)
            }
            Text("Gold is what a key sends now. \u{25C6} a rule drives the key; select it to see the rule."
                 + (controller.settings.checkerEnabled ? " A red dot is a checker finding." : ""))
                .stStyle(.caption)
                .foregroundStyle(theme.inkTertiary)
        }
    }

    // MARK: Per-key state

    private func state(for event: KarabinerEvent) -> KeyCapState {
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
        state.isFlagged = !controller.derived.flaggedKeys.isDisjoint(with: KeyTable.shared.aliases(of: event))
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
        var parts = [KeyNames.name(for: key.event)]
        if let binding = controller.binding(for: key.event) {
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
        if let output = EffectiveMapping.output(of: key.event, in: controller.derived.bindings) {
            let actions = controller.minecraftActions(for: output)
            if !actions.isEmpty { parts.append("In Minecraft: \(actions.joined(separator: ", "))") }
        }
        if !controller.findings(for: key.event).isEmpty { parts.append("The checker found a problem") }
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
            Text("Scope: \(scopeName)").stStyle(.body).foregroundStyle(STColor.ink)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Scope: \(scopeName)")
    }

    private var scopeName: String {
        guard let device = controller.settings.scopeDevice else { return "All devices" }
        return controller.devices.first { $0.identifiers == device }?.displayName ?? "A device that isn\u{2019}t connected"
    }
}
