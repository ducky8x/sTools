import STDesign
import STPlatform
import SwiftUI

/// The editor's Karabiner profile row, under the action chips (spec 6.1): None, Next profile and each profile by name,
/// in Karabiner's order, all in view, one chosen. When there is nothing to choose, one line says why in its place. The
/// Key Rebinder's key panel has the same row, from the same `HotkeyProfileChoice`.
struct HotkeyProfileRow: View {
    @Binding var selection: HotkeyProfileAction?
    let profiles: HotkeyProfiles
    @Environment(\.stTheme) private var theme

    var body: some View {
        let choice = HotkeyProfileChoice(profiles: profiles, selection: selection)
        VStack(alignment: .leading, spacing: 4) {
            if choice.options.isEmpty {
                Text(HotkeyWording.profileChoiceLabel)
                    .stStyle(.label)
                    .foregroundStyle(theme.inkSecondary)
                    .accessibilityHidden(true)
            } else {
                STChoiceRow(HotkeyWording.profileChoiceLabel, showsRule: false) {
                    STSegmented(selection: $selection, options: choice.options.map { STSegmentedOption($0.value, $0.title) })
                }
            }
            if let note = choice.note {
                STNoteLine(note)
                    .accessibilityLabel(choice.options.isEmpty ? "\(HotkeyWording.profileChoiceLabel): \(note.text)" : note.text)
            }
        }
    }
}
