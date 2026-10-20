import Foundation
import Testing
@testable import KeyRebinder

@Suite struct KarabinerBackupsTests {
    private func backups(_ directory: TempDirectory, keep: Int = 20, at date: Date = Date(timeIntervalSince1970: 1_792_067_445.123)) -> KarabinerBackups {
        KarabinerBackups(
            directory: directory.url.appending(path: "b"), keep: keep, now: { date },
            fileSystem: LocalKarabinerFileSystem()
        )
    }

    @Test func namesUseUTCTimeAndACounter() async throws {
        try await withTempDirectory { directory in
            let store = backups(directory)
            let first = try store.create(from: Data("one".utf8))
            let second = try store.create(from: Data("two".utf8))
            #expect(first.lastPathComponent == "karabiner-20261015-123045-123-01.json")
            #expect(second.lastPathComponent == "karabiner-20261015-123045-123-02.json")
            #expect(try String(contentsOf: first, encoding: .utf8) == "one")
            #expect(try String(contentsOf: second, encoding: .utf8) == "two")
        }
    }

    @Test func createsTheDirectoryWhenMissing() async throws {
        try await withTempDirectory { directory in
            _ = try backups(directory).create(from: Data())
            #expect(FileManager.default.fileExists(atPath: directory.url.appending(path: "b").path))
        }
    }

    @Test func pruneKeepsTheNewestAndLeavesOtherFilesAlone() async throws {
        try await withTempDirectory { directory in
            let clock = TickingClock()
            let store = KarabinerBackups(
                directory: directory.url.appending(path: "b"), keep: 3, now: { clock.now() },
                fileSystem: LocalKarabinerFileSystem()
            )
            var urls: [URL] = []
            for index in 0..<6 { urls.append(try store.create(from: Data("\(index)".utf8))) }
            try Data("keep me".utf8).write(to: directory.url.appending(path: "b/notes.txt"))
            store.prune()
            let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.url.appending(path: "b").path).sorted()
            #expect(remaining == urls.suffix(3).map(\.lastPathComponent) + ["notes.txt"])
        }
    }

    @Test func pruneNeverKeepsFewerThanOne() async throws {
        try await withTempDirectory { directory in
            let store = backups(directory, keep: 0)
            _ = try store.create(from: Data())
            _ = try store.create(from: Data())
            store.prune()
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.appending(path: "b").path).count == 1)
        }
    }
}
