import Testing
@testable import sTools

@MainActor
@Suite("Settings ▸ Data messages")
struct SettingsPageMessageTests {
    @Test func theExportLineCountsSettingGroupsInTheRightNumber() {
        #expect(SettingsPage.exportedMessage(groups: 1) == "Exported 1 setting group.")
        #expect(SettingsPage.exportedMessage(groups: 6) == "Exported 6 setting groups.")
    }

    @Test func theImportLineCountsItemsInTheRightNumber() {
        #expect(SettingsPage.importedMessage(applied: 1, skipped: 0) == "Imported 1 item.")
        #expect(SettingsPage.importedMessage(applied: 0, skipped: 0) == "Imported 0 items.")
        #expect(SettingsPage.importedMessage(applied: 3, skipped: 1) == "Imported 3 items, skipped 1.")
    }
}
