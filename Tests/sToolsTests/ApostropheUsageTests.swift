import Foundation
import Testing

// Text people read has curly apostrophes (can’t, Minecraft’s; `\u{2019}` in the source). A straight one looks out of
// place in the app's serif type, and some had crept into error lines, dialog titles and a switch's VoiceOver label. Read
// from the source, as the choice rows' test is, so a string added later with a straight apostrophe fails here with its
// file and line.

@Suite("Apostrophes in text")
struct ApostropheUsageTests {
    private static let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources", directoryHint: .isDirectory)

    /// Strings with a straight apostrophe that nobody reads in the app, by file and a piece of the string, and why.
    private static let notForReading: [(file: String, piece: String, why: String)] = [
        ("HotkeyCenter.swift", "sTools' window", "names where a key event came from, in the log"),
        ("HotkeyCenter.swift", "A key event's time", "a line for the log"),
    ]

    /// The calls that write to the log, which is for whoever reads Copy Diagnostics, not for the app's text.
    private static let logCalls = ["log.debug(", "log.info(", "log.notice(", "log.warning(", "log.error(", "log.fault("]

    // MARK: The source

    /// The text of every string literal on `line`: what is interpolated into one is left out (a placeholder stands for
    /// it), and comments and raw strings (regular expressions) are skipped.
    static func literals(in line: String) -> [String] {
        let chars = Array(line)
        var found: [String] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" { break }
            if chars[i] == "#" {
                var quote = i
                while quote < chars.count, chars[quote] == "#" { quote += 1 }
                if quote < chars.count, chars[quote] == "\"" {
                    let closing = Array("\"" + String(repeating: "#", count: quote - i))
                    var end = quote + 1
                    while end + closing.count <= chars.count, Array(chars[end..<end + closing.count]) != closing { end += 1 }
                    i = min(end + closing.count, chars.count)
                    continue
                }
            }
            if chars[i] == "\"" {
                let literal = readLiteral(chars, from: i + 1)
                found.append(literal.text)
                i = literal.next
                continue
            }
            i += 1
        }
        return found
    }

    /// The literal whose opening quote comes just before `start`, and where the text after its closing quote begins.
    private static func readLiteral(_ chars: [Character], from start: Int) -> (text: String, next: Int) {
        var text = ""
        var i = start
        while i < chars.count {
            if chars[i] == "\"" { return (text, i + 1) }
            guard chars[i] == "\\", i + 1 < chars.count else {
                text.append(chars[i])
                i += 1
                continue
            }
            switch chars[i + 1] {
            case "(":
                var depth = 1
                i += 2
                while i < chars.count, depth > 0 {
                    if chars[i] == "\"" {
                        i = readLiteral(chars, from: i + 1).next
                        continue
                    }
                    if chars[i] == "(" { depth += 1 } else if chars[i] == ")" { depth -= 1 }
                    i += 1
                }
                text.append("\u{FFFC}")
            case "u":
                var digits = ""
                i += 2
                while i < chars.count, chars[i] != "}" {
                    if chars[i] != "{" { digits.append(chars[i]) }
                    i += 1
                }
                i += 1
                text.append(UInt32(digits, radix: 16) == 0x27 ? "'" : "\u{FFFC}")
            default:
                text.append(chars[i + 1])
                i += 2
            }
        }
        return (text, i)
    }

    /// Whether a straight apostrophe in `text`, on `line` of `file`, is none that anyone reads as text.
    private static func isExcused(_ text: String, on line: String, in file: String) -> Bool {
        if logCalls.contains(where: { line.contains($0) }) { return true }
        if text.rangeOfCharacter(from: .letters) == nil { return true }
        let quotedCharacters = text.replacingOccurrences(of: "'[^\\p{L}\\p{N}\\s']'", with: "", options: .regularExpression)
        if !quotedCharacters.contains("'") { return true }
        return notForReading.contains { $0.file == (file as NSString).lastPathComponent && text.contains($0.piece) }
    }

    /// Each string literal in `lines`, a Swift file called `file`, that holds a straight apostrophe in text people read.
    static func problems(in lines: [String], file: String) -> [String] {
        var problems: [String] = []
        var inBlockComment = false
        var inMultiline = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let texts: [String]
            if inMultiline {
                if line.contains("\"\"\"") {
                    inMultiline = false
                    continue
                }
                texts = [line]
            } else {
                if inBlockComment {
                    if line.contains("*/") { inBlockComment = false }
                    continue
                }
                if trimmed.hasPrefix("/*") {
                    inBlockComment = !line.contains("*/")
                    continue
                }
                if trimmed.hasPrefix("//") { continue }
                if line.components(separatedBy: "\"\"\"").count % 2 == 0 {
                    inMultiline = true
                    continue
                }
                texts = literals(in: line)
            }
            for text in texts where text.contains("'") && !isExcused(text, on: line, in: file) {
                problems.append("\(file):\(index + 1): \(text.trimmingCharacters(in: .whitespaces))")
            }
        }
        return problems
    }

    // MARK: The tests

    @Test func noTextPeopleReadHasAStraightApostrophe() throws {
        let enumerator = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 100, "the sources were found")
        var problems: [String] = []
        for url in files {
            let path = url.path.replacingOccurrences(of: Self.sources.path + "/", with: "")
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            problems += Self.problems(in: lines, file: path)
        }
        #expect(problems.isEmpty, Comment(rawValue: "write \\u{2019} in text people read:\n" + problems.joined(separator: "\n")))
    }

    /// The check has to see what it is there for, and leave alone what isn't text.
    @Test func theCheckSeesAStraightApostropheAndNothingElse() {
        func found(_ lines: String...) -> Int { Self.problems(in: lines, file: "Sample.swift").count }
        #expect(found(#"Text("It isn't there")"#) == 1)
        #expect(found(#"Text("It isn\u{2019}t there")"#) == 0)
        #expect(found(#"Text("\(name)'s sound")"#) == 1)
        #expect(found(#"Text("\(name ?? "none")")"#) == 0)
        #expect(found(#"Text("Don\u{0027}t")"#) == 1)
        #expect(found(#"return "Can\'t""#) == 1)
        #expect(found(#"let n = 1 // it isn't text"#) == 0)
        #expect(found(#"/// Minecraft's window"#) == 0)
        #expect(found("/* It isn't", "text */") == 0)
        #expect(found(#"log.notice("it couldn't switch on")"#) == 0, "the log is not the app's text")
        #expect(found(#"throw error("Expected ',' or '}'")"#) == 0, "a character quoted as code")
        #expect(found(##"replace(#"/[U]sers/[^/\s"')\]]+"#, in: result)"##) == 0, "a regular expression")
        #expect(found(#"key("quote", shape == .jis ? ":" : "'")"#) == 0, "the key that prints an apostrophe")
        #expect(found(#"let text = """"#, "  It isn't here", #"  """"#) == 1, "a multi-line string")
        #expect(found(#"let text = """"#, "  It isn\\u{2019}t here", #"  """"#) == 0)
    }
}
