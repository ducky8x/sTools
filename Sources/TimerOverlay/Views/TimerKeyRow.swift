import STDesign
import SwiftUI

/// The key row (spec 5.6.2): the Start-timer key from Home ▸ Hotkeys ("Start timer: F13", or "No key yet"), any
/// problem with it, whether Hotkeys are on, and **Set in Hotkeys…**, which shows only when the app passes
/// `onSetInHotkeys` (the Prologue's trial records the key in place, so it passes nil). It shows only what it's
/// given: the timer registers no key of its own (spec 5.6.10). The words are placeholder wording for M9.
struct TimerKeyRow: View {
    let status: TimerKeyStatus
    let onSetInHotkeys: (@MainActor () -> Void)?
    @Environment(\.stTheme) private var theme

    /// One line under the key.
    struct Note: Equatable, Identifiable {
        var text: String
        var isCaution: Bool
        var id: String { text }
    }

    /// Each key's problem, then whether Hotkeys are on. While they're off a key does nothing, so that line is a
    /// caution when there is one.
    static func notes(for status: TimerKeyStatus) -> [Note] {
        var notes = status.keys.compactMap { key in
            key.problem.map { Note(text: "\(key.name): \($0)", isCaution: true) }
        }
        if status.hotkeysAreOn {
            notes.append(Note(text: "Hotkeys are on.", isCaution: false))
        } else if status.hasKey {
            notes.append(Note(text: "Hotkeys are off, so the key does nothing until they\u{2019}re on.", isCaution: true))
        } else {
            notes.append(Note(text: "Hotkeys are off.", isCaution: false))
        }
        return notes
    }

    var body: some View {
        let notes = Self.notes(for: status)
        VStack(alignment: .leading, spacing: 0) {
            STSettingsRow("Key", showsRule: false) {
                HStack(spacing: 12) {
                    Text(status.title)
                        .stStyle(.body)
                        .foregroundStyle(status.hasKey ? STColor.ink : theme.inkSecondary)
                    if let onSetInHotkeys {
                        Button("Set in Hotkeys\u{2026}") { onSetInHotkeys() }
                            .buttonStyle(STButtonStyle(.quiet))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notes) { note in
                    STNoteLine(note.text, tone: note.isCaution ? .caution : .note)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true)
            }
        }
    }
}
