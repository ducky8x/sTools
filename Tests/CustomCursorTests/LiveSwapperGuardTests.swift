import Foundation
import Testing

/// The live swapper changes the pointer macOS draws for the whole Mac, and what it registers outlives the process (spec
/// 5.7.1). No test, benchmark or helper may build it: they use a fake `CursorSwapping`. This reads every file under
/// `Tests/` and `Benchmarks/` and fails if one names it. The names are put together here so this file doesn't name it
/// either.
@Suite("Custom Cursor: no test uses the real pointer")
struct LiveSwapperGuardTests {
    private static let forbidden = ["Live" + "CursorSwapper", "makeLive" + "Swapper"]

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func swiftFiles(under folder: String) -> [URL] {
        let root = packageRoot.appending(path: folder, directoryHint: .isDirectory)
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    @Test func noTestOrBenchmarkNamesTheLiveSwapper() throws {
        let files = Self.swiftFiles(under: "Tests") + Self.swiftFiles(under: "Benchmarks")
        #expect(files.count > 100, "the walk found the test files")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for name in Self.forbidden {
                #expect(!text.contains(name), "\(file.lastPathComponent) names \(name)")
            }
        }
    }

    /// In the app, only the production wiring builds it: `AppModel`'s own initializer, which no test calls.
    @Test func onlyTheAppsOwnWiringBuildsIt() throws {
        let users = try Self.swiftFiles(under: "Sources").filter { file in
            let text = try String(contentsOf: file, encoding: .utf8)
            return text.contains(Self.forbidden[1])
        }
        #expect(users.map(\.lastPathComponent).sorted() == ["AppModel.swift", "CursorSwapping.swift"])
    }

    /// No test calls the app model's own initializer, the production wiring that builds the live swapper.
    @Test func noTestBuildsTheAppsOwnWiring() throws {
        for file in Self.swiftFiles(under: "Tests") {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("AppModel" + "()"), "\(file.lastPathComponent)")
            #expect(!text.contains("AppDelegate" + "()"), "\(file.lastPathComponent)")
        }
    }
}
