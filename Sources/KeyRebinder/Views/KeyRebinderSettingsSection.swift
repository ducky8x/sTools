import AppKit
import STDesign
import SwiftUI

/// The Key Rebinder's settings (spec 5.5.9): main rows, then Advanced.
struct KeyRebinderSettingsSection: View {
    @Bindable var controller: KeyRebinderController
    /// Whether the page shows sTools hotkeys, which Advanced ▸ Show hotkeys switches. False in the Prologue's trial.
    var showsHotkeys = true

    @State private var showsAdvanced = false
    @State private var isResetConfirming = false
    @Environment(\.stTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                if controller.layout != nil {
                    STSettingsRow("Keyboard") {
                        VStack(alignment: .trailing, spacing: 8) {
                            STSegmented(selection: shapeBinding, options: KeyboardShape.allCases.map { STSegmentedOption($0, $0.title) })
                            STSegmented(selection: formFactorBinding, options: KeyboardFormFactor.allCases.map { STSegmentedOption($0, $0.title) })
                        }
                    }
                }
                STSettingsRow("Show Minecraft keybinds", showsRule: controller.settings.showsMinecraftKeybinds) {
                    STSwitch(isOn: $controller.settings.showsMinecraftKeybinds, label: "Show Minecraft keybinds")
                }
                if controller.settings.showsMinecraftKeybinds {
                    STSettingsRow("options.txt", showsRule: false) {
                        HStack(spacing: 10) {
                            if controller.settings.customOptionsFilePath != nil {
                                Button("Find Automatically") { controller.settings.customOptionsFilePath = nil }
                                    .buttonStyle(STButtonStyle(.quiet))
                            }
                            Button("Choose\u{2026}", action: chooseOptionsFile).buttonStyle(STButtonStyle(.secondary))
                        }
                    }
                    Text(optionsStatus)
                        .stStyle(.caption)
                        .foregroundStyle(controller.optionsProblem == nil ? theme.inkTertiary : STColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                }
                STSettingsRow("Checker") {
                    STSwitch(isOn: $controller.settings.checkerEnabled, label: "Checker")
                }
                if controller.settings.checkerEnabled {
                    STSettingsRow("Speedrun-rule findings") {
                        STSwitch(isOn: $controller.settings.checkerIncludesSpeedrunRules, label: "Speedrun-rule findings")
                    }
                }
            }

            STAdvancedDisclosure(isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 0) {
                    STSettingsRow("Hover arcs") {
                        STSwitch(isOn: $controller.settings.showsHoverArcs, label: "Hover arcs")
                    }
                    if Self.offersShowHotkeys(controller: controller, showsHotkeys: showsHotkeys) {
                        STSettingsRow("Show hotkeys") {
                            STSwitch(isOn: $controller.settings.showsHotkeys, label: "Show hotkeys")
                        }
                    }
                    STSettingsRow("Backups kept") {
                        STSegmented(selection: backupsBinding, options: KeyRebinderSettings.backupsKeptChoices.map { STSegmentedOption($0, "\($0)") })
                    }
                    Text("Copies of karabiner.json made before every change, in ~/Library/Application Support/sTools/Karabiner Backups.")
                        .stStyle(.caption).foregroundStyle(theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                    STSettingsRow("Reset", showsRule: false) {
                        Button("Reset to default\u{2026}") { isResetConfirming = true }.buttonStyle(STButtonStyle(.secondary))
                    }
                }
            }
        }
        .confirmationDialog("Reset Key Rebinder settings?", isPresented: $isResetConfirming) {
            Button("Reset", role: .destructive) { controller.resetToDefault() }
        } message: {
            Text("Your keyboard layout, scope and checker choices go back to their defaults. Your rebinds in Karabiner-Elements are not touched.")
        }
    }

    /// Advanced ▸ Show hotkeys appears once the page has a hotkey list to show, and never in the trial.
    static func offersShowHotkeys(controller: KeyRebinderController, showsHotkeys: Bool) -> Bool {
        showsHotkeys && controller.hotkeyCenter != nil
    }

    private var optionsStatus: String {
        if let problem = controller.optionsProblem { return problem }
        guard let file = controller.optionsFile else { return "" }
        let how = controller.settings.customOptionsFilePath == nil ? "Found automatically" : "Chosen"
        return "\(how): \((file.path as NSString).abbreviatingWithTildeInPath)"
    }

    private var shapeBinding: Binding<KeyboardShape> {
        Binding(get: { controller.settings.keyboardShape ?? .ansi }, set: { controller.settings.keyboardShape = $0 })
    }

    private var formFactorBinding: Binding<KeyboardFormFactor> {
        Binding(get: { controller.settings.formFactor ?? .laptop }, set: { controller.settings.formFactor = $0 })
    }

    /// Snaps an odd stored count (from an imported file) to the nearest offered choice for display.
    private var backupsBinding: Binding<Int> {
        Binding(
            get: {
                let kept = controller.settings.backupsKept
                return KeyRebinderSettings.backupsKeptChoices.min { abs($0 - kept) < abs($1 - kept) } ?? kept
            },
            set: { controller.settings.backupsKept = $0 })
    }

    /// Minecraft's `options.txt`, or the game folder that holds it.
    private func chooseOptionsFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose Minecraft\u{2019}s options.txt, or the game folder that holds it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let file = isDirectory.boolValue
            ? MinecraftKeybinds.locateOptionsFile(gameDirectory: url) ?? url.appending(path: "options.txt")
            : url
        controller.settings.customOptionsFilePath = file.path
    }
}
