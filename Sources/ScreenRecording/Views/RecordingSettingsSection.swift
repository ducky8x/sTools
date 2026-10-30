import AppKit
import STDesign
import SwiftUI

/// Screen Recording's settings (spec 5.4.5): main rows, then Advanced.
struct RecordingSettingsSection: View {
    @Bindable var controller: ScreenRecordingController
    @State private var showsAdvanced = false
    @State private var isResetConfirming = false
    @Environment(\.stTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                STSettingsRow("Folder") {
                    HStack(spacing: 10) {
                        Text((controller.options.folderPath as NSString).abbreviatingWithTildeInPath)
                            .stStyle(.body).foregroundStyle(theme.inkSecondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose\u{2026}", action: chooseFolder).buttonStyle(STButtonStyle(.secondary))
                    }
                }
                STChoiceRow("Frame rate") {
                    STSegmented(selection: $controller.options.frameRate, options: [.init(.fps60, "60 fps"), .init(.fps30, "30 fps")])
                }
                STChoiceRow("Output size") {
                    STSegmented(selection: $controller.options.outputSize, options: [
                        .init(.native, "Native"), .init(.p1440, "1440p"), .init(.p1080, "1080p"),
                    ])
                }
                STChoiceRow("File type", showsRule: false) {
                    STSegmented(selection: $controller.options.fileType, options: [.init(.mp4, ".mp4"), .init(.mov, ".mov")])
                }
            }
            .disabled(controller.isLayoutLocked)

            STAdvancedDisclosure(isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 0) {
                    STChoiceRow("Canvas size") {
                        STSegmented(selection: canvasChoice, options: [.init(false, "Minecraft\u{2019}s display"), .init(true, "Custom")])
                    }
                    if case .custom(let size) = controller.options.canvas {
                        STSettingsRow("Custom size") {
                            HStack(spacing: 10) {
                                PixelField("Width", value: Binding(get: { size.width }, set: { setCanvas(PixelSize(width: $0, height: size.height)) }))
                                PixelField("Height", value: Binding(get: { size.height }, set: { setCanvas(PixelSize(width: size.width, height: $0)) }))
                            }
                        }
                    }
                    STChoiceRow("Codec") {
                        STSegmented(selection: $controller.options.codec, options: [.init(.h264, "H.264"), .init(.hevc, "HEVC")])
                    }
                    STSettingsRow("Quality") {
                        HStack(spacing: 12) {
                            if case .manual(let value) = controller.options.quality {
                                STSlider(value: Binding(get: { value * 100 }, set: { controller.options.quality = .manual($0 / 100) }),
                                         in: 10...100, label: "Quality", valueText: { "\(Int($0))%" })
                            }
                            STSegmented(selection: manualQuality, options: [.init(false, "Automatic"), .init(true, "Manual")])
                        }
                    }
                    STSettingsRow("Show mouse pointer") {
                        STSwitch(isOn: $controller.options.showCursor, label: "Show mouse pointer")
                    }
                    STSettingsRow("Ask Save or Delete on stop") {
                        STSwitch(isOn: $controller.options.askSaveDelete, label: "Ask Save or Delete on stop")
                    }
                    STChoiceRow("Countdown") {
                        STSegmented(selection: $controller.options.countdown, options: [
                            .init(.off, "Off"), .init(.threeSeconds, "3 s"), .init(.fiveSeconds, "5 s"),
                        ])
                    }
                    STChoiceRow("Split into files every") {
                        STSegmented(selection: $controller.options.split, options: [
                            .init(.off, "Off"), .init(.thirtyMinutes, "30 min"), .init(.sixtyMinutes, "60 min"), .init(.twoHours, "120 min"),
                        ])
                    }
                    STSettingsRow("Low-disk warning") {
                        STSlider(value: $controller.options.lowDiskWarningGB, in: 1...100, label: "Low-disk warning",
                                 valueText: { "under \(Int($0)) GB" })
                    }
                    STSettingsRow("Live preview while recording") {
                        STSwitch(isOn: $controller.options.livePreview, label: "Live preview while recording")
                    }
                    STChoiceRow("Minimized window source") {
                        STSegmented(selection: $controller.options.minimizedWindowBehavior, options: [
                            .init(.holdLastFrame, "Hold last frame"), .init(.showNothing, "Show nothing"),
                        ])
                    }
                    STSettingsRow("Reset", showsRule: false) {
                        Button("Reset to default\u{2026}") { isResetConfirming = true }.buttonStyle(STButtonStyle(.secondary))
                    }
                }
                .disabled(controller.isLayoutLocked)
            }
        }
        .confirmationDialog("Reset Screen Recording settings?", isPresented: $isResetConfirming) {
            Button("Reset", role: .destructive) { controller.resetToDefault() }
        } message: {
            Text("Folder, frame rate, size and the Advanced choices go back to their defaults. Your canvas layout is kept.")
        }
    }

    private var canvasChoice: Binding<Bool> {
        Binding(
            get: { if case .custom = controller.options.canvas { true } else { false } },
            set: { custom in controller.options.canvas = custom ? .custom(controller.minecraftDisplaySize.evenSized) : .minecraftDisplay })
    }

    private func setCanvas(_ size: PixelSize) {
        var options = controller.options
        options.canvas = .custom(size)
        options.clamp()
        controller.options = options
    }

    private var manualQuality: Binding<Bool> {
        Binding(
            get: { if case .manual = controller.options.quality { true } else { false } },
            set: { manual in controller.options.quality = manual ? .manual(0.7) : .automatic })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = controller.options.folderURL
        panel.message = "Choose where recordings are saved."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.options.folderPath = url.path
    }
}
