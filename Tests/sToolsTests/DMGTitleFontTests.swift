import Foundation
import Testing

/// The DMG window's title (`scripts/dmg-window.swift`) is set in Bodoni Moda the way the app sets its titles
/// (`STFont.display`: weight 400, optical size 96), not in DM Serif Display, which is kept for the Prologue's greeting.
@Suite("DMG title font")
struct DMGTitleFontTests {
    private static let window = repositoryRoot.appending(path: "scripts/dmg-window.swift")

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    /// The two numbers after `wghtAxisTag:` and `opszAxisTag:` in the app's `STFont.bodoniModaDisplay`.
    private func appAxes() throws -> (weight: Int, opticalSize: Int) {
        let source = try text(repositoryRoot.appending(path: "Sources/STDesign/STFont.swift"))
        let pattern = try NSRegularExpression(pattern: #"\[wghtAxisTag: (\d+), opszAxisTag: (\d+)\]"#)
        let match = try #require(pattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)))
        func number(_ group: Int) throws -> Int {
            let range = try #require(Range(match.range(at: group), in: source))
            return try #require(Int(source[range]))
        }
        return (try number(1), try number(2))
    }

    @Test func theTitleUsesBodoniModaWithTheAxesTheAppUses() throws {
        let source = try text(Self.window)
        let axes = try appAxes()
        let display = try #require(source.range(of: "static func display(_ size: CGFloat) throws -> CTFont {"))
        let body = String(source[display.lowerBound...].prefix(400))
        #expect(body.contains(#""BodoniModa[opsz,wght].ttf""#), "the title font is Bodoni Moda: \(body)")
        #expect(body.contains(#""wght": \#(axes.weight)"#) && body.contains(#""opsz": \#(axes.opticalSize)"#),
                "the same weight and optical size as STFont.display: \(body)")
        #expect(!source.contains("DMSerifDisplay"), "the window no longer draws anything in DM Serif Display")
    }

    @Test func theFontFileTheWindowLoadsIsBundledWithTheApp() throws {
        let file = repositoryRoot.appending(path: "Sources/STDesign/Resources/Fonts/BodoniModa[opsz,wght].ttf")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// Compiles the script and draws the background, as `scripts/build-dmg.sh` does: it must still fit its text.
    @Test func theBackgroundStillDrawsAndItsTextStillFits() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sTools-dmg-title-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = ["HOME": folder.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": folder.path + "/",
                           "DEVELOPER_DIR": "/Applications/Xcode-beta.app/Contents/Developer"]
        let tool = folder.appending(path: "dmg-window")
        let compiled = try await runScript(URL(filePath: "/usr/bin/xcrun"), ["swiftc", "-o", tool.path, Self.window.path],
                                           environment: environment, timeout: .seconds(600))
        try #require(compiled.status == 0, "\(compiled.output)")
        let output = folder.appending(path: "background")
        let drawn = try await runScript(tool, ["background", output.path, "--version", "0.2.0"],
                                        environment: environment, timeout: .seconds(120))
        #expect(drawn.status == 0, "\(drawn.output)")
        #expect(drawn.output.contains("text fits"), "\(drawn.output)")
        for name in ["background.png", "background@2x.png", "background.tiff"] {
            let size = (try? FileManager.default.attributesOfItem(atPath: output.appending(path: name).path)[.size] as? Int) ?? 0
            #expect(size > 10_000, "\(name) was drawn")
        }
    }
}
