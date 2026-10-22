import AppKit
import SwiftUI
import Testing
@testable import STDesign

private let keyC: UInt16 = 8
private let keyF5: UInt16 = 96
private let keyEscape: UInt16 = 53
private let keyDelete: UInt16 = 51
private let keyForwardDelete: UInt16 = 117
private let keyReturn: UInt16 = 36
/// No key has this code, so the recorder refuses it.
private let keyUnknown: UInt16 = 999

// MARK: - Values

@Suite("STShortcut")
struct ShortcutValueTests {
    @Test func modifiersUseCarbonValues() {
        #expect(STShortcutModifiers.command.rawValue == 256)
        #expect(STShortcutModifiers.shift.rawValue == 512)
        #expect(STShortcutModifiers.option.rawValue == 2048)
        #expect(STShortcutModifiers.control.rawValue == 4096)
    }

    @Test func displayUsesMacOrder() {
        #expect(STShortcut(keyCode: keyC, modifiers: [.control, .option]).display == "⌃⌥C")
        #expect(STShortcut(keyCode: keyC, modifiers: .all).display == "⌃⌥⇧⌘C")
        #expect(STShortcut(keyCode: keyF5, modifiers: .shift).display == "⇧F5")
        #expect(STShortcut(keyCode: keyF5, modifiers: []).display == "F5")
        #expect(STShortcut(keyCode: 999, modifiers: .command).display == "⌘Key 999")
    }

    @Test func modifierBitsOutsideTheFourAreDropped() {
        #expect(STShortcut(keyCode: keyC, modifiers: STShortcutModifiers(rawValue: 0xFFFF_FFFF)).modifiers == .all)
    }

    @Test func eventFlagsConvertIgnoringCapsLockAndFunction() {
        let flags: NSEvent.ModifierFlags = [.command, .option, .capsLock, .function]
        #expect(STShortcutModifiers(flags) == [.command, .option])
        #expect(STShortcutModifiers([.control, .shift]) == [.control, .shift])
        #expect(STShortcutModifiers([]) == [])
    }

    @Test func symbolsAreEmptyWithoutModifiers() {
        #expect(STShortcutModifiers([]).symbols == "")
        #expect(STShortcutModifiers([.command, .control]).symbols == "⌃⌘")
    }

    @Test func everyFunctionKeyHasItsName() {
        let names = STShortcutKeys.functionKeyCodes.map { STShortcut(keyCode: $0, modifiers: []).display }
        #expect(names == (1...20).map { "F\($0)" })
    }

    /// The keys added so every drawn key the Key Rebinder can put a hotkey on has a name.
    @Test func newKeyNames() {
        let named: [(UInt16, String)] = [
            (10, "§"), (71, "Pad Clear"), (93, "¥"), (94, "_"), (95, "Pad ,"), (102, "英数"), (104, "かな"), (110, "Menu"),
        ]
        for (code, name) in named {
            #expect(STShortcut(keyCode: code, modifiers: []).display == name)
            #expect(STShortcut(keyCode: code, modifiers: [.control, .option]).display == "⌃⌥" + name)
            #expect(STShortcutRecorderLogic.basicRejection(STShortcut(keyCode: code, modifiers: [])) == nil, "key code \(code)")
        }
    }
}

// MARK: - Logic

@Suite("STShortcutRecorderLogic")
struct ShortcutLogicTests {
    private func outcome(_ code: UInt16, _ modifiers: STShortcutModifiers,
                         validate: (STShortcut) -> String? = STShortcutRecorderLogic.basicRejection) -> STShortcutRecorderLogic.Outcome {
        STShortcutRecorderLogic.outcome(keyCode: code, modifiers: modifiers, validate: validate)
    }

    @Test func modifiedKeyCommits() {
        #expect(outcome(keyC, [.control, .option]) == .commit(STShortcut(keyCode: keyC, modifiers: [.control, .option])))
    }

    @Test func functionKeyCommitsWithoutModifiers() {
        #expect(outcome(keyF5, []) == .commit(STShortcut(keyCode: keyF5, modifiers: [])))
    }

    /// C, Return, Space, Tab, Pad 1 and ←: any known key commits alone.
    @Test func unmodifiedKeysCommit() {
        for code: UInt16 in [keyC, keyReturn, 49, 48, 83, 123] {
            #expect(outcome(code, []) == .commit(STShortcut(keyCode: code, modifiers: [])), "key code \(code)")
        }
    }

    @Test func shiftOrOptionAloneCommits() {
        #expect(outcome(keyC, .shift) == .commit(STShortcut(keyCode: keyC, modifiers: .shift)))
        #expect(outcome(keyC, .option) == .commit(STShortcut(keyCode: keyC, modifiers: .option)))
    }

    @Test func unknownKeyIsRejected() {
        #expect(outcome(56, .command) == .reject("That key can't be used"))
        #expect(outcome(56, []) == .reject("That key can't be used"))
        #expect(outcome(999, []) == .reject("That key can't be used"))
    }

    @Test func escapeAloneCancels() {
        #expect(outcome(keyEscape, []) == .cancel)
    }

    @Test func deleteAloneClears() {
        #expect(outcome(keyDelete, []) == .clear)
        #expect(outcome(keyForwardDelete, []) == .clear)
    }

    @Test func escapeAndDeleteWithModifiersAreOrdinaryShortcuts() {
        #expect(outcome(keyEscape, .control) == .commit(STShortcut(keyCode: keyEscape, modifiers: .control)))
        #expect(outcome(keyDelete, .command) == .commit(STShortcut(keyCode: keyDelete, modifiers: .command)))
    }

    @Test func hostValidationRunsAfterBasicOnes() {
        let reject: (STShortcut) -> String? = { $0.keyCode == keyC ? "Taken" : nil }
        #expect(outcome(keyC, .command, validate: reject) == .reject("Taken"))
        #expect(outcome(keyF5, .command, validate: reject) == .commit(STShortcut(keyCode: keyF5, modifiers: .command)))
    }

    @Test func hostValidationDoesNotInterceptCancelOrClear() {
        let rejectAll: (STShortcut) -> String? = { _ in "No" }
        #expect(outcome(keyEscape, [], validate: rejectAll) == .cancel)
        #expect(outcome(keyDelete, [], validate: rejectAll) == .clear)
    }
}

@Suite("STShortcutRecorderModel")
struct ShortcutModelTests {
    private let basic = STShortcutRecorderLogic.basicRejection

    @Test func startsIdleAndIgnoresKeys() {
        var model = STShortcutRecorderModel()
        #expect(!model.isRecording)
        #expect(model.keyDown(keyCode: keyC, modifiers: .command, validate: basic) == .none)
        model.flagsChanged(.command)
        #expect(model.heldModifiers.isEmpty)
    }

    @Test func commitEndsRecording() {
        var model = STShortcutRecorderModel()
        model.begin()
        let effect = model.keyDown(keyCode: keyC, modifiers: [.control, .option], validate: basic)
        #expect(effect == .commit(STShortcut(keyCode: keyC, modifiers: [.control, .option])))
        #expect(!model.isRecording)
        #expect(model.heldModifiers.isEmpty)
    }

    @Test func rejectionKeepsRecordingWithAMessage() {
        var model = STShortcutRecorderModel()
        model.begin()
        #expect(model.keyDown(keyCode: keyUnknown, modifiers: [], validate: basic) == .none)
        #expect(model.isRecording)
        #expect(model.message == "That key can't be used")
    }

    @Test func movingModifiersClearsTheMessageAndShowsThemLive() {
        var model = STShortcutRecorderModel()
        model.begin()
        _ = model.keyDown(keyCode: keyUnknown, modifiers: [], validate: basic)
        #expect(model.message == "That key can't be used")
        model.flagsChanged([.control, .option])
        #expect(model.message == nil)
        #expect(model.heldModifiers == [.control, .option])
    }

    @Test func escapeCancelsWithoutAnEffect() {
        var model = STShortcutRecorderModel()
        model.begin()
        #expect(model.keyDown(keyCode: keyEscape, modifiers: [], validate: basic) == .none)
        #expect(!model.isRecording)
    }

    @Test func deleteClearsAndEndsRecording() {
        var model = STShortcutRecorderModel()
        model.begin()
        #expect(model.keyDown(keyCode: keyDelete, modifiers: [], validate: basic) == .clear)
        #expect(!model.isRecording)
    }

    @Test func beginResetsStaleState() {
        var model = STShortcutRecorderModel()
        model.begin()
        _ = model.keyDown(keyCode: keyUnknown, modifiers: .shift, validate: basic)
        #expect(model.message == "That key can't be used")
        model.cancel()
        model.begin()
        #expect(model.message == nil)
        #expect(model.heldModifiers.isEmpty)
    }
}

// MARK: - Monitor

@Suite("STShortcutKeyMonitor")
@MainActor
struct ShortcutMonitorTests {
    @Test func monitorExistsOnlyBetweenStartAndStop() {
        let monitor = STShortcutKeyMonitor()
        #expect(!monitor.isActive)
        monitor.start { _ in }
        #expect(monitor.isActive)
        monitor.stop()
        #expect(!monitor.isActive)
        monitor.stop()
        #expect(!monitor.isActive)
    }

    @Test func startingTwiceKeepsOneMonitor() {
        let monitor = STShortcutKeyMonitor()
        monitor.start { _ in }
        monitor.start { _ in }
        #expect(monitor.isActive)
        monitor.stop()
        #expect(!monitor.isActive)
    }
}

// MARK: - Render smoke

@MainActor
private func renderRecorder(_ shortcut: STShortcut?, size: CGSize, theme: STTheme = STTheme()) -> NSBitmapImageRep? {
    let root = STShortcutRecorder(shortcut: .constant(shortcut))
        .padding(8)
        .environment(\.stTheme, theme)
        .environment(\.stSoundPlayer, STSoundPlayer.silent)
        .frame(width: size.width, height: size.height)
        .background(STColor.background)
    let host = hostingView(root)
    host.frame = CGRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: .darkAqua)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

private func distinctColors(_ rep: NSBitmapImageRep) -> Int {
    guard let data = rep.bitmapData else { return 0 }
    let bytesPerPixel = rep.bitsPerPixel / 8
    var seen = Set<UInt32>()
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            let offset = y * rep.bytesPerRow + x * bytesPerPixel
            var key: UInt32 = 0
            for channel in 0..<min(bytesPerPixel, 4) { key = (key << 8) | UInt32(data[offset + channel]) }
            seen.insert(key)
        }
    }
    return seen.count
}

@Suite("STShortcutRecorder rendering")
@MainActor
struct ShortcutRenderTests {
    private let size = CGSize(width: 260, height: 48)

    @Test func rendersSetAndUnsetDifferently() throws {
        let set = try #require(renderRecorder(STShortcut(keyCode: keyC, modifiers: [.control, .option]), size: size))
        let unset = try #require(renderRecorder(nil, size: size))
        #expect(set.size == size)
        #expect(distinctColors(set) > 1)
        #expect(distinctColors(unset) > 1)
        #expect(set.representation(using: .png, properties: [:]) != unset.representation(using: .png, properties: [:]))
    }

    @Test func differentShortcutsRenderDifferently() throws {
        let one = try #require(renderRecorder(STShortcut(keyCode: keyC, modifiers: .command), size: size))
        let two = try #require(renderRecorder(STShortcut(keyCode: keyF5, modifiers: .shift), size: size))
        #expect(one.representation(using: .png, properties: [:]) != two.representation(using: .png, properties: [:]))
    }

    @Test func rendersUnderReducedMotionAndIncreasedContrast() throws {
        let theme = STTheme(motionMode: .reduced, increaseContrast: true)
        let rep = try #require(renderRecorder(STShortcut(keyCode: keyC, modifiers: .command), size: size, theme: theme))
        #expect(distinctColors(rep) > 1)
    }
}

// MARK: - Clicking (regression: a click focused the field but recording never started)

@MainActor
private final class ShortcutBox {
    var shortcut: STShortcut?
}

/// Clicks reach a window that isn't key only when the view accepts the first mouse; the off-screen test window
/// can't become key while another app is in front, so the host accepts it.
private final class FirstMouseHost: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private struct ClickHarness {
    let box = ShortcutBox()
    let window: NSWindow
    let host: FirstMouseHost

    init() {
        _ = NSApplication.shared
        let box = box
        let recorder = STShortcutRecorder(shortcut: Binding(get: { box.shortcut }, set: { box.shortcut = $0 }), label: "Key combination")
        host = hostingView(AnyView(VStack { recorder.frame(width: 240) }.padding(20).frame(width: 320, height: 120, alignment: .top)), as: FirstMouseHost.self)
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        // Far outside every display, so nothing ever shows on screen.
        window = NSWindow(contentRect: CGRect(x: -8000, y: -8000, width: 320, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        spin(0.3)
    }

    func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        repeat { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) } while Date() < end
    }

    /// A click at `y` points from the window's bottom.
    func click(atY y: CGFloat) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 60, y: y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.sendEvent(event)
            spin(0.1)
        }
        spin(0.2)
    }

    func press(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: keyCode)!
        NSApp.sendEvent(event)
        spin(0.2)
    }

    func close() { window.orderOut(nil) }
}

@Suite("STShortcutRecorder clicks", .serialized)
@MainActor
struct ShortcutRecorderClickTests {
    /// The recorder sits 20 pt below the top of a 120 pt window.
    private let recorderY: CGFloat = 120 - 20 - 14

    @Test func clickingRecordsTheNextShortcut() {
        let harness = ClickHarness()
        defer { harness.close() }
        harness.click(atY: recorderY)
        harness.press(keyCode: 8, modifiers: [.control, .option])
        #expect(harness.box.shortcut == STShortcut(keyCode: 8, modifiers: [.control, .option]))
    }

    @Test func clickingElsewhereCancels() {
        let harness = ClickHarness()
        defer { harness.close() }
        harness.click(atY: recorderY)
        harness.click(atY: 10)
        harness.press(keyCode: 8, modifiers: [.control, .option])
        #expect(harness.box.shortcut == nil)
    }
}
