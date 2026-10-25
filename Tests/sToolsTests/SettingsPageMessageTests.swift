import Testing
@testable import sTools

/// Settings ▸ Data's lines after an export or import count in words that agree with each count, one included.
@MainActor
@Suite("Settings data messages")
struct SettingsPageMessageTests {
    @Test func anExportCountsItsGroups() {
        #expect(SettingsPage.exportedMessage(groups: 1) == "Exported 1 setting group.")
        #expect(SettingsPage.exportedMessage(groups: 7) == "Exported 7 setting groups.")
    }

    @Test func anImportCountsWhatItAppliedAndSkipped() {
        #expect(SettingsPage.importedMessage(applied: 1, skipped: 0) == "Imported 1 item.")
        #expect(SettingsPage.importedMessage(applied: 5, skipped: 0) == "Imported 5 items.")
        #expect(SettingsPage.importedMessage(applied: 0, skipped: 1) == "Imported 0 items, skipped 1.")
        #expect(SettingsPage.importedMessage(applied: 4, skipped: 2) == "Imported 4 items, skipped 2.")
    }
}
