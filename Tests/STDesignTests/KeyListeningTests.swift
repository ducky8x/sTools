import AppKit
import Observation
import SwiftUI
import Testing
@testable import STDesign

private let keyC: UInt16 = 8
private let keyEscape: UInt16 = 53
private let keyDelete: UInt16 = 51

@MainActor
@Observable
private final class ListeningBox {
    var isListening = false
    var activity: STKeyCapActivity = .idle
    var keys: [STShortcut?] = []
}

/// A label that listens for a key while the box says so, in a window far off every display.
@MainActor
private struct ListeningHarness {
    let box = ListeningBox()
    let window: NSWindow

    init(refusing refusal: String? = nil) {
        _ = NSApplication.shared
        let box = box
        let label = Text("Speedrun")
            .stListensForKey(Binding(get: { box.isListening }, set: { box.isListening = $0 }),
                             activity: Binding(get: { box.activity }, set: { box.activity = $0 }),
                             validate: { refusal == nil || $0.modifiers.isEmpty ? nil : refusal },
                             onKey: { box.keys.append($0) })
        let host = hostingView(AnyView(label.padding(20).frame(width: 240, height: 80, alignment: .topLeading)
            .environment(\.stSoundPlayer, STSoundPlayer.silent)))
        host.frame = CGRect(x: 0, y: 0, width: 240, height: 80)
        window = NSWindow(contentRect: CGRect(x: -8000, y: -8000, width: 240, height: 80), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        spin(0.2)
    }

    func spin(_ seconds: TimeInterval) {
        let end = SuspendingClock.now.advanced(by: .seconds(seconds))
        repeat { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) } while SuspendingClock.now < end
    }

    func listen() {
        box.isListening = true
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

    func click() {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 200, y: 10), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.sendEvent(event)
            spin(0.1)
        }
    }

    func close() {
        box.isListening = false
        spin(0.1)
        window.orderOut(nil)
    }
}

/// A view that records a key in place but starts listening from elsewhere (a menu's Set Key…) keeps a key cap's rules.
@Suite("stListensForKey", .serialized)
@MainActor
struct KeyListeningTests {
    @Test func itListensOnlyWhileAskedAndHandsOnTheKey() {
        let harness = ListeningHarness()
        defer { harness.close() }
        #expect(!STKeyCapture.isCapturing)
        harness.press(keyCode: keyC, modifiers: [.control])
        #expect(harness.box.keys.isEmpty, "nothing listens until asked")

        harness.listen()
        #expect(harness.box.activity == .listening)
        #expect(STKeyCapture.isCapturing, "hotkeys step aside while it listens")
        harness.press(keyCode: keyC, modifiers: [.control, .option])
        #expect(harness.box.keys == [STShortcut(keyCode: keyC, modifiers: [.control, .option])])
        #expect(!harness.box.isListening, "one key, then it stops")
        #expect(harness.box.activity == .idle)
        #expect(!STKeyCapture.isCapturing)
    }

    @Test func escCancelsAndDeleteClears() {
        let harness = ListeningHarness()
        defer { harness.close() }
        harness.listen()
        harness.press(keyCode: keyEscape, modifiers: [])
        #expect(harness.box.keys.isEmpty)
        #expect(!harness.box.isListening)
        harness.listen()
        harness.press(keyCode: keyDelete, modifiers: [])
        #expect(harness.box.keys == [nil])
        #expect(!harness.box.isListening)
    }

    /// A refused key keeps it listening and says why, as a key cap does.
    @Test func aRefusedKeySaysWhyAndKeepsListening() {
        let harness = ListeningHarness(refusing: "Reserved: Quit")
        defer { harness.close() }
        harness.listen()
        harness.press(keyCode: keyC, modifiers: .command)
        #expect(harness.box.activity == .refused("Reserved: Quit"))
        #expect(harness.box.isListening)
        #expect(harness.box.keys.isEmpty)
        harness.press(keyCode: keyC, modifiers: [])
        #expect(harness.box.keys == [STShortcut(keyCode: keyC, modifiers: [])])
    }

    /// A click anywhere stops it, and so does being told to stop.
    @Test func aClickOrBeingToldStopsIt() {
        let harness = ListeningHarness()
        defer { harness.close() }
        harness.listen()
        harness.click()
        #expect(!harness.box.isListening)
        #expect(harness.box.activity == .idle)
        harness.listen()
        harness.box.isListening = false
        harness.spin(0.2)
        #expect(!STKeyCapture.isCapturing)
        harness.press(keyCode: keyC, modifiers: [.control])
        #expect(harness.box.keys.isEmpty)
    }
}
