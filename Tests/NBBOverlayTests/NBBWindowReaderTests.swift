import Darwin
import Foundation
import Synchronization
import Testing
@testable import NBBOverlay

/// A made-up Accessibility tree that records every call a read makes, and whether it ran on the main thread.
final class FakeAccessibility: NBBAccessibility, @unchecked Sendable {
    final class Node {
        let role: String
        var text: String?
        var children: [Node]
        var answer: NBBAXText?
        init(_ role: String, _ text: String? = nil, _ children: [Node] = []) {
            self.role = role
            self.text = text
            self.children = children
        }
    }

    private let lock = NSLock()
    private var windowList: [Node]
    var trusted = true
    private(set) var roleCalls = 0
    private(set) var childrenCalls = 0
    private(set) var textCalls: [String] = []
    private(set) var callsOnMainThread = 0

    init(windows: [Node]) { windowList = windows }

    var windows: [Node] {
        get { lock.withLock { windowList } }
        set { lock.withLock { windowList = newValue } }
    }

    func resetCounts() {
        lock.withLock {
            roleCalls = 0
            childrenCalls = 0
            textCalls = []
        }
    }

    private func node(_ element: NBBAXElement) -> Node { element.reference as! Node }

    private func record(_ body: () -> Void) {
        lock.withLock {
            if pthread_main_np() != 0 { callsOnMainThread += 1 }
            body()
        }
    }

    func isTrusted() -> Bool { lock.withLock { trusted } }

    func windows(ofApp pid: Int32) -> [NBBAXElement] {
        record {}
        return windows.map { NBBAXElement(reference: $0) }
    }

    func role(of element: NBBAXElement) -> String? {
        record { roleCalls += 1 }
        return node(element).role
    }

    func children(of element: NBBAXElement) -> [NBBAXElement] {
        record { childrenCalls += 1 }
        return node(element).children.map { NBBAXElement(reference: $0) }
    }

    func text(of element: NBBAXElement, isButton: Bool) -> NBBAXText {
        let node = node(element)
        record { textCalls.append(node.text ?? "") }
        return node.answer ?? .text(node.text)
    }
}

private typealias Node = FakeAccessibility.Node

/// Ninjabrain Bot's main window, cut down: the predictions table with one row, a button and the throws' title.
private func nbbWindow(certainty: String = "100.0%") -> (window: Node, certainty: Node) {
    let certaintyText = Node("AXStaticText", certainty)
    let table = Node("AXGroup", nil, [
        Node("AXStaticText", "Location"), Node("AXStaticText", "%"), Node("AXStaticText", "Dist."),
        Node("AXStaticText", "(-1340, 84)"), certaintyText, Node("AXStaticText", "1"),
    ])
    let throwsPanel = Node("AXGroup", nil, [Node("AXStaticText", "Ender eye throws"), Node("AXButton", "Undo")])
    return (Node("AXWindow", "Ninjabrain Bot", [table, throwsPanel]), certaintyText)
}

/// A clock the test moves by hand.
private final class ManualClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    var now: ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(by duration: Duration) { instant.withLock { $0 += duration } }
}

@Suite("Reading a Ninjabrain Bot window through Accessibility")
struct NBBWindowReaderTests {
    private func reader(_ accessibility: FakeAccessibility, clock: ManualClock) -> AXNBBWindowReader {
        AXNBBWindowReader(accessibility: accessibility, now: { clock.now })
    }

    @Test func aWalkReadsEachElementOnceAndLaterReadsAskOnlyTheStaticTexts() async throws {
        let (window, certainty) = nbbWindow()
        let accessibility = FakeAccessibility(windows: [window])
        let clock = ManualClock()
        let reader = reader(accessibility, clock: clock)

        let first = try #require(await reader.read(pid: 7))
        #expect(first.stronghold.predictions.first?.certainty == 1)
        #expect(accessibility.roleCalls == 11 && accessibility.childrenCalls == 11, "the window, two panels and eight labels")
        #expect(accessibility.textCalls.count == 8, "each static text and button once: the walk's texts are its result")

        accessibility.resetCounts()
        certainty.text = "87.5%"
        clock.advance(by: .milliseconds(500))
        let second = try #require(await reader.read(pid: 7))
        #expect(second.stronghold.predictions.first?.certainty == 0.875)
        #expect(accessibility.roleCalls == 0 && accessibility.childrenCalls == 0, "no walk between walks")
        #expect(accessibility.textCalls.count == 7 && !accessibility.textCalls.contains("Undo"), "the button's title is kept from the walk")
    }

    @Test func itWalksAgainEveryFiveSecondsAndForAnotherCopy() async {
        let accessibility = FakeAccessibility(windows: [nbbWindow().window])
        let clock = ManualClock()
        let reader = reader(accessibility, clock: clock)
        _ = await reader.read(pid: 7)
        accessibility.resetCounts()
        clock.advance(by: .milliseconds(4_900))
        _ = await reader.read(pid: 7)
        #expect(accessibility.roleCalls == 0)
        clock.advance(by: .milliseconds(200))
        _ = await reader.read(pid: 7)
        #expect(accessibility.roleCalls == 11)
        accessibility.resetCounts()
        _ = await reader.read(pid: 8)
        #expect(accessibility.roleCalls == 11)
    }

    /// Seen on macOS 27 with a Ninjabrain Bot whose window was closed: Accessibility listed the app itself as its only
    /// window, with the app again and its menu bar inside, endlessly (2,393 elements to depth 30, 135 ms a read).
    @Test func aWindowListedAsTheAppItselfIsntWalkedAndIsTriedAgainOnlyAfterTwoSeconds() async {
        let app = Node("AXApplication", "java")
        let menuBar = Node("AXMenuBar", nil, [Node("AXMenuBarItem", "java", [Node("AXMenu", nil, [Node("AXMenuItem", "Quit")])])])
        app.children = [app, menuBar]
        let accessibility = FakeAccessibility(windows: [app])
        let clock = ManualClock()
        let reader = reader(accessibility, clock: clock)

        #expect(await reader.read(pid: 7) == nil)
        #expect(accessibility.roleCalls == 1 && accessibility.childrenCalls == 0 && accessibility.textCalls.isEmpty)
        accessibility.resetCounts()
        clock.advance(by: .milliseconds(1_500))
        #expect(await reader.read(pid: 7) == nil)
        #expect(accessibility.roleCalls == 0, "no new walk within 2 s of one that found nothing")

        accessibility.windows = [nbbWindow().window]
        clock.advance(by: .milliseconds(600))
        #expect(await reader.read(pid: 7) != nil)
    }

    @Test func aWalkStopsAtItsLimit() async {
        let deep = Node("AXWindow", nil, (0..<40).map { _ in Node("AXGroup", nil, (0..<40).map { _ in Node("AXStaticText", "label") }) })
        let accessibility = FakeAccessibility(windows: [deep])
        let reader = reader(accessibility, clock: ManualClock())
        #expect(await reader.read(pid: 7) == nil)
        #expect(accessibility.roleCalls == AXNBBWindowReader.walkLimit)
    }

    @Test func aGoneElementMakesTheNextReadWalkAgain() async {
        let (window, certainty) = nbbWindow()
        let accessibility = FakeAccessibility(windows: [window])
        let clock = ManualClock()
        let reader = reader(accessibility, clock: clock)
        _ = await reader.read(pid: 7)
        certainty.answer = .gone
        clock.advance(by: .milliseconds(500))
        #expect(await reader.read(pid: 7) == nil)
        certainty.answer = nil
        accessibility.resetCounts()
        clock.advance(by: .milliseconds(500))
        #expect(await reader.read(pid: 7) != nil)
        #expect(accessibility.roleCalls == 11)
    }

    /// A copy that doesn't answer in time isn't asked for the rest of its labels; the walk is kept for the next read.
    @Test func aBusyAppEndsTheReadButKeepsTheWalk() async {
        let (window, certainty) = nbbWindow()
        let accessibility = FakeAccessibility(windows: [window])
        let clock = ManualClock()
        let reader = reader(accessibility, clock: clock)
        _ = await reader.read(pid: 7)
        certainty.answer = .noAnswer
        accessibility.resetCounts()
        clock.advance(by: .milliseconds(500))
        #expect(await reader.read(pid: 7) == nil)
        #expect(accessibility.textCalls.count == 5, "the read stopped at the label that didn't answer")
        certainty.answer = nil
        accessibility.resetCounts()
        clock.advance(by: .milliseconds(500))
        #expect(await reader.read(pid: 7) != nil)
        #expect(accessibility.roleCalls == 0)
    }

    @Test func withoutAccessibilityNothingIsAsked() async {
        let accessibility = FakeAccessibility(windows: [nbbWindow().window])
        accessibility.trusted = false
        let reader = reader(accessibility, clock: ManualClock())
        #expect(await reader.read(pid: 7) == nil)
        #expect(accessibility.roleCalls == 0 && accessibility.textCalls.isEmpty)
    }

    @MainActor @Test func readsRunOffTheMainActor() async {
        let accessibility = FakeAccessibility(windows: [nbbWindow().window])
        let clock = ManualClock()
        let reader = reader(accessibility, clock: clock)
        for _ in 0..<3 {
            #expect(await reader.read(pid: 7) != nil)
            clock.advance(by: .seconds(3))
        }
        #expect(accessibility.roleCalls > 0 && accessibility.callsOnMainThread == 0)
    }
}
