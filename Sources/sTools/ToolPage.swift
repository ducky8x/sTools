import Backdrop
import Crosshair
import KeyRebinder
import NBBOverlay
import ScreenRecording
import STDesign
import SwiftUI

/// One page for all five tools: header with the tool's switch, the Accessibility strip when needed,
/// then the tool's own settings.
struct ToolPage: View {
    let model: AppModel
    let tool: ToolID

    private var needsAccessibility: Bool { tool.requiresAccessibility && !model.accessibilityGranted }

    var body: some View {
        // The Key Rebinder's keyboard needs more than the usual 640 pt column to be big enough to use.
        PageContainer(maxWidth: tool == .keyRebinder ? 1400 : 640) {
            STPageHeader(title: tool.title, tagline: tool.tagline) {
                if tool.hasSwitch {
                    STSwitch(isOn: model.switchBinding(tool), label: tool.title)
                        .disabled(!model.canSwitch(tool))
                } else if tool == .keyRebinder, let keyRebinder = model.keyRebinder {
                    KeyRebinderProfileMenu(controller: keyRebinder)
                }
            }
            if needsAccessibility {
                STRequirementStrip(
                    kind: .warning,
                    message: "\(tool.title) needs Accessibility to find the Minecraft window.",
                    actionTitle: "Allow\u{2026}",
                    action: { Task { await model.allowAccessibility() } })
                .padding(.top, 18)
            }
            ToolContent(model: model, tool: tool).padding(.top, 22)
        }
        .pollsPermissions(model.permissions, showing: tool.permissionsShown, when: tool.requiresAccessibility)
    }
}

/// A tool's own settings and plate: everything below its page header.
struct ToolContent: View {
    let model: AppModel
    let tool: ToolID

    var body: some View {
        switch tool {
        case .nbbOverlay:
            if let controller = model.controller(for: tool, as: NBBOverlayController.self) {
                NBBOverlaySettingsView(controller: controller)
            }
        case .windowBackdrop:
            if let controller = model.controller(for: tool, as: BackdropController.self) {
                BackdropSettingsView(controller: controller)
            }
        case .crosshair:
            if let controller = model.controller(for: tool, as: CrosshairController.self) {
                CrosshairSettingsView(controller: controller)
            }
        case .keyRebinder:
            if let keyRebinder = model.keyRebinder {
                KeyRebinderView(controller: keyRebinder)
            } else {
                LaterMilestonePlate(tool: tool)
            }
        case .screenRecording:
            if let controller = model.controller(for: tool, as: ScreenRecordingController.self) {
                ScreenRecordingView(controller: controller)
            }
        }
    }
}

/// Stands in for a tool whose page has not been built yet.
struct LaterMilestonePlate: View {
    let tool: ToolID
    @Environment(\.stTheme) private var theme

    var body: some View {
        STPlate {
            Text("\(tool.title) arrives in a later milestone. Nothing here works yet.")
                .stStyle(.body)
                .foregroundStyle(theme.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .accessibilityElement(children: .combine)
    }
}
