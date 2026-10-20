import Foundation
import Testing
@testable import KeyRebinder

@Suite struct KarabinerConfigStoreLoadTests {
    @Test func loadsTheFile() async throws {
        try await withTempDirectory { directory in
            let rig = try StoreRig(directory, text: FixtureLoader.text("typical"))
            let config = try await rig.store.load()
            #expect(config.profiles.count == 3)
            #expect(config.selectedProfileName == "Default profile")
            #expect(config.containsComments == false)
        }
    }

    @Test func missingFileMeansKarabinerIsNotSetUp() async throws {
        try await withTempDirectory { directory in
            let rig = try StoreRig(directory, text: nil)
            await #expect(throws: KarabinerStoreError.notSetUp(rig.configURL)) { try await rig.store.load() }
        }
    }

    @Test func invalidJSONIsMalformed() async throws {
        try await withTempDirectory { directory in
            let rig = try StoreRig(directory, text: #"{"profiles": ["#)
            await #expect {
                try await rig.store.load()
            } throws: { error in
                if case KarabinerStoreError.malformed = error { true } else { false }
            }
        }
    }

    @Test func aTopLevelArrayIsMalformed() async throws {
        try await withTempDirectory { directory in
            let rig = try StoreRig(directory, text: "[]")
            await #expect(throws: KarabinerStoreError.malformed(reason: "the top level is not an object")) {
                try await rig.store.load()
            }
        }
    }

    @Test func reportsComments() async throws {
        try await withTempDirectory { directory in
            let rig = try StoreRig(directory, text: "{ // note\n \"profiles\": [] }")
            #expect(try await rig.store.load().containsComments)
        }
    }

    @Test func readsThroughASymbolicLink() async throws {
        try await withTempDirectory { directory in
            let rig = try StoreRig(directory, text: nil)
            let target = directory.url.appending(path: "real.json")
            try Data(FixtureLoader.text("minimal").utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: rig.configURL, withDestinationURL: target)
            #expect(try await rig.store.load().selectedProfileName == "Default profile")
        }
    }

    @Test func defaultLocations() {
        #expect(KarabinerConfigStore.defaultConfigURL().path.hasSuffix("/.config/karabiner/karabiner.json"))
        #expect(KarabinerConfigStore.defaultBackupsDirectory().path.hasSuffix("/Application Support/sTools/Karabiner Backups"))
    }
}

@Suite struct KarabinerConfigStoreApplyTests {
    @Test func applyBeforeLoadIsRefused() async throws {
        try await withTempDirectory { directory in
            let rig = try StoreRig(directory, text: FixtureLoader.text("minimal"))
            await #expect(throws: KarabinerStoreError.notLoaded) { try await rig.store.apply(settingCounter(1)) }
        }
    }

    @Test func writesTheEditAndKeepsUnrelatedBytes() async throws {
        try await withTempDirectory { directory in
            let original = try StoreRig.karabinerFormatted("typical")
            let rig = try StoreRig(directory, text: original)
            _ = try await rig.store.load()
            let result = try await rig.store.apply(addingTabRebind)

            guard case .written(let config, _) = result else {
                Issue.record("expected .written, got \(result)")
                return
            }
            let after = rig.configText
            let expected = try JSONValue.parse(original).updating("profiles") { profiles in
                let added = try! addingTabRebind(JSONValue.parse(original))["profiles"]?[index: 0]
                return profiles?.replacing(at: 0, with: added ?? .null)
            }
            #expect(after == expected.serialized())
            #expect(config.root == expected)

            let before = original.components(separatedBy: "\n")
            let now = after.components(separatedBy: "\n")
            var head = 0
            while head < min(before.count, now.count), before[head] == now[head] { head += 1 }
            var tail = 0
            while tail < min(before.count, now.count) - head, before[before.count - 1 - tail] == now[now.count - 1 - tail] {
                tail += 1
            }
            #expect(before.count - head - tail <= 3)
            let untouched = Set(before[(before.count - tail)...].joined(separator: "\n").components(separatedBy: "\n"))
            for marker in ["\"name\": \"Plain keyboard\"", "\"name\": \"Macros\"", "\"description\": \"Hold Tab for sprint\""] {
                #expect(untouched.contains { $0.contains(marker) }, "\(marker) must be outside the changed lines")
            }
        }
    }

    @Test func keepsUnknownKeysOrderAndNumberText() async throws {
        try await withTempDirectory { directory in
            let original = try StoreRig.karabinerFormatted("future-keys")
            let rig = try StoreRig(directory, text: original)
            _ = try await rig.store.load()
            _ = try await rig.store.apply(addingTabRebind)
            let after = rig.configText
            for kept in ["18446744073709551615", "1e-7", "-0.5E+3", "\"pointing_motion_xy_multiplier\": 1.0", "\"future_flag\": null", "\"tail_key\""] {
                #expect(after.contains(kept))
            }
            let reparsed = try JSONValue.parse(after)
            #expect(reparsed["tail_key"] == ["a", "b"])
            #expect(reparsed["profiles"]?[index: 0]?["future_profile_block"] == (try JSONValue.parse(original))["profiles"]?[index: 0]?["future_profile_block"])
            #expect(reparsed.members?.map(\.key) == (try JSONValue.parse(original)).members?.map(\.key))
        }
    }

    @Test func anEditThatChangesNothingWritesNothing() async throws {
        try await withTempDirectory { directory in
            let original = try StoreRig.karabinerFormatted("minimal")
            let rig = try StoreRig(directory, text: original)
            _ = try await rig.store.load()
            let result = try await rig.store.apply { $0 }
            guard case .unchanged = result else {
                Issue.record("expected .unchanged, got \(result)")
                return
            }
            #expect(rig.configText == original)
            #expect(rig.backupNames().isEmpty)
        }
    }

    @Test func anEditThatThrowsWritesNothing() async throws {
        struct Refused: Error {}
        try await withTempDirectory { directory in
            let original = try StoreRig.karabinerFormatted("minimal")
            let rig = try StoreRig(directory, text: original)
            _ = try await rig.store.load()
            await #expect(throws: Refused.self) { try await rig.store.apply { _ in throw Refused() } }
            #expect(rig.configText == original)
            #expect(rig.backupNames().isEmpty)
        }
    }

    @Test func backsUpTheFileAsItWasJustBeforeTheWrite() async throws {
        try await withTempDirectory { directory in
            let original = try StoreRig.karabinerFormatted("minimal")
            let rig = try StoreRig(directory, text: original)
            _ = try await rig.store.load()
            let result = try await rig.store.apply(settingCounter(1))
            guard case .written(_, let backupURL) = result else {
                Issue.record("expected .written")
                return
            }
            #expect(backupURL.deletingLastPathComponent().path == rig.backupsURL.path)
            #expect(try String(contentsOf: backupURL, encoding: .utf8) == original)
            #expect(rig.backupNames() == [backupURL.lastPathComponent])
        }
    }

    @Test func keepsTheNewestTwentyBackups() async throws {
        try await withTempDirectory { directory in
            let rig = try StoreRig(directory, text: try StoreRig.karabinerFormatted("minimal"))
            _ = try await rig.store.load()
            var urls: [URL] = []
            for value in 1...25 {
                guard case .written(_, let backup) = try await rig.store.apply(settingCounter(value)) else {
                    Issue.record("write \(value) did not happen")
                    return
                }
                urls.append(backup)
            }
            #expect(rig.backupNames() == urls.suffix(20).map(\.lastPathComponent))
            let newest = try String(contentsOf: urls[24], encoding: .utf8)
            #expect(try JSONValue.parse(newest)["counter"] == .int(24))
        }
    }

    @Test func backupLimitIsConfigurable() async throws {
        try await withTempDirectory { directory in
            let rig = try StoreRig(directory, text: try StoreRig.karabinerFormatted("minimal"), backupsKept: 2)
            _ = try await rig.store.load()
            for value in 1...5 { _ = try await rig.store.apply(settingCounter(value)) }
            #expect(rig.backupNames().count == 2)
        }
    }

    @Test func leavesNoTemporaryFilesAndKeepsPermissions() async throws {
        try await withTempDirectory { directory in
            let rig = try StoreRig(directory, text: try StoreRig.karabinerFormatted("minimal"))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rig.configURL.path)
            _ = try await rig.store.load()
            _ = try await rig.store.apply(settingCounter(1))
            let names = try FileManager.default.contentsOfDirectory(atPath: rig.configURL.deletingLastPathComponent().path)
            #expect(names == ["karabiner.json"])
            let permissions = try FileManager.default.attributesOfItem(atPath: rig.configURL.path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)
        }
    }

    @Test func consecutiveAppliesNeedNoReload() async throws {
        try await withTempDirectory { directory in
            let rig = try StoreRig(directory, text: try StoreRig.karabinerFormatted("minimal"))
            _ = try await rig.store.load()
            for value in 1...3 {
                guard case .written = try await rig.store.apply(settingCounter(value)) else {
                    Issue.record("write \(value) was not a plain write")
                    return
                }
            }
            #expect(try JSONValue.parse(rig.configText)["counter"] == .int(3))
        }
    }

    @Test func aFileThatVanishedMeansNotSetUp() async throws {
        try await withTempDirectory { directory in
            let rig = try StoreRig(directory, text: try StoreRig.karabinerFormatted("minimal"))
            _ = try await rig.store.load()
            try FileManager.default.removeItem(at: rig.configURL)
            await #expect(throws: KarabinerStoreError.notSetUp(rig.configURL)) { try await rig.store.apply(settingCounter(1)) }
        }
    }
}

@Suite struct KarabinerConfigStoreExternalChangeTests {
    private func external(_ text: String) throws -> String {
        try JSONValue.parse(text).setting("added_elsewhere", true).serialized()
    }

    @Test func anExternalChangeIsPreviewedNotWritten() async throws {
        try await withTempDirectory { directory in
            let original = try StoreRig.karabinerFormatted("minimal")
            let rig = try StoreRig(directory, text: original)
            _ = try await rig.store.load()
            let changed = try external(original)
            try rig.write(changed)

            let result = try await rig.store.apply(settingCounter(7))
            guard case .changedExternally(let preview) = result else {
                Issue.record("expected .changedExternally, got \(result)")
                return
            }
            #expect(preview.root["added_elsewhere"] == true)
            #expect(preview.root["counter"] == .int(7))
            #expect(rig.configText == changed)
            #expect(rig.backupNames().isEmpty)
        }
    }

    @Test func confirmingWritesThePreviewedResultAndBacksUpTheExternalVersion() async throws {
        try await withTempDirectory { directory in
            let original = try StoreRig.karabinerFormatted("minimal")
            let rig = try StoreRig(directory, text: original)
            _ = try await rig.store.load()
            let changed = try external(original)
            try rig.write(changed)
            _ = try await rig.store.apply(settingCounter(7))

            let result = try await rig.store.apply(confirm: true, settingCounter(7))
            guard case .written(let config, let backup) = result else {
                Issue.record("expected .written, got \(result)")
                return
            }
            #expect(config.root["added_elsewhere"] == true)
            #expect(config.root["counter"] == .int(7))
            #expect(try JSONValue.parse(rig.configText) == config.root)
            #expect(try String(contentsOf: backup, encoding: .utf8) == changed)
        }
    }

    @Test func aSecondCallWithoutConfirmationStillOnlyPreviews() async throws {
        try await withTempDirectory { directory in
            let original = try StoreRig.karabinerFormatted("minimal")
            let rig = try StoreRig(directory, text: original)
            _ = try await rig.store.load()
            try rig.write(try external(original))
            _ = try await rig.store.apply(settingCounter(7))
            let again = try await rig.store.apply(settingCounter(7))
            guard case .changedExternally = again else {
                Issue.record("expected .changedExternally, got \(again)")
                return
            }
            #expect(rig.backupNames().isEmpty)
        }
    }

    @Test func confirmingWithoutHavingSeenAPreviewDoesNotWrite() async throws {
        try await withTempDirectory { directory in
            let original = try StoreRig.karabinerFormatted("minimal")
            let rig = try StoreRig(directory, text: original)
            _ = try await rig.store.load()
            let changed = try external(original)
            try rig.write(changed)
            let result = try await rig.store.apply(confirm: true, settingCounter(7))
            guard case .changedExternally = result else {
                Issue.record("expected .changedExternally, got \(result)")
                return
            }
            #expect(rig.configText == changed)
        }
    }

    @Test func aSecondExternalChangeAfterThePreviewIsPreviewedAgain() async throws {
        try await withTempDirectory { directory in
            let original = try StoreRig.karabinerFormatted("minimal")
            let rig = try StoreRig(directory, text: original)
            _ = try await rig.store.load()
            try rig.write(try external(original))
            _ = try await rig.store.apply(settingCounter(7))

            let secondChange = try JSONValue.parse(original).setting("added_again", 1).serialized()
            try rig.write(secondChange)
            let result = try await rig.store.apply(confirm: true, settingCounter(7))
            guard case .changedExternally(let preview) = result else {
                Issue.record("expected .changedExternally, got \(result)")
                return
            }
            #expect(preview.root["added_again"] == .int(1))
            #expect(rig.configText == secondChange)

            guard case .written = try await rig.store.apply(confirm: true, settingCounter(7)) else {
                Issue.record("the re-previewed change should now be writable")
                return
            }
        }
    }

    @Test func confirmingWhenNothingChangedJustWrites() async throws {
        try await withTempDirectory { directory in
            let rig = try StoreRig(directory, text: try StoreRig.karabinerFormatted("minimal"))
            _ = try await rig.store.load()
            guard case .written = try await rig.store.apply(confirm: true, settingCounter(1)) else {
                Issue.record("expected .written")
                return
            }
        }
    }

    @Test func rewritingTheSameBytesIsNotAChange() async throws {
        try await withTempDirectory { directory in
            let original = try StoreRig.karabinerFormatted("minimal")
            let rig = try StoreRig(directory, text: original)
            _ = try await rig.store.load()
            try await Task.sleep(for: .milliseconds(20))
            try rig.write(original)
            guard case .written = try await rig.store.apply(settingCounter(1)) else {
                Issue.record("a touch with identical content must not ask for confirmation")
                return
            }
        }
    }

    @Test func anExternalChangeThatMakesTheEditPointlessIsUnchanged() async throws {
        try await withTempDirectory { directory in
            let original = try StoreRig.karabinerFormatted("minimal")
            let rig = try StoreRig(directory, text: original)
            _ = try await rig.store.load()
            let changed = try JSONValue.parse(original).setting("counter", .int(5)).serialized()
            try rig.write(changed)
            let result = try await rig.store.apply(settingCounter(5))
            guard case .unchanged(let config) = result else {
                Issue.record("expected .unchanged, got \(result)")
                return
            }
            #expect(config.root["counter"] == .int(5))
            #expect(rig.configText == changed)
            guard case .written = try await rig.store.apply(settingCounter(6)) else {
                Issue.record("the store should have adopted the new file as its base")
                return
            }
        }
    }

    @Test func loadingAgainAdoptsTheExternalVersion() async throws {
        try await withTempDirectory { directory in
            let original = try StoreRig.karabinerFormatted("minimal")
            let rig = try StoreRig(directory, text: original)
            _ = try await rig.store.load()
            try rig.write(try external(original))
            _ = try await rig.store.load()
            guard case .written = try await rig.store.apply(settingCounter(1)) else {
                Issue.record("expected .written after a fresh load")
                return
            }
        }
    }

    @Test func aFileThatBecameInvalidIsReportedNotOverwritten() async throws {
        try await withTempDirectory { directory in
            let rig = try StoreRig(directory, text: try StoreRig.karabinerFormatted("minimal"))
            _ = try await rig.store.load()
            try rig.write("{ nope")
            await #expect {
                try await rig.store.apply(settingCounter(1))
            } throws: { error in
                if case KarabinerStoreError.malformed = error { true } else { false }
            }
            #expect(rig.configText == "{ nope")
        }
    }
}

@Suite struct KarabinerConfigStoreSafetyTests {
    @Test func refusesToWriteThroughASymbolicLink() async throws {
        try await withTempDirectory { directory in
            let rig = try StoreRig(directory, text: nil)
            let target = directory.url.appending(path: "real.json")
            let text = try StoreRig.karabinerFormatted("minimal")
            try Data(text.utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: rig.configURL, withDestinationURL: target)
            _ = try await rig.store.load()

            await #expect(throws: KarabinerStoreError.symbolicLink(rig.configURL)) { try await rig.store.apply(settingCounter(1)) }
            #expect(try String(contentsOf: target, encoding: .utf8) == text)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: rig.configURL.path) == target.path)
            #expect(rig.backupNames().isEmpty)
        }
    }

    @Test func restoresTheBackupWhenTheWrittenFileDoesNotParse() async throws {
        try await withTempDirectory { directory in
            let original = try StoreRig.karabinerFormatted("minimal")
            let rig = try StoreRig(directory, text: original, fileSystem: FaultyFileSystem(corruptions: 1))
            _ = try await rig.store.load()

            await #expect {
                try await rig.store.apply(settingCounter(1))
            } throws: { error in
                if case KarabinerStoreError.verificationFailed = error { true } else { false }
            }
            #expect(rig.configText == original)
            #expect(rig.backupNames().count == 1)

            guard case .written = try await rig.store.apply(settingCounter(2)) else {
                Issue.record("the store should work again after a restore")
                return
            }
            #expect(try JSONValue.parse(rig.configText)["counter"] == .int(2))
        }
    }

    @Test func reportsWhenTheRestoreFailsToo() async throws {
        try await withTempDirectory { directory in
            let original = try StoreRig.karabinerFormatted("minimal")
            let rig = try StoreRig(directory, text: original, fileSystem: FaultyFileSystem(corruptions: 2))
            _ = try await rig.store.load()

            do {
                _ = try await rig.store.apply(settingCounter(1))
                Issue.record("expected an error")
            } catch KarabinerStoreError.restoreFailed(_, let backup) {
                #expect(try String(contentsOf: backup, encoding: .utf8) == original)
            }
        }
    }

    @Test func aReadOnlyDirectoryLeavesTheFileAndBackupsAlone() async throws {
        try #require(geteuid() != 0, "root ignores directory permissions")
        try await withTempDirectory { directory in
            let original = try StoreRig.karabinerFormatted("minimal")
            let rig = try StoreRig(directory, text: original)
            _ = try await rig.store.load()
            let configDirectory = rig.configURL.deletingLastPathComponent().path
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: configDirectory)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: configDirectory) }

            await #expect {
                try await rig.store.apply(settingCounter(1))
            } throws: { error in
                if case KarabinerStoreError.writeFailed = error { true } else { false }
            }
            #expect(rig.configText == original)
            #expect(rig.backupNames().isEmpty)
        }
    }

    @Test func failingToBackUpMeansNothingIsWritten() async throws {
        try await withTempDirectory { directory in
            let original = try StoreRig.karabinerFormatted("minimal")
            let rig = try StoreRig(directory, text: original)
            try Data("in the way".utf8).write(to: rig.backupsURL)
            _ = try await rig.store.load()

            await #expect {
                try await rig.store.apply(settingCounter(1))
            } throws: { error in
                if case KarabinerStoreError.backupFailed = error { true } else { false }
            }
            #expect(rig.configText == original)
        }
    }

    @Test func errorsExplainThemselves() {
        let url = URL(fileURLWithPath: "/x/karabiner.json")
        #expect(KarabinerStoreError.symbolicLink(url).errorDescription?.contains("symbolic link") == true)
        #expect(KarabinerStoreError.notSetUp(url).errorDescription?.contains("not been set up") == true)
        #expect(KarabinerStoreError.restoreFailed(reason: "r", backup: url).errorDescription?.contains("/x/karabiner.json") == true)
    }
}
