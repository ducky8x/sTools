import AppKit
import SwiftUI
import Testing
@testable import STDesign

private let keyC: UInt16 = 8
private let key1: UInt16 = 18
private let keyEscape: UInt16 = 53
private let keyDelete: UInt16 = 51
private let commandOne = STShortcut(keyCode: key1, modifiers: .command)

// MARK: - What it reports

@Suite("STKeyCapRecorder activity")
struct KeyCapActivityTests {
    @Test func itReportsListeningAndRefusalsAndIdlesAgain() {
        var model = STShortcutRecorderModel()
        #expect(STKeyCapActivity(model) == .idle)
        model.begin()
        #expect(STKeyCapActivity(model) == .listening)
        _ = model.keyDown(keyCode: keyC, modifiers: .command, validate: { _ in "Already used by another hotkey" })
        #expect(STKeyCapActivity(model) == .refused("Already used by another hotkey"))
        model.flagsChanged(.command)
        #expect(STKeyCapActivity(model) == .listening, "a new modifier clears the refusal")
        _ = model.keyDown(keyCode: keyEscape, modifiers: [], validate: { _ in nil })
        #expect(STKeyCapActivity(model) == .idle)
    }
}

// MARK: - How it looks

@MainActor
private func renderCap(_ shortcut: STShortcut?, isDimmed: Bool = false, problem: String? = nil, revealsClear: Bool = true,
                       width: CGFloat = 140, theme: STTheme = STTheme()) -> Data? {
    let size = CGSize(width: width, height: 40)
    let root = STKeyCapRecorder(shortcut: .constant(shortcut), label: "Crosshair hotkey", isDimmed: isDimmed, problem: problem,
                                revealsClear: revealsClear)
        .padding(8)
        .frame(width: size.width, height: size.height, alignment: .leading)
        .environment(\.stTheme, theme)
        .environment(\.stSoundPlayer, STSoundPlayer.silent)
        .background(STColor.background)
    let host = hostingView(root)
    host.frame = CGRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: .darkAqua)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep.representation(using: .png, properties: [:])
}

@Suite("STKeyCapRecorder rendering")
@MainActor
struct KeyCapRenderTests {
    /// A key, no key (Add Key), a key while hotkeys are off and a key that doesn't work each look different.
    @Test func everyStateLooksDifferent() throws {
        let set = try #require(renderCap(commandOne))
        let unset = try #require(renderCap(nil))
        let dimmed = try #require(renderCap(commandOne, isDimmed: true))
        let broken = try #require(renderCap(commandOne, problem: "Refused by macOS"))
        #expect(Set([set, unset, dimmed, broken]).count == 4)
    }

    /// Beside a tile that isn't hovered the × waits for the pointer; without a key there is nothing to clear either way.
    @Test func theClearControlCanWaitForThePointer() throws {
        let theme = STTheme(motionMode: .reduced)
        #expect(try #require(renderCap(commandOne, revealsClear: false, theme: theme))
            != (try #require(renderCap(commandOne, revealsClear: true, theme: theme))))
        #expect(try #require(renderCap(nil, revealsClear: false, theme: theme))
            == (try #require(renderCap(nil, revealsClear: true, theme: theme))))
    }

    /// Where there's no room for Add Key the empty cap keeps its plus at the cap's least width (34 pt), rather than
    /// stretching to its room with the words cut off.
    @Test func anEmptyCapShortensInsteadOfCuttingOff() throws {
        let png = try #require(renderCap(nil, width: 64, theme: STTheme(motionMode: .reduced)))
        let rep = try #require(NSBitmapImageRep(data: png))
        let scale = rep.pixelsWide / 64
        // The window's last column is the background; everything right of the 8 pt padding, the 34 pt cap and a little
        // to spare matches it.
        let background = rep.colorAt(x: rep.pixelsWide - 1, y: 0)
        var inked = 0
        for x in (8 + 34 + 4) * scale..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where rep.colorAt(x: x, y: y) != background {
                inked += 1
            }
        }
        #expect(inked == 0, "\(inked) pixels past the cap")
    }

    @Test func rendersUnderReducedMotionAndIncreasedContrast() throws {
        let theme = STTheme(motionMode: .reduced, increaseContrast: true)
        #expect(try #require(renderCap(commandOne, theme: theme)) != (try #require(renderCap(nil, theme: theme))))
    }

    /// Offered less room than its key needs, beside controls that take the room first, a cap keeps its whole key
    /// rather than shrinking to an ellipsis.
    @Test func aSqueezedCapKeepsItsWholeKey() {
        final class Width { var value: CGFloat = 0 }
        let width = Width()
        let long = STShortcut(keyCode: 111, modifiers: [.control, .option, .shift])
        let row = HStack(spacing: 8) {
            // The × waits for the pointer, so the width is the cap's alone.
            STKeyCapRecorder(shortcut: .constant(long), label: "Next profile hotkey", revealsClear: false)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width.value = $0 }
            Color.clear.frame(maxWidth: .infinity, maxHeight: 10).layoutPriority(1)
        }
        .environment(\.stSoundPlayer, STSoundPlayer.silent)
        let host = hostingView(row.frame(width: 120))
        host.frame = CGRect(x: 0, y: 0, width: 120, height: 40)
        host.layoutSubtreeIfNeeded()
        // ⌃⌥⇧F12 is far wider than the cap's least width of 34 pt.
        #expect(width.value > 60, "\(width.value) pt")
    }
}

// MARK: - Clicking and keys

@MainActor
private final class Box {
    var shortcut: STShortcut?
    var activity: STKeyCapActivity = .idle
}

/// Clicks reach a window that isn't key only when the view accepts the first mouse; the off-screen test window can't
/// become key while another app is in front, so the host accepts it.
private final class FirstMouseHost: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private struct CapHarness {
    let box = Box()
    let window: NSWindow
    let host: FirstMouseHost

    /// The cap sits 20 pt in from the window's top-left corner, in a window 120 pt tall.
    init(_ shortcut: STShortcut?, refusing refusal: String? = nil) {
        _ = NSApplication.shared
        let box = box
        box.shortcut = shortcut
        let cap = STKeyCapRecorder(
            shortcut: Binding(get: { box.shortcut }, set: { box.shortcut = $0 }), label: "Crosshair hotkey",
            activity: Binding(get: { box.activity }, set: { box.activity = $0 }),
            validate: { refusal == nil || $0.modifiers.isEmpty ? nil : refusal })
        host = hostingView(
            AnyView(cap.padding(20).frame(width: 320, height: 120, alignment: .topLeading)
                .environment(\.stSoundPlayer, STSoundPlayer.silent)),
            as: FirstMouseHost.self)
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        // Far outside every display, so nothing ever shows on screen.
        window = NSWindow(contentRect: CGRect(x: -8000, y: -8000, width: 320, height: 120), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        spin(0.3)
    }

    func spin(_ seconds: TimeInterval) {
        let end = SuspendingClock.now.advanced(by: .seconds(seconds))
        repeat { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) } while SuspendingClock.now < end
    }

    /// A click `x` points from the window's left edge, on the cap's row.
    func click(atX x: CGFloat, y: CGFloat = 120 - 20 - 12) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.sendEvent(event)
            spin(0.1)
        }
        spin(0.2)
    }

    func press(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c",
            isARepeat: false, keyCode: keyCode)!
        NSApp.sendEvent(event)
        spin(0.2)
    }

    func close() { window.orderOut(nil) }
}

@Suite("STKeyCapRecorder clicks", .serialized)
@MainActor
struct KeyCapClickTests {
    /// The cap's middle, 20 pt in plus half its narrowest width.
    private let capX: CGFloat = 20 + 17

    @Test func clickingTheCapRecordsTheNextKeyInPlace() {
        let harness = CapHarness(nil)
        defer { harness.close() }
        harness.click(atX: capX)
        #expect(harness.box.activity == .listening)
        harness.press(keyCode: keyC, modifiers: [.control, .option])
        #expect(harness.box.shortcut == STShortcut(keyCode: keyC, modifiers: [.control, .option]))
        #expect(harness.box.activity == .idle)
    }

    @Test func escCancelsAndDeleteClears() {
        let harness = CapHarness(commandOne)
        defer { harness.close() }
        harness.click(atX: capX)
        harness.press(keyCode: keyEscape, modifiers: [])
        #expect(harness.box.shortcut == commandOne)
        #expect(harness.box.activity == .idle)
        harness.click(atX: capX)
        harness.press(keyCode: keyDelete, modifiers: [])
        #expect(harness.box.shortcut == nil)
    }

    /// A refused key keeps the cap listening and says why; the next key that passes commits.
    @Test func aRefusedKeySaysWhyAndKeepsListening() {
        let harness = CapHarness(nil, refusing: "Reserved: Quit")
        defer { harness.close() }
        harness.click(atX: capX)
        harness.press(keyCode: keyC, modifiers: .command)
        #expect(harness.box.activity == .refused("Reserved: Quit"))
        #expect(harness.box.shortcut == nil)
        harness.press(keyCode: keyC, modifiers: [])
        #expect(harness.box.shortcut == STShortcut(keyCode: keyC, modifiers: []))
    }

    /// The × beside a set key clears it without recording.
    @Test func theClearControlRemovesTheKey() {
        let harness = CapHarness(commandOne)
        defer { harness.close() }
        // Just right of the cap: 20 pt in, the cap's 34 pt, a 4 pt gap and half the 18 pt control.
        harness.click(atX: 20 + 34 + 4 + 9)
        #expect(harness.box.shortcut == nil)
        #expect(harness.box.activity == .idle)
    }
}
