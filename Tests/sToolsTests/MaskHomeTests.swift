import Foundation
import Testing

/// What the release scripts print: `scripts/lib/mask-home.sh` (the build scripts and the smoke test) and the checker
/// behind `scripts/check-no-home-paths.sh` hide the home folder, the account name and the full name, and each part of
/// the full name on its own. Every name here is made up: the script's `id` is replaced by one that answers with them
/// (or the checker's test hook adds them), so no test reads, prints or compares the person's real name.
@Suite("Mask home")
struct MaskHomeTests {
    static let library = repositoryRoot.appending(path: "scripts/lib/mask-home.sh")

    /// A home folder, and an `id` that gives a made-up account name and full name, in a folder of their own.
    private final class Workspace {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sTools-mask-\(UUID().uuidString)")
        var home: URL { folder.appending(path: "quuxhome") }
        var bin: URL { folder.appending(path: "bin") }

        init(account: String = "tester9", fullName: String = "Zebulon Quillfeather") throws {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try writeExecutable(#"""
            #!/bin/sh
            case "$1" in
            -un) echo "\#(account)" ;;
            -F) echo "\#(fullName)" ;;
            *) exec /usr/bin/id "$@" ;;
            esac
            """#, to: bin.appending(path: "id"))
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        var environment: [String: String] {
            [
                "HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": folder.path + "/", "LIB": MaskHomeTests.library.path,
            ]
        }

        /// `text` through `mask_home`.
        func mask(_ text: String, extra: String? = nil) async throws -> String {
            var environment = self.environment
            environment["TEXT"] = text
            if let extra { environment["CHECK_NO_HOME_PATHS_EXTRA_NAMES"] = extra }
            let result = try await runScript(URL(filePath: "/bin/bash"),
                                             ["-c", #"source "$LIB" && printf '%s\n' "$TEXT" | mask_home"#],
                                             environment: environment, timeout: .seconds(60))
            try #require(result.status == 0, "\(result.output)")
            return result.output.hasSuffix("\n") ? String(result.output.dropLast()) : result.output
        }
    }

    // MARK: Names

    @Test func theSurnameAloneIsHidden() async throws {
        let world = try Workspace()
        #expect(try await world.mask("Hello Quillfeather says hi") == "Hello <full name> says hi")
    }

    @Test func theGivenNameAloneIsHidden() async throws {
        let world = try Workspace()
        #expect(try await world.mask("Zebulon wrote this") == "<full name> wrote this")
    }

    @Test func theFullNameIsHiddenWhateverTheOrderOrSeparator() async throws {
        let world = try Workspace()
        #expect(try await world.mask("By Zebulon Quillfeather.") == "By <full name>.")
        #expect(try await world.mask("Quillfeather, Zebulon") == "<full name>")
        #expect(try await world.mask("ZebulonQuillfeather zebulon.quillfeather zebulon_quillfeather zebulon-quillfeather")
                == "<full name> <full name> <full name> <full name>")
    }

    @Test func aNameIsHiddenInAnyLetterCaseAndInsideAPath() async throws {
        let world = try Workspace()
        #expect(try await world.mask("QUILLFEATHER and zebulon") == "<full name> and <full name>")
        #expect(try await world.mask("see /Volumes/Quillfeather's MacBook/x") == "see /Volumes/<full name>'s MacBook/x")
    }

    @Test func aNameShorterThanSixLettersIsHiddenOnlyAsAWordOfItsOwn() async throws {
        let world = try Workspace(account: "tester9", fullName: "Orrin Pell")
        // "Pell" and "Orrin" are hidden as words, but are left alone inside "Pelletier", "compelling" and "Orrins".
        #expect(try await world.mask("Pell's Mac, compelling, Pelletier") == "<full name>'s Mac, compelling, Pelletier")
        #expect(try await world.mask("Orrin and Orrins") == "<full name> and Orrins")
        #expect(try await world.mask("/Users/pell/x") == "/Users/<full name>/x")
    }

    @Test func everyPartOfALongerNameIsHiddenToo() async throws {
        let world = try Workspace(account: "tester9", fullName: "Mary Ann Doe")
        #expect(try await world.mask("Mary, Ann and Doe") == "<full name>, <full name> and <full name>")
        #expect(try await world.mask("Doe, Ann, Mary") == "<full name>")
    }

    @Test func theAccountNameAndTheHomeFolderAreHidden() async throws {
        let world = try Workspace()
        #expect(try await world.mask("built for tester9 and TESTER9") == "built for <account name> and <account name>")
        #expect(try await world.mask("\(world.home.path)/Projects/x") == "~/Projects/x")
        #expect(try await world.mask("the folder quuxhome") == "the folder <home folder name>")
    }

    @Test func whatReplacesANameIsNotSearchedAgain() async throws {
        // "Name" is the surname here, and "name" is a word in both placeholders.
        let world = try Workspace(account: "tester9", fullName: "Full Name")
        #expect(try await world.mask("tester9 and Name and Full") == "<account name> and <full name> and <full name>")
    }

    @Test func aLineWithoutAnyNameIsUnchanged() async throws {
        let world = try Workspace()
        let line = "  ==> Building (release) 100% [12/34] \\ swift build -c release  "
        #expect(try await world.mask(line) == line)
        #expect(try await world.mask("one\ntwo Quillfeather\nthree") == "one\ntwo <full name>\nthree")
    }

    @Test func extraNamesFromTheTestHookAreHiddenToo() async throws {
        let world = try Workspace()
        #expect(try await world.mask("Gwendolyn Marchbanks, Marchbanks and Gwendolyn", extra: "Gwendolyn Marchbanks")
                == "<extra name>, <extra name> and <extra name>")
    }

    // MARK: A script's whole output

    @Test func aScriptThatMasksItsOutputPrintsNoNameAndKeepsItsStatus() async throws {
        let world = try Workspace()
        let script = world.folder.appending(path: "noisy.sh")
        try writeExecutable(#"""
        #!/bin/bash
        source "$LIB"
        mask_output_of "${BASH_SOURCE[0]}" "$@"
        echo "out: Zebulon Quillfeather lives in $HOME/work"
        echo "err: tester9 says $1" >&2
        exit 7
        """#, to: script)
        let result = try await runScript(script, ["Quillfeather"], environment: world.environment, timeout: .seconds(60))
        #expect(result.status == 7, "the script's own status comes through: \(result.output)")
        #expect(result.output.contains("out: <full name> lives in ~/work"), "\(result.output)")
        #expect(result.output.contains("err: <account name> says <full name>"), "errors are masked too: \(result.output)")
        #expect(!result.output.lowercased().contains("quillfeather") && !result.output.lowercased().contains("zebulon"))
    }

    // MARK: The checker

    /// `scripts/check-no-home-paths.sh` finds a name and prints it only as a placeholder: the whole name, a surname
    /// alone, a short one as a word, in file names and in file contents.
    @Test func theCheckerNeverPrintsANameItFoundNorAPartOfIt() async throws {
        let world = try Workspace()
        let shipped = world.folder.appending(path: "shipped")
        try FileManager.default.createDirectory(at: shipped, withIntermediateDirectories: true)
        try "Made by Marchbanks in Gwendolyn's kitchen, with Pell's help.\n".write(
            to: shipped.appending(path: "marchbanks-notes.txt"), atomically: true, encoding: .utf8)
        var environment = world.environment
        environment["CHECK_NO_HOME_PATHS_EXTRA_NAMES"] = "Gwendolyn Marchbanks\nOrrin Pell"
        let result = try await runScript(repositoryRoot.appending(path: "scripts/check-no-home-paths.sh"), [shipped.path],
                                         environment: environment, timeout: .seconds(600))
        #expect(result.status == 1, "it finds the names: \(result.output)")
        #expect(result.output.contains("a part of an extra name"), "\(result.output)")
        let lowered = result.output.lowercased()
        for name in ["marchbanks", "gwendolyn", "orrin", "pell"] {
            #expect(!lowered.contains(name), "the checker printed a part of a name it looked for: \(name)")
        }
    }

    @Test func theCheckerPassesAFolderWithoutAnyNameInIt() async throws {
        let world = try Workspace()
        let shipped = world.folder.appending(path: "shipped")
        try FileManager.default.createDirectory(at: shipped, withIntermediateDirectories: true)
        try "Nothing personal here.\n".write(to: shipped.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        var environment = world.environment
        environment["CHECK_NO_HOME_PATHS_EXTRA_NAMES"] = "Gwendolyn Marchbanks"
        let result = try await runScript(repositoryRoot.appending(path: "scripts/check-no-home-paths.sh"), [shipped.path],
                                         environment: environment, timeout: .seconds(600))
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("nothing found"), "\(result.output)")
    }

    // MARK: Who uses it

    @Test func everyScriptThatMasksOutputUsesTheOneSharedFilter() throws {
        let scripts = repositoryRoot.appending(path: "scripts")
        let names = try FileManager.default.contentsOfDirectory(atPath: scripts.path).filter { $0.hasSuffix(".sh") }
        for name in names {
            let code = try String(contentsOf: scripts.appending(path: name), encoding: .utf8).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
            #expect(!code.contains("id -F"), "\(name) keeps a masking filter of its own; use scripts/lib/mask-home.sh")
        }
        for name in ["build-app.sh", "build-dmg.sh", "smoke-update.sh", "check-no-home-paths.sh"] {
            let text = try String(contentsOf: scripts.appending(path: name), encoding: .utf8)
            #expect(text.contains("scripts/lib/mask-home.sh"), "\(name) sources the shared filter")
        }
        for name in ["build-app.sh", "build-dmg.sh"] {
            let text = try String(contentsOf: scripts.appending(path: name), encoding: .utf8)
            #expect(text.contains(#"mask_output_of "${BASH_SOURCE[0]}" "$@""#), "\(name) masks everything it prints")
        }
    }
}
