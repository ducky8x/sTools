import Foundation
import Testing

// A segmented control never gets narrower than its words, so in a settings row it must be in an `STChoiceRow`, which puts
// the options under the label when the column is too narrow for both (spec 3.6, revisions 44 and 58). In an `STSettingsRow`
// the options wrap to a second line or break inside a word at the window's 680 pt minimum: the Timer Overlay's Look,
// Crosshair's Image anchor, Screen Recording's Split into files every and others did. Read from the source, as the Timer
// Overlay's hard limits are, so a choice added later in the wrong row fails here.

@Suite("Choice rows")
struct ChoiceRowUsageTests {
    private static let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources", directoryHint: .isDirectory)

    /// How far above a segmented control its row's opening line can be.
    private static let reach = 10

    /// Segmented controls that sit in no settings row on purpose, by file, and why.
    private static let outsideARow: [String: String] = [
        "LayoutChooser.swift": "two controls side by side in the first-visit plate, with no row label",
        "KeyRebinderProfileMenu.swift": "in the New Profile sheet, which has a width of its own",
    ]

    /// Settings rows that hold a segmented control beside something else, by label, and why they stay `STSettingsRow`.
    private static let sharedRows: [String: String] = [
        "Keyboard": "two short controls stacked in one row",
        "Quality": "a slider beside the control while Manual is chosen",
    ]

    /// The text of every Swift file under `Sources`, by path relative to it.
    private static func swiftFiles() throws -> [(path: String, lines: [String])] {
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        return try enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.map { url in
            let path = url.path.replacingOccurrences(of: sources.path + "/", with: "")
            return (path, try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n"))
        }
    }

    /// The label of the row opened on `line`: `STSettingsRow("Look", …` is ("STSettingsRow", "Look").
    private static func row(opening line: String) -> (kind: String, label: String)? {
        for kind in ["STSettingsRow", "STChoiceRow"] {
            guard let start = line.range(of: "\(kind)(\"") else { continue }
            let label = line[start.upperBound...].prefix { $0 != "\"" }
            return (kind, String(label))
        }
        return nil
    }

    @Test func everySegmentedControlSitsInAChoiceRow() throws {
        let files = try Self.swiftFiles().filter { !$0.path.hasSuffix("STSegmented.swift") }
        #expect(files.count > 100, "the sources were found")
        var problems: [String] = []
        var checked = 0
        for file in files {
            let name = (file.path as NSString).lastPathComponent
            for (index, line) in file.lines.enumerated() where line.contains("STSegmented(") && !line.contains("///") {
                checked += 1
                let above = file.lines[max(0, index - Self.reach)...index].reversed()
                guard let opener = above.lazy.compactMap({ Self.row(opening: $0) }).first else {
                    if Self.outsideARow[name] == nil { problems.append("\(file.path):\(index + 1): a segmented control in no row") }
                    continue
                }
                if opener.kind == "STSettingsRow", Self.sharedRows[opener.label] == nil {
                    problems.append("\(file.path):\(index + 1): a segmented control in STSettingsRow(\"\(opener.label)\"), "
                        + "which should be STChoiceRow")
                }
            }
        }
        #expect(checked > 30, "found the segmented controls")
        #expect(problems.isEmpty, Comment(rawValue: "\n" + problems.joined(separator: "\n")))
    }

    @Test func theExceptionsAreStillTrue() throws {
        let files = try Self.swiftFiles()
        for name in Self.outsideARow.keys {
            let file = try #require(files.first { ($0.path as NSString).lastPathComponent == name }, "\(name) still exists")
            #expect(file.lines.contains { $0.contains("STSegmented(") }, "\(name) still has a segmented control")
        }
        for label in Self.sharedRows.keys {
            #expect(files.contains { $0.lines.contains { $0.contains("STSettingsRow(\"\(label)\"") } }, "a row named \(label) still exists")
        }
    }
}
