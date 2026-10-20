import CoreGraphics
import Foundation
import Testing
@testable import STPlatform

// MARK: - Window rules

@Test(arguments: [
    ("Minecraft 1.16.1", "1.16.1"),
    ("Minecraft* 1.16.1", "1.16.1"),
    ("Minecraft* 1.16.1 - Singleplayer", "1.16.1"),
    ("Minecraft 1.16.1 - Multiplayer (3rd-party Server)", "1.16.1"),
    ("Minecraft* 24w14a", "24w14a"),
    ("Minecraft 1.20.4", "1.20.4"),
])
func versionIsParsedFromGameWindowTitles(title: String, version: String) {
    #expect(MinecraftWindowRules.version(fromTitle: title) == version)
    #expect(MinecraftWindowRules.isMinecraftTitle(title))
}

@Test(arguments: [
    "", "Minecraft", "Minecraft*", "Minecraft Launcher", "Minecraft Wiki - Safari", "minecraft 1.16.1",
    "Ninjabrain Bot", "Minecraft  ", "Minecraft*1.16.1", "Not Minecraft 1.16.1", "Minecraft x1.16.1", "🙂",
])
func nonGameTitlesAreRejected(title: String) {
    #expect(MinecraftWindowRules.version(fromTitle: title) == nil)
    #expect(!MinecraftWindowRules.isMinecraftTitle(title))
}

@Test func weirdTitlesNeverCrash() {
    let long = "Minecraft* " + String(repeating: "1.16.1😀", count: 5_000)
    #expect(MinecraftWindowRules.version(fromTitle: long) != nil)
    #expect(MinecraftWindowRules.version(fromTitle: "Minecraft 1.16.1\u{0}") != nil)
    #expect(MinecraftWindowRules.version(fromTitle: "Minecraft \u{202E}1.16.1") == nil)
}

@Test func onlyJavaProcessesCount() {
    #expect(MinecraftWindowRules.isJavaExecutable(named: "java"))
    #expect(MinecraftWindowRules.isJavaExecutable(named: "javaw"))
    #expect(!MinecraftWindowRules.isJavaExecutable(named: "Safari"))
    #expect(!MinecraftWindowRules.isJavaExecutable(named: "Java"))
    #expect(!MinecraftWindowRules.isJavaExecutable(named: ""))
}

// MARK: - Instance selection (rule R11)

private func instance(pid: Int32, title: String = "Minecraft* 1.16.1", launched: TimeInterval, frontmost: Bool = false,
                      frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)) -> MinecraftInstance {
    MinecraftInstance(
        window: MinecraftWindow(windowNumber: UInt32(pid) * 10, processID: pid, title: title, frame: frame),
        launchDate: Date(timeIntervalSince1970: launched), isFrontmost: frontmost, displayID: 1)
}

@Test func noInstancesMeansNoActiveAndNoConflict() {
    let selection = InstanceSelector.select(from: [])
    #expect(selection.active == nil && selection.others.isEmpty && selection.conflict == .none)
}

@Test func singleInstanceIsActiveWithoutConflict() {
    let one = instance(pid: 7, launched: 100)
    let selection = InstanceSelector.select(from: [one])
    #expect(selection.active == one && selection.others.isEmpty && selection.conflict == .none)
}

@Test func preferredVersionBeatsAnEarlierOtherVersion() {
    let older = instance(pid: 1, title: "Minecraft* 1.20.4", launched: 100)
    let preferred = instance(pid: 2, title: "Minecraft* 1.16.1", launched: 200)
    let selection = InstanceSelector.select(from: [older, preferred])
    #expect(selection.active == preferred)
    #expect(selection.others == [older])
    #expect(selection.conflict == .multiple(count: 2, followingVersion: "1.16.1"))
}

@Test func amongPreferredVersionsTheFirstOpenedWins() {
    let first = instance(pid: 5, launched: 100)
    let second = instance(pid: 3, launched: 200)
    let third = instance(pid: 4, launched: 300)
    let selection = InstanceSelector.select(from: [third, second, first])
    #expect(selection.active == first)
    #expect(selection.others == [second, third])
    #expect(selection.conflict == .multiple(count: 3, followingVersion: "1.16.1"))
}

@Test func withoutAnyPreferredVersionTheFirstOpenedWins() {
    let a = instance(pid: 1, title: "Minecraft* 1.20.4", launched: 300)
    let b = instance(pid: 2, title: "Minecraft* 1.19.2", launched: 100)
    let selection = InstanceSelector.select(from: [a, b])
    #expect(selection.active == b)
    #expect(selection.conflict == .multiple(count: 2, followingVersion: "1.19.2"))
}

@Test func launchTiesBreakOnProcessIDDeterministically() {
    let a = instance(pid: 9, launched: 100)
    let b = instance(pid: 4, launched: 100)
    #expect(InstanceSelector.select(from: [a, b]).active == b)
    #expect(InstanceSelector.select(from: [b, a]).active == b)
}

@Test func selectionDoesNotDependOnInputOrder() {
    let items = (1...6).map { instance(pid: Int32($0), title: $0.isMultiple(of: 2) ? "Minecraft* 1.20.4" : "Minecraft* 1.16.1", launched: Double(700 - $0 * 10)) }
    let expected = InstanceSelector.select(from: items)
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<50 {
        #expect(InstanceSelector.select(from: items.shuffled(using: &generator)) == expected)
    }
    #expect(expected.active?.id == 5)
}

// MARK: - Window server matching

private func windowRow(number: Int, pid: Int, rect: CGRect, layer: Int = 0) -> [String: Any] {
    [kCGWindowNumber as String: number, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
     kCGWindowBounds as String: CGRectCreateDictionaryRepresentation(rect)]
}

@Test func windowEntriesAreParsedAndBrokenRowsSkipped() {
    let rows: [[String: Any]] = [
        windowRow(number: 11, pid: 100, rect: CGRect(x: 10, y: 20, width: 800, height: 600)),
        [kCGWindowNumber as String: 12],
        windowRow(number: 13, pid: 101, rect: CGRect(x: 0, y: 0, width: 50, height: 50), layer: 25),
    ]
    let entries = CGWindowMatcher.entries(from: rows)
    #expect(entries.map(\.number) == [11, 13])
    #expect(entries[0].bounds == CGRect(x: 10, y: 20, width: 800, height: 600))
    #expect(entries[1].layer == 25)
}

@Test func windowNumberMatchesByProcessAndBounds() {
    let entries = [
        WindowListEntry(number: 1, processID: 100, bounds: CGRect(x: 0, y: 0, width: 400, height: 300), layer: 0),
        WindowListEntry(number: 2, processID: 100, bounds: CGRect(x: 0, y: 0, width: 800, height: 600), layer: 0),
        WindowListEntry(number: 3, processID: 200, bounds: CGRect(x: 0, y: 0, width: 800, height: 600), layer: 0),
        WindowListEntry(number: 4, processID: 100, bounds: CGRect(x: 0, y: 0, width: 800, height: 600), layer: 8),
    ]
    let frame = CGRect(x: 0.4, y: 0, width: 800, height: 600)
    #expect(CGWindowMatcher.windowNumber(processID: 100, frame: frame, in: entries) == 2)
    #expect(CGWindowMatcher.windowNumber(processID: 200, frame: frame, in: entries) == 3)
    #expect(CGWindowMatcher.windowNumber(processID: 300, frame: frame, in: entries) == nil)
    #expect(CGWindowMatcher.windowNumber(processID: 100, frame: CGRect(x: 5, y: 0, width: 800, height: 600), in: entries) == nil)
}

@Test func processStartTimeOfThisProcessIsRecent() throws {
    let start = try #require(ProcessStartTime.date(for: ProcessInfo.processInfo.processIdentifier))
    #expect(start <= Date() && Date().timeIntervalSince(start) < 3_600 * 24 * 14)
    #expect(ProcessStartTime.date(for: 2_000_000) == nil)
}

// MARK: - Locator

@MainActor
private func eventually(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
@Test func locatorTakesASnapshotOnStart() {
    let source = StaticMinecraftWindowSource(instances: [instance(pid: 1, launched: 100)])
    let locator = MinecraftLocator(source: source)
    #expect(locator.active == nil)
    locator.start()
    defer { locator.stop() }
    #expect(locator.active?.id == 1)
    #expect(locator.conflict == .none)
    #expect(locator.isRunning)
}

@MainActor
@Test func locatorFollowsInstancesAppearingAndDisappearing() async {
    let source = StaticMinecraftWindowSource()
    let locator = MinecraftLocator(source: source, coalescing: .milliseconds(5))
    locator.start()
    defer { locator.stop() }
    #expect(locator.active == nil)

    source.instances = [instance(pid: 1, launched: 100)]
    #expect(await eventually { locator.active?.id == 1 })

    source.instances = [instance(pid: 1, launched: 100), instance(pid: 2, launched: 200)]
    #expect(await eventually { locator.conflict == .multiple(count: 2, followingVersion: "1.16.1") })
    #expect(locator.active?.id == 1)

    source.instances = [instance(pid: 2, launched: 200)]
    #expect(await eventually { locator.conflict == .none && locator.active?.id == 2 })

    source.instances = []
    #expect(await eventually { locator.active == nil && locator.instances.isEmpty })
}

@MainActor
@Test func locatorSwitchesWhenThePreferredVersionAppears() async {
    let old = instance(pid: 1, title: "Minecraft* 1.20.4", launched: 100)
    let source = StaticMinecraftWindowSource(instances: [old])
    let locator = MinecraftLocator(source: source, coalescing: .milliseconds(5))
    locator.start()
    defer { locator.stop() }
    #expect(locator.active?.id == 1)
    source.instances = [old, instance(pid: 2, launched: 500)]
    #expect(await eventually { locator.active?.id == 2 })
}

@MainActor
@Test func stopHaltsUpdatesAndStartTwiceIsSafe() async {
    let source = StaticMinecraftWindowSource()
    let locator = MinecraftLocator(source: source, coalescing: .milliseconds(5))
    locator.start()
    locator.start()
    #expect(locator.isRunning)
    locator.stop()
    #expect(!locator.isRunning)
    source.instances = [instance(pid: 1, launched: 100)]
    try? await Task.sleep(for: .milliseconds(80))
    #expect(locator.active == nil)
    locator.stop()
    locator.start()
    #expect(locator.active?.id == 1)
    locator.stop()
}

@MainActor
@Test func burstsOfChangesCollapseIntoFewRefreshes() async {
    @MainActor final class CountingSource: MinecraftWindowSource {
        var snapshots = 0
        private let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        func snapshot() -> [MinecraftInstance] { snapshots += 1; return [] }
        func changes() -> AsyncStream<Void> { stream.0 }
        func fire() { stream.1.yield() }
    }
    let source = CountingSource()
    let locator = MinecraftLocator(source: source, coalescing: .milliseconds(40))
    locator.start()
    defer { locator.stop() }
    #expect(source.snapshots == 1)
    for _ in 0..<200 { source.fire() }
    try? await Task.sleep(for: .milliseconds(300))
    #expect(source.snapshots <= 4, "200 change events must not cause 200 snapshots (got \(source.snapshots))")
    #expect(source.snapshots >= 2)
}

@MainActor
@Test func closingTheActiveInstanceHandsOverToTheOther() async {
    let a = instance(pid: 1, launched: 100)
    let b = instance(pid: 2, launched: 200)
    let source = StaticMinecraftWindowSource(instances: [a, b])
    let locator = MinecraftLocator(source: source, coalescing: .milliseconds(5))
    locator.start()
    defer { locator.stop() }
    #expect(locator.active?.id == 1)
    source.instances = [b]
    #expect(await eventually { locator.active?.id == 2 && locator.conflict == .none })
}

@MainActor
@Test func instanceEdgeCasesAreHandled() {
    let zero = instance(pid: 1, launched: 100, frame: .zero)
    let emoji = instance(pid: 2, title: "Minecraft* 1.16.1 - 🌍🌍🌍 " + String(repeating: "x", count: 500), launched: 200)
    let source = StaticMinecraftWindowSource(instances: [zero, emoji])
    let locator = MinecraftLocator(source: source)
    locator.start()
    defer { locator.stop() }
    #expect(locator.instances.count == 2)
    #expect(locator.active?.window.frame == .zero)
    #expect(locator.active?.version == "1.16.1")
}

@MainActor
@Test func realSourceWithoutAnyJavaProcessDoesNotCrash() {
    let source = AXMinecraftSource()
    _ = source.changes()
    // Result depends on whether Minecraft happens to be running; the call must simply be safe.
    _ = source.snapshot()
}
