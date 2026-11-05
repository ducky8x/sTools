import STDesign
import SwiftUI

/// The Crosshair page's two switches for Minecraft's menus, each with a line on what it does. Being the pointer hides the
/// crosshair in the menus too, so while it's on the hide switch shows on and can't be changed.
struct CrosshairMenuRows: View {
    @Bindable var controller: CrosshairController

    /// The rows' words, gathered here.
    enum Copy {
        static let hideLabel = "Hide in Minecraft\u{2019}s menus"
        static let hideCaption = "Hides the crosshair while Minecraft shows the pointer: in menus, inventories and the pause screen."
        static let hideWhilePointer = "Always on while the crosshair is the pointer."
        static let pointerLabel = "Be the pointer in Minecraft\u{2019}s menus"
        static let pointerCaption = "In menus, the pointer looks like the crosshair and clicks where it aims."
        static let otherApps = "When sTools puts your arrow back, it can also reset pointers another cursor app such as "
            + "Mousecape changed. Apply them again from that app."
        static let cantWatch = "This version of macOS doesn\u{2019}t say when Minecraft shows the pointer, so these do nothing."
        static let cantSwap = "This version of macOS doesn\u{2019}t let sTools change the pointer."
    }

    var body: some View {
        let isPointer = controller.settings.isPointerInMinecraftMenus
        VStack(alignment: .leading, spacing: 0) {
            STSettingsRow(Copy.hideLabel, showsRule: false) {
                STSwitch(isOn: hideBinding, label: Copy.hideLabel)
                    .disabled(!Self.hideIsEditable(canWatch: controller.canHideInMinecraftMenus, isPointer: isPointer))
            }
            CrosshairCaptions(lines: [Self.hideLine(isPointer: isPointer)])
            STSettingsRow(Copy.pointerLabel, showsRule: false) {
                STSwitch(isOn: $controller.settings.isPointerInMinecraftMenus, label: Copy.pointerLabel)
                    .disabled(!controller.canBeThePointer)
            }
            CrosshairCaptions(lines: Self.pointerLines(canWatch: controller.canHideInMinecraftMenus,
                                                       canSwap: controller.canBeThePointer))
        }
    }

    /// Shows the hide switch on while being the pointer hides the crosshair anyway; a change edits the hide setting alone.
    private var hideBinding: Binding<Bool> {
        Binding(get: { controller.settings.hidesWhileThePointerShows },
                set: { controller.settings.hidesInMinecraftMenus = $0 })
    }

    /// The hide switch can be changed when the pointer can be watched and the crosshair isn't the pointer.
    static func hideIsEditable(canWatch: Bool, isPointer: Bool) -> Bool {
        canWatch && !isPointer
    }

    /// The line under the hide switch: what it does, or why it's on and can't be changed.
    static func hideLine(isPointer: Bool) -> String {
        isPointer ? Copy.hideWhilePointer : Copy.hideCaption
    }

    /// The lines under the pointer switch: what it does, then what it can undo in another cursor app, or why it can't
    /// work on this macOS.
    static func pointerLines(canWatch: Bool, canSwap: Bool) -> [String] {
        if !canWatch { return [Copy.pointerCaption, Copy.cantWatch] }
        if !canSwap { return [Copy.pointerCaption, Copy.cantSwap] }
        return [Copy.pointerCaption, Copy.otherApps]
    }
}

/// Small lines under a switch row, with the row's hairline beneath them.
private struct CrosshairCaptions: View {
    let lines: [String]
    @Environment(\.stTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .stStyle(.caption)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true)
        }
    }
}
