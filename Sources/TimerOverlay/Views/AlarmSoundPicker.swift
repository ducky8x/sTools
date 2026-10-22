import STDesign
import SwiftUI

/// The alarm's sound (spec 5.6.6): a menu of the macOS sounds, sTools' alarms and the owner's own files, with
/// Preview, **Add Sound File…** and Remove. The file comes from `chooseSoundFile`, which tests replace, so no test
/// opens a panel. Adding a file copies it into `Sounds/` and makes it the alarm; removing the alarm's own file sends
/// the alarm back to Ping. The words are placeholder wording for M9.
struct AlarmSoundPicker: View {
    @Bindable var controller: TimerOverlayController
    let chooseSoundFile: @MainActor () -> URL?
    @State private var errorText: String?

    /// The menu's sections, in the picker's order.
    static let sections: [(source: AlarmSound.Source, title: String)] = [
        (.macOS, "macOS"), (.sTools, "sTools alarms"), (.file, "Your files"),
    ]

    var body: some View {
        let sounds = controller.sounds
        let current = sounds.first { $0.id == controller.settings.soundID }
        let notes = [controller.missingSoundNote, errorText].compactMap { $0 }
        VStack(alignment: .leading, spacing: 0) {
            STSettingsRow("Alarm sound", showsRule: notes.isEmpty) {
                HStack(spacing: 12) {
                    Menu {
                        ForEach(Self.sections, id: \.source) { section in
                            let listed = sounds.filter { $0.source == section.source }
                            if !listed.isEmpty {
                                Section(section.title) {
                                    ForEach(listed) { sound in
                                        Button { pick(sound) } label: {
                                            if sound.id == current?.id { Label(sound.title, systemImage: "checkmark") } else { Text(sound.title) }
                                        }
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Add Sound File\u{2026}") { addSoundFile() }
                    } label: {
                        STMenuLabel(current?.title ?? "Ping")
                    }
                    .stMenuStyle()
                    .accessibilityLabel("Alarm sound: \(current?.title ?? "Ping")")
                    if let current, current.source == .file {
                        Button("Remove") { remove(current) }
                            .buttonStyle(STButtonStyle(.quiet))
                            .accessibilityLabel("Remove \(current.title)")
                    }
                    Button(controller.isPreviewing ? "Stop" : "Preview") {
                        if controller.isPreviewing { controller.stopPreview() } else { controller.preview() }
                    }
                    .buttonStyle(STButtonStyle(.secondary))
                }
            }
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(notes, id: \.self) { STNoteLine($0, tone: .caution) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true)
                }
            }
        }
    }

    private func pick(_ sound: AlarmSound) {
        errorText = nil
        controller.settings.soundID = sound.id
    }

    private func addSoundFile() {
        guard let file = chooseSoundFile() else { return }
        errorText = Self.add(file, to: controller)
    }

    private func remove(_ sound: AlarmSound) {
        errorText = Self.remove(sound, from: controller)
    }

    /// Copies `file` into `Sounds/` and makes it the alarm; the line to show when that fails, nil when it worked.
    static func add(_ file: URL, to controller: TimerOverlayController) -> String? {
        do {
            try controller.addSound(from: file)
            return nil
        } catch {
            return message(for: error)
        }
    }

    /// Deletes one of the owner's files; the line to show when that fails, nil when it worked.
    static func remove(_ sound: AlarmSound, from controller: TimerOverlayController) -> String? {
        do {
            try controller.removeSound(sound)
            return nil
        } catch {
            return message(for: error)
        }
    }

    /// The line under the picker when adding or removing a file fails: `OwnSoundsError`'s own words.
    static func message(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
