import AppKit
import Observation
import SwiftUI
import Testing
@testable import STDesign

/// Clicks reach a window that isn't key only when the view accepts the first mouse; the off-screen test window can't
/// become key while another app is in front, so the host accepts it.
private final class FirstMouseHost: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Two choices, one above the other, and where each one sits in the window, as the views report it.
@MainActor
@Observable
private final class Choices {
    var upper = 0
    var lower = 0
    /// Each control's frame in the hosting view, top-left origin.
    var upperFrame: CGRect = .zero
    var lowerFrame: CGRect = .zero
}

private var options: [STSegmentedOption<Int>] { [STSegmentedOption(0, "One"), STSegmentedOption(1, "Two"), STSegmentedOption(2, "Three")] }

/// Two `STSegmented` controls in a window far outside every display, driven by real click and key events sent to the
/// window, so nothing ever shows on screen or reaches another app.
@MainActor
private final class SegmentedWindow {
    let choices = Choices()
    let window: NSWindow
    let host: FirstMouseHost
    private let size = CGSize(width: 360, height: 140)

    init() {
        _ = NSApplication.shared
        let choices = choices
        let root = VStack(alignment: .leading, spacing: 24) {
            STSegmented(selection: Binding(get: { choices.upper }, set: { choices.upper = $0 }), options: options)
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { choices.upperFrame = proxy.frame(in: .global) }
                })
            STSegmented(selection: Binding(get: { choices.lower }, set: { choices.lower = $0 }), options: options)
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { choices.lowerFrame = proxy.frame(in: .global) }
                })
        }
        .padding(20)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(STColor.background)
        .environment(\.stSoundPlayer, STSoundPlayer.silent)
        host = hostingView(AnyView(root), as: FirstMouseHost.self)
        host.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -9000, y: -9000), size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        spin(0.4)
    }

    func spin(_ seconds: TimeInterval) {
        let end = SuspendingClock.now.advanced(by: .seconds(seconds))
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        } while SuspendingClock.now < end
    }

    /// A click `x` points in from the left edge of `frame` (a control's, top-left origin), halfway down it.
    func click(_ frame: CGRect, x: CGFloat) {
        let point = NSPoint(x: frame.minX + x, y: size.height - frame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
            spin(0.1)
        }
        spin(0.3)
    }

    /// The right arrow key, pressed in the window: it goes to whatever has keyboard focus.
    func pressRightArrow() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}",
            isARepeat: false, keyCode: 124)!
        window.sendEvent(event)
        spin(0.3)
    }

    func close() { window.orderOut(nil) }
}

/// Arrow keys move an `STSegmented`'s selection once it has keyboard focus, and a click anywhere on it gives it that:
/// with macOS's keyboard navigation off (its default), Tab never reaches it, so a click is the way in.
@MainActor
@Suite("STSegmented focus", .serialized)
struct SegmentedFocusTests {
    /// Clicking an option, even the one already chosen, focuses the control, so the arrows move on from there; the
    /// control focused before stops taking them.
    @Test func clickingAnOptionFocusesTheControl() throws {
        let segmented = SegmentedWindow()
        defer { segmented.close() }
        let choices = segmented.choices
        try #require(choices.upperFrame.width > 0 && choices.lowerFrame.width > 0, "the controls were laid out")

        // "One", the chosen option, sits just inside each control's 6 pt padding.
        segmented.click(choices.upperFrame, x: 12)
        segmented.pressRightArrow()
        #expect(choices.upper == 1, "the control: the upper one took the arrow after its click")

        segmented.click(choices.lowerFrame, x: 12)
        #expect(choices.lower == 0, "clicking the chosen option changes nothing")
        segmented.pressRightArrow()
        #expect(choices.lower == 1)
        #expect(choices.upper == 1, "the arrow went to the control clicked last")
    }

    /// A click beside the options, in the control's padding or between two of them, focuses it too.
    @Test func clickingBesideTheOptionsFocusesTheControl() throws {
        let segmented = SegmentedWindow()
        defer { segmented.close() }
        let choices = segmented.choices
        try #require(choices.upperFrame.width > 0 && choices.lowerFrame.width > 0, "the controls were laid out")
        segmented.click(choices.upperFrame, x: 12)

        segmented.click(choices.lowerFrame, x: 2)
        #expect(choices.lower == 0, "a click beside the options chooses nothing")
        segmented.pressRightArrow()
        #expect(choices.lower == 1)
        #expect(choices.upper == 0)
    }
}

@Suite("STSegmented options")
struct SegmentedOptionTests {
    /// VoiceOver reads an option's spoken title when it has one ("Command 1 to Command 5" for "⌘1–⌘5"), else its title.
    @Test func anOptionIsReadByItsSpokenTitle() {
        #expect(STSegmentedOption(1, "Plus").accessibilityTitle == "Plus")
        let set = STSegmentedOption(2, "⌘1–⌘5", spokenTitle: "Command 1 to Command 5")
        #expect(set.title == "⌘1–⌘5")
        #expect(set.accessibilityTitle == "Command 1 to Command 5")
    }
}
