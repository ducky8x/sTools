import AppKit
@testable import KeyRebinder
@testable import STDesign
import SwiftUI
import Testing
@testable import sTools

// Every page's title shows whole, at every text size the app offers, in the window's narrowest column and in its default
// one. At the 680 pt minimum the page column is 371 pt, and "Screen Recording", "Window Backdrop" and "Key Rebinder" ended
// in an ellipsis there. A title now shrinks to fit on one line, never below 0.7 of its size, and where that is still too
// wide it wraps between words, at about 0.8. Read off the pixels of the header as the page draws it.

/// What stands at the right end of a page's title row.
enum TitleBeside: Sendable, Equatable {
    case nothing
    case switchControl
    /// The Key Rebinder's profile menu, showing this profile (`nil`: Karabiner has none).
    case profileMenu(String?)
}

struct TitlePage: Sendable, CustomTestStringConvertible {
    let title: String
    let beside: TitleBeside

    var testDescription: String {
        if case .profileMenu(let name) = beside { return "\(title), \(name ?? "no profile")" }
        return title
    }
}

/// A profile name well past what the Key Rebinder's menu button has room for.
private let longProfile = "Minecraft speedrun practice"

/// Home, Settings and the six tools, each with what its title row holds; the Key Rebinder with Karabiner's own first
/// profile and with a long name as well as none.
private let pages: [TitlePage] = [TitlePage(title: "Home", beside: .nothing), TitlePage(title: "Settings", beside: .nothing)]
    + ToolID.allCases.map { TitlePage(title: $0.title, beside: $0.hasSwitch ? .switchControl : .profileMenu(nil)) }
    + [TitlePage(title: ToolID.keyRebinder.title, beside: .profileMenu("Default profile")),
       TitlePage(title: ToolID.keyRebinder.title, beside: .profileMenu(longProfile))]

/// The text sizes Settings offers, 90% to 130% in steps of 5.
private let textSizes = [0.9, 0.95, 1.0, 1.05, 1.1, 1.15, 1.2, 1.25, 1.3]

/// A text size and the page column it is drawn in.
struct TitleSetting: Sendable, CustomTestStringConvertible {
    let textScale: Double
    let column: CGFloat

    var testDescription: String { "\(Int((textScale * 100).rounded()))%, \(Int(column)) pt" }
}

/// Every text size Settings offers, in the page column of the window's 680 pt minimum (less its 237 pt sidebar and the
/// page's 36 pt margins) and in the default 760 pt window's.
private let settings: [TitleSetting] = [371, 451].flatMap { column in
    textSizes.map { TitleSetting(textScale: $0, column: column) }
}

/// One line of a title as drawn: the pixel columns and rows its ink covers, at 2 pixels to the point.
struct TitleInk {
    let columns: Range<Int>
    let rows: Range<Int>
}

@MainActor
@Suite("Page titles")
struct PageTitleFitTests {
    private func theme(_ textScale: Double) -> STTheme {
        _ = STFont.register()
        return STTheme(textScale: textScale, motionMode: .reduced)
    }

    /// What stands beside `page`'s title, and the harness it needs while it is drawn.
    private func standingBeside(_ page: TitlePage) async throws -> (view: AnyView, harness: Harness?) {
        switch page.beside {
        case .nothing:
            return (AnyView(EmptyView()), nil)
        case .switchControl:
            return (AnyView(STSwitch(isOn: .constant(false), label: page.title)), nil)
        case .profileMenu(let profile):
            let harness = Harness(withKeyRebinder: true)
            let controller = try #require(harness.model.keyRebinder)
            if let profile {
                try Data(#"{ "profiles": [{ "name": "\#(profile)", "selected": true }] }"#.utf8).write(to: harness.karabinerConfigURL)
                await controller.reloadConfig()
                #expect(controller.currentProfile == profile)
            }
            return (AnyView(KeyRebinderProfileMenu(controller: controller)), harness)
        }
    }

    /// `view` `width` wide and as tall as it asks to be, as a bitmap at 2 pixels to the point, in the dark appearance.
    private func render(_ view: AnyView, width: CGFloat) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.appearance = NSAppearance(named: .darkAqua)
        let size = CGSize(width: width, height: ceil(host.fittingSize.height))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The header as the page draws it, `column` wide. Reduce animations is on, so the gilt rule is there whole.
    private func header(_ title: String, beside: AnyView, column: CGFloat, textScale: Double) -> NSBitmapImageRep {
        render(
            AnyView(
                STPageHeader(title: title, tagline: "A tagline.") { beside }
                    .environment(\.stTheme, theme(textScale))
                    .environment(\.stSoundPlayer, STSoundPlayer.silent)
                    .background(STColor.background)),
            width: column)
    }

    /// `title` on one line at full size, in whole points.
    private func lineWidth(_ title: String, textScale: Double) -> CGFloat {
        NSHostingView(rootView: Text(title).stStyle(.pageTitle).fixedSize().environment(\.stTheme, theme(textScale))).fittingSize.width
    }

    /// The lines of ink in the title's part of the row, above the gilt rule: the first row lit across nearly the whole width.
    /// `limit` is the pixel column where what stands beside the title begins.
    private func inkLines(in rep: NSBitmapImageRep, before limit: Int) -> [TitleInk] {
        guard let data = rep.bitmapData else { return [] }
        let width = rep.pixelsWide
        func isLit(_ row: UnsafeMutablePointer<UInt8>, _ x: Int) -> Bool {
            max(row[x * 4], row[x * 4 + 1], row[x * 4 + 2]) > 60
        }
        var ruleRow = rep.pixelsHigh
        for y in 0..<rep.pixelsHigh {
            let row = data + y * rep.bytesPerRow
            var lit = 0
            var sampled = 0
            for x in stride(from: 0, to: width, by: 4) {
                if isLit(row, x) { lit += 1 }
                sampled += 1
            }
            if lit * 10 >= sampled * 9 {
                ruleRow = y
                break
            }
        }
        var lines: [TitleInk] = []
        var first: Int?
        var left = Int.max
        var right = -1
        for y in 0...ruleRow {
            var rowLeft = Int.max
            var rowRight = -1
            if y < ruleRow {
                let row = data + y * rep.bytesPerRow
                for x in 0..<min(limit, width) where isLit(row, x) {
                    rowLeft = min(rowLeft, x)
                    rowRight = max(rowRight, x)
                }
            }
            if rowRight >= 0 {
                if first == nil { first = y }
                left = min(left, rowLeft)
                right = max(right, rowRight)
            } else if let start = first {
                lines.append(TitleInk(columns: left..<(right + 1), rows: start..<y))
                first = nil
                left = Int.max
                right = -1
            }
        }
        return lines
    }

    private static var references: [String: TitleInk] = [:]

    /// `text` as a page title at full size, on one line, with nothing in its way.
    private func reference(_ text: String, textScale: Double) -> TitleInk? {
        let key = "\(text)|\(textScale)"
        if let known = Self.references[key] { return known }
        let rep = header(text, beside: AnyView(EmptyView()), column: 600, textScale: textScale)
        let lines = inkLines(in: rep, before: rep.pixelsWide)
        guard lines.count == 1 else { return nil }
        Self.references[key] = lines[0]
        return lines[0]
    }

    @Test(arguments: pages, settings)
    func aTitleShowsWholeAtEveryTextSize(page: TitlePage, setting: TitleSetting) async throws {
        let (textScale, column) = (setting.textScale, setting.column)
        let (beside, harness) = try await standingBeside(page)
        defer { withExtendedLifetime(harness) {} }
        let besideWidth = NSHostingView(rootView: beside.environment(\.stTheme, theme(textScale))).fittingSize.width
        // The row puts 16 pt between the title and the spacer, which is 16 pt at least, and 16 pt between the spacer and
        // what stands beside the title, if anything does.
        let room = column - besideWidth - (besideWidth > 0 ? 48 : 32)
        let share = Double(room / lineWidth(page.title, textScale: textScale))
        let rep = header(page.title, beside: beside, column: column, textScale: textScale)
        let lines = inkLines(in: rep, before: Int((column - besideWidth) * 2))
        let words = page.title.split(separator: " ").map(String.init)
        let context = "\(page.testDescription) at \(textScale)x in \(column) pt"

        // One line, or one line to a word: a title never breaks inside a word, or runs onto a third line.
        #expect(lines.count == 1 || lines.count == words.count, "\(context): \(lines.count) lines of ink for \(words.count) words")
        guard lines.count == 1 || lines.count == words.count else { return }
        if lines.count == 1 {
            // On one line it is as wide as its room asks, down to 0.7 of its size and no lower: a title in less room than
            // that would be cut off with an ellipsis, and one in more would not have shrunk. A line is only chosen with
            // room to spare over 0.7, so a line in less than that is a title that was to wrap and fell back to one, cut off.
            #expect(share >= 0.7 * STTitleFit.slack - 0.005, "\(context): one line in \(share) of the title's width")
            let full = try #require(reference(page.title, textScale: textScale), "\(page.title) in one line at full size")
            let across = Double(lines[0].columns.count) / Double(full.columns.count)
            #expect(across >= 0.68, "\(context): the title is \(across) of its width")
            #expect(abs(across - min(1, share)) <= 0.02, "\(context): the title is \(across) as wide, in room for \(min(1, share))")
        } else {
            // On two lines it was too wide for one at 0.7. Each word is whole and between 0.7 and 0.85 of its size: aimed at
            // 0.8, and a little under where a long word needs the room, but never under 0.7 and never at full size.
            #expect(share < 0.7 * STTitleFit.slack + 0.005, "\(context): wrapped, though one line fits in \(share) of the title's width")
            for (line, word) in zip(lines, words) {
                let full = try #require(reference(word, textScale: textScale), "\(word) in one line at full size")
                let across = Double(line.columns.count) / Double(full.columns.count)
                #expect(across >= 0.68, "\(context): \(word) is \(across) of its width")
                #expect(across <= 0.86, "\(context): \(word) is \(across) of its width, not 0.8")
            }
        }
        let inkRight = Double(lines.map(\.columns.upperBound).max() ?? 0) / 2
        #expect(inkRight <= Double(room) + 1, "\(context): the title ends \(inkRight - Double(room)) pt past its room")
    }

    /// At the least room one line is chosen for, a title is on one line and whole: the room a title needs at 0.7 of its size is a
    /// little more than 0.7 of its width, by an amount that changes with the text size, and a line a hair short of that is cut
    /// off with an ellipsis.
    @Test(arguments: ["Crosshair", "Timer Overlay", "NBB Overlay", "Screen Recording", "Window Backdrop", "Key Rebinder"], textSizes)
    func aTitleInTheLeastRoomForOneLineIsNotCutOff(title: String, textScale: Double) throws {
        let titleWidth = lineWidth(title, textScale: textScale)
        let room = titleWidth * STTitleFit.floor * STTitleFit.slack
        let rep = render(AnyView(STPageTitle(title).environment(\.stTheme, theme(textScale)).background(STColor.background)), width: room)
        let lines = inkLines(in: rep, before: rep.pixelsWide)
        #expect(lines.count == 1, "\(title) at \(textScale)x in \(room) pt: \(lines.count) lines")
        guard lines.count == 1 else { return }
        let full = try #require(reference(title, textScale: textScale))
        let across = Double(lines[0].columns.count) / Double(full.columns.count)
        #expect(abs(across - Double(room / titleWidth)) <= 0.02, "\(title) at \(textScale)x: \(across) as wide, in room for \(room / titleWidth)")
    }

    /// Wherever a title has to wrap, it wraps: two lines, a word to a line, each whole. At a size too tight for the two lines
    /// the title would fall back to one cut-off line, so this goes through the rooms from the least that wraps down to
    /// the one the longest word fills at 0.7.
    @Test(arguments: ["Screen Recording", "Window Backdrop", "Key Rebinder"], textSizes)
    func aTitleThatMustWrapWrapsInEveryRoomItCan(title: String, textScale: Double) throws {
        let titleWidth = lineWidth(title, textScale: textScale)
        let words = title.split(separator: " ").map(String.init)
        let wordInk = try words.map { try #require(reference($0, textScale: textScale)).columns.count }
        let view = AnyView(STPageTitle(title).environment(\.stTheme, theme(textScale)).background(STColor.background))
        for share in [0.71, 0.69, 0.65, 0.6, 0.55, 0.5] {
            let room = titleWidth * share
            // The longest word at 0.7 of its size, in points, has to fit: narrower than that is no room for any title.
            guard Double(wordInk.max() ?? 0) / 2 * 0.7 <= Double(room) - 2 else { continue }
            let rep = render(view, width: room)
            let lines = inkLines(in: rep, before: rep.pixelsWide)
            let context = "\(title) at \(textScale)x in \(room) pt"
            #expect(lines.count == words.count, "\(context): \(lines.count) lines of ink")
            guard lines.count == words.count else { continue }
            for ((line, word), ink) in zip(zip(lines, words), wordInk) {
                let across = Double(line.columns.count) / Double(ink)
                #expect(across >= 0.68, "\(context): \(word) is \(across) of its width")
            }
        }
    }

    /// The Key Rebinder's profile button: "Default profile", the name Karabiner starts with, is whole at every text size, and a
    /// longer name stops at the button's cap, which grows with the text size.
    @Test(arguments: textSizes)
    func theProfileButtonStopsAtItsCap(textScale: Double) async throws {
        let appearance = theme(textScale)
        func button(_ profile: String) async throws -> CGFloat {
            let (menu, harness) = try await standingBeside(TitlePage(title: "Key Rebinder", beside: .profileMenu(profile)))
            return withExtendedLifetime(harness) { NSHostingView(rootView: menu.environment(\.stTheme, appearance)).fittingSize.width }
        }
        func label(_ title: String) -> CGFloat {
            NSHostingView(rootView: STMenuLabel(title).environment(\.stTheme, appearance)).fittingSize.width
        }
        let cap = (KeyRebinderProfileMenu.widestButton * textScale).rounded(.up)
        let defaultButton = try await button("Default profile")
        #expect(defaultButton == label("Default profile"), "Default profile is \(defaultButton) pt wide, and as a label \(label("Default profile")) pt")
        #expect(defaultButton <= cap, "Default profile is \(defaultButton) pt wide at \(textScale)x, in a cap of \(cap) pt")
        let longButton = try await button(longProfile)
        #expect(label(longProfile) > cap + 20, "the long name is not long enough to test the cap")
        #expect(abs(longButton - cap) <= 1, "\(longProfile) is \(longButton) pt wide at \(textScale)x, in a cap of \(cap) pt")
    }
}
