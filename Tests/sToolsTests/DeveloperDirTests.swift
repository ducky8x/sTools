import Foundation
import Testing

/// Which developer tools the scripts run (`scripts/lib/developer-dir.sh`): DEVELOPER_DIR when it is set, else the Xcode
/// beta when it is installed, else Xcode, else whatever `xcode-select` chose. The Command Line Tools alone have no actool,
/// which the app's icon needs, so an installed Xcode comes first. Nothing here changes `xcode-select`.
@Suite("Developer folder")
struct DeveloperDirTests {
    static let library = repositoryRoot.appending(path: "scripts/lib/developer-dir.sh")

    /// A folder for made-up Xcode installs, removed afterwards.
    private final class Installs {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sTools-developer-\(UUID().uuidString)")

        /// A developer folder that exists.
        func installed(_ name: String) throws -> String {
            let url = folder.appending(path: "\(name)/Contents/Developer")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }

        /// A developer folder that doesn't exist.
        func missing(_ name: String) -> String { folder.appending(path: "\(name)/Contents/Developer").path }

        deinit { try? FileManager.default.removeItem(at: folder) }
    }

    /// What `use_full_xcode` leaves in DEVELOPER_DIR when it looks at `candidates`, in that order, with DEVELOPER_DIR set
    /// to `given` beforehand. Empty when it is left unset. Runs as the scripts do, with `set -euo pipefail`.
    private func chosen(_ candidates: [String], given: String? = nil) async throws -> String {
        var environment = ["HOME": FileManager.default.temporaryDirectory.path, "PATH": "/usr/bin:/bin", "LIB": Self.library.path]
        if let given { environment["DEVELOPER_DIR"] = given }
        let script = #"set -euo pipefail; source "$LIB"; use_full_xcode "$@"; printf '%s' "${DEVELOPER_DIR:-}""#
        let result = try await runScript(URL(filePath: "/bin/bash"), ["-c", script, "bash"] + candidates,
                                         environment: environment, timeout: .seconds(60))
        #expect(result.status == 0, "\(result.output)")
        return result.output
    }

    @Test func theBetaComesFirstWhenItIsInstalled() async throws {
        let installs = Installs()
        let beta = try installs.installed("Xcode-beta.app")
        let xcode = try installs.installed("Xcode.app")
        #expect(try await chosen([beta, xcode]) == beta)
    }

    /// The beta is gone: Xcode it is, not the Command Line Tools `xcode-select` may point at.
    @Test func xcodeWhenTheBetaIsGone() async throws {
        let installs = Installs()
        let xcode = try installs.installed("Xcode.app")
        #expect(try await chosen([installs.missing("Xcode-beta.app"), xcode]) == xcode)
    }

    /// Neither is installed: DEVELOPER_DIR stays unset, so `xcrun` uses what `xcode-select` chose.
    @Test func nothingWhenNeitherIsInstalled() async throws {
        let installs = Installs()
        #expect(try await chosen([installs.missing("Xcode-beta.app"), installs.missing("Xcode.app")]).isEmpty)
    }

    @Test func aDeveloperFolderGivenInTheEnvironmentWins() async throws {
        let installs = Installs()
        let beta = try installs.installed("Xcode-beta.app")
        let own = try installs.installed("Own.app")
        #expect(try await chosen([beta], given: own) == own)
    }

    /// Without candidates of its own it looks for the Xcode beta, then Xcode, where they install.
    @Test func itLooksForTheBetaThenXcodeInApplications() throws {
        let text = try String(contentsOf: Self.library, encoding: .utf8)
        let beta = try #require(text.range(of: "/Applications/Xcode-beta.app/Contents/Developer"))
        let xcode = try #require(text.range(of: "/Applications/Xcode.app/Contents/Developer"))
        #expect(beta.lowerBound < xcode.lowerBound)
    }

    /// Every script that runs developer tools chooses them this way, and none names the beta itself any more, so one
    /// missing Xcode can't stop a script that another installed one would run.
    @Test func everyScriptChoosesThisWay() throws {
        let scripts = ["build-app.sh", "build-dmg.sh", "check-appcast.sh", "check-no-home-paths.sh", "make-update-key.sh",
                       "publish-update.sh", "smoke-update.sh"]
        for name in scripts {
            let text = try String(contentsOf: repositoryRoot.appending(path: "scripts/\(name)"), encoding: .utf8)
            #expect(text.contains(#"source "$ROOT/scripts/lib/developer-dir.sh""#), "\(name) uses the library")
            #expect(text.contains("\nuse_full_xcode\n"), "\(name) chooses with it")
            #expect(!text.contains("Xcode-beta"), "\(name) names the beta itself")
        }
        let all = try FileManager.default.contentsOfDirectory(atPath: repositoryRoot.appending(path: "scripts").path)
            .filter { $0.hasSuffix(".sh") }
        for name in all where !scripts.contains(name) {
            let text = try String(contentsOf: repositoryRoot.appending(path: "scripts/\(name)"), encoding: .utf8)
            #expect(!text.contains("Xcode-beta"), "\(name) names the beta itself")
        }
    }
}
