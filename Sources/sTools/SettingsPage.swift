import AppKit
import STDesign
import STPlatform
import SwiftUI
import UniformTypeIdentifiers

/// Settings (spec 6.2): General, Appearance, Updates, Data, Help.
struct SettingsPage: View {
    let model: AppModel
    @State private var generalAdvancedIsOpen: Bool
    @State private var appearanceAdvancedIsOpen = false
    @State private var dataMessage: String?
    @State private var isResetConfirming = false
    @State private var isResetAllToolsConfirming = false
    @State private var diagnosticsCopied = false

    init(model: AppModel, generalAdvancedIsOpen: Bool = false) {
        self.model = model
        _generalAdvancedIsOpen = State(initialValue: generalAdvancedIsOpen)
    }

    var body: some View {
        PageContainer {
            STPageHeader(title: "Settings", tagline: "How sTools looks, sounds and moves.") { EmptyView() }

            PageSectionTitle("General").padding(.top, 28).padding(.bottom, 4)
            STSettingsRow("Open at login", showsRule: false) {
                HStack(spacing: 10) {
                    if model.loginItemState == .requiresApproval {
                        Button("Open System Settings\u{2026}") { model.loginItem.openSystemSettings() }
                            .buttonStyle(STButtonStyle(.quiet))
                    }
                    STSwitch(isOn: Binding(get: { model.loginItem.isEnabled }, set: { model.setOpensAtLogin($0) }), label: "Open at login")
                }
            }
            STAdvancedDisclosure(isExpanded: $generalAdvancedIsOpen) {
                STSettingsRow("Restore tools that were on at quit", showsRule: false) {
                    STSwitch(isOn: model.generalBinding(\.restoreToolsAtQuit), label: "Restore tools that were on at quit")
                }
            }
            .padding(.top, 14)

            PageSectionTitle("Appearance").padding(.top, 28).padding(.bottom, 4)
            STSettingsRow("Sounds") {
                STSwitch(isOn: model.appearanceBinding(\.soundsEnabled), label: "Sounds")
            }
            STSettingsRow("Volume") {
                STSlider(value: model.percentBinding(\.soundVolume), in: 0...100, step: 5, label: "Volume",
                         valueText: PercentFormat.text, parse: PercentFormat.parse)
                    .frame(width: 260)
            }
            STAdvancedDisclosure(isExpanded: $appearanceAdvancedIsOpen) {
                appearanceAdvancedRows
            }
            .padding(.top, 14)

            PageSectionTitle("Updates").padding(.top, 28).padding(.bottom, 4)
            STSettingsRow("Check automatically") {
                STSwitch(isOn: model.updatesBinding(\.checksAutomatically), label: "Check automatically")
            }
            STSettingsRow("Download and install automatically", showsRule: false) {
                STSwitch(isOn: model.updatesBinding(\.installsAutomatically), label: "Download and install automatically")
            }

            PageSectionTitle("Data").padding(.top, 28).padding(.bottom, 4)
            STSettingsRow("Settings file") {
                HStack(spacing: 14) {
                    Button("Export settings\u{2026}") { exportSettings() }
                        .buttonStyle(STButtonStyle(.secondary))
                    Button("Import settings\u{2026}") { importSettings() }
                        .buttonStyle(STButtonStyle(.secondary))
                }
            }
            if let dataMessage {
                Text(dataMessage).stStyle(.caption).foregroundStyle(STColor.inkSecondary).padding(.top, 4)
            }
            STSettingsRow("Reset all tools to default") {
                Button("Reset All Tools\u{2026}") { isResetAllToolsConfirming = true }
                    .buttonStyle(STButtonStyle(.secondary))
            }
            .confirmationDialog(
                "Reset every tool's settings to default?", isPresented: $isResetAllToolsConfirming, titleVisibility: .visible,
                actions: {
                    Button("Reset All Tools", role: .destructive) { model.resetAllToolsToDefault() }
                    Button("Cancel", role: .cancel) {}
                },
                message: { Text("This sets Window Backdrop, Crosshair and NBB Overlay back to their defaults. General, Appearance and Hotkeys are untouched — use Reset sTools below for those.") })
            STSettingsRow("Reset sTools", showsRule: false) {
                Button("Reset sTools\u{2026}") { isResetConfirming = true }
                    .buttonStyle(STButtonStyle(.secondary))
            }
            .confirmationDialog(
                "Reset sTools?", isPresented: $isResetConfirming, titleVisibility: .visible,
                actions: {
                    Button("Reset sTools", role: .destructive) { resetApp() }
                    Button("Cancel", role: .cancel) {}
                },
                message: { Text("This clears every setting and brings back the first-launch introduction. Your current settings are backed up first, then sTools opens again.") })

            PageSectionTitle("Help").padding(.top, 28).padding(.bottom, 4)
            STSettingsRow("Replay Introduction") {
                Button("Replay Introduction") { model.replayIntroduction() }
                    .buttonStyle(STButtonStyle(.secondary))
            }
            STSettingsRow("Copy Diagnostics", showsRule: false) {
                HStack(spacing: 10) {
                    if diagnosticsCopied {
                        Text("Copied").stStyle(.caption).foregroundStyle(STColor.inkSecondary)
                    }
                    Button("Copy Diagnostics") { copyDiagnostics() }
                        .buttonStyle(STButtonStyle(.secondary))
                }
            }
        }
    }

    @ViewBuilder private var appearanceAdvancedRows: some View {
        STSettingsRow("Motion") {
            STSegmented(selection: model.appearanceBinding(\.motionMode),
                        options: [STSegmentedOption(.full, "Full"), STSegmentedOption(.reduced, "Reduced")])
        }
        STSettingsRow("Text size") {
            STSlider(value: model.percentBinding(\.textScale), in: 90...130, step: 5, label: "Text size",
                     valueText: PercentFormat.text, parse: PercentFormat.parse)
                .frame(width: 260)
        }
        STSettingsRow("Accent color") {
            STColorWell(hex: model.appearanceBinding(\.accentHex), label: "Accent color")
        }
    }

    // MARK: - Actions

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "sTools"
        panel.allowedContentTypes = [Self.settingsFileType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let summary = try await model.exportSettings(to: url)
                dataMessage = "Exported \(summary.documentNames.count) setting groups."
            } catch {
                dataMessage = "Couldn't export: \(error.localizedDescription)"
            }
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.settingsFileType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let report = try await model.importSettings(from: url)
                dataMessage = "Imported \(report.appliedCount) item(s)" + (report.skippedCount > 0 ? ", skipped \(report.skippedCount)." : ".")
            } catch {
                dataMessage = "Couldn't import: \(error.localizedDescription)"
            }
        }
    }

    /// Relaunches so that no setting still held in memory is written back (spec 6.2: re-runs the Prologue).
    private func resetApp() {
        Task {
            do {
                try await model.resetAppSettings()
                model.settingsWereReset = true
                AppRelauncher.relaunch()
            } catch {
                dataMessage = error.localizedDescription
            }
        }
    }

    private func copyDiagnostics() {
        model.copyDiagnostics()
        diagnosticsCopied = true
    }

    private static let settingsFileType = UTType(filenameExtension: "stools-settings") ?? .json
}
