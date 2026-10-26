import ApplicationServices
import Foundation

/// What a Ninjabrain Bot copy's own window shows, read through Accessibility: for a copy that can't share its data
/// over the API (another copy holds the port), so the overlay can still follow the copy the person is using.
///
/// The window gives the predictions table and the eye throws, plus its notes; the boat (an icon) and the blind, divine
/// and all-advancements views aren't read. Everything shown comes from Ninjabrain Bot's own window, so the overlay
/// still shows only what Ninjabrain Bot shows.
public struct NBBWindowSnapshot: Equatable, Sendable {
    public var stronghold: NBBEvents.Stronghold
    public var messages: [String]

    public init(stronghold: NBBEvents.Stronghold, messages: [String]) {
        self.stronghold = stronghold
        self.messages = messages
    }
}

/// Reads a copy's window, off the main actor. The live one uses Accessibility; tests use a fake.
public protocol NBBWindowReading: Sendable {
    /// The window's contents, or nil when it can't be read (no Accessibility, no window, the copy quit).
    func read(pid: Int32) async -> NBBWindowSnapshot?
}

/// Turns the window's text, in the order Accessibility lists it, into a result. Pure, so it can be checked against
/// recorded windows.
enum NBBWindowParser {
    struct Item: Equatable {
        var role: String
        var text: String
        static func text(_ text: String) -> Item { Item(role: "AXStaticText", text: text) }
        static var button: Item { Item(role: "AXButton", text: "-") }
    }

    static func parse(_ items: [Item]) -> NBBWindowSnapshot? {
        let texts = items.map { $0.text.trimmingCharacters(in: .whitespaces) }
        guard let header = indexOfSequence(["Location", "%", "Dist."], in: texts) else { return nil }
        let predictions = parsePredictions(texts, from: header + 3)
        // The Error heading shows only while Ninjabrain Bot's Show angle errors is on.
        let throwsHeader = indexOfSequence(["x", "z", "Angle"], in: texts, from: header)
        let showsErrors = throwsHeader.map { $0 + 3 < texts.count && texts[$0 + 3] == "Error" } ?? false
        let eyeThrows = throwsHeader.map { parseThrows(items, from: $0 + (showsErrors ? 4 : 3), showsErrors: showsErrors) } ?? []
        let throwsTitle = texts.firstIndex(of: "Ender eye throws") ?? texts.count
        let messages = texts[header..<throwsTitle].filter(isMessage)
        let resultType: NBBEvents.ResultType = !predictions.isEmpty ? .triangulation : (eyeThrows.isEmpty ? .none : .failed)
        return NBBWindowSnapshot(
            stronghold: NBBEvents.Stronghold(resultType: resultType, predictions: predictions, eyeThrows: eyeThrows, playerPosition: nil),
            messages: resultType == .none ? [] : messages)
    }

    /// Rows of location "(x, z)", certainty "87.4%" and distance, then the Nether location, the angle and its turn when
    /// the window shows them (a nether location isn't followed by a certainty, so it never starts a row). The window's
    /// own Location, Nether and distance texts are kept as they are (`shownLocation`, `shownNether`, `shownDistance`):
    /// its distance is already in the player's dimension, and its Location follows its own display choice. The chunk is
    /// the location block divided by 16 (unused for what's shown, which is the window's text). The table ends at the
    /// next panel's first label.
    private static func parsePredictions(_ texts: [String], from start: Int) -> [NBBEvents.Prediction] {
        let stops: Set<String> = ["s1", "Safe:", "Ender eye throws"]
        var predictions: [NBBEvents.Prediction] = []
        var index = start
        while index + 2 < texts.count, !stops.contains(texts[index]) {
            if let block = coordinates(texts[index]), let certainty = percent(texts[index + 1]) {
                // A location followed by a certainty is the next row's, when the window hides its Nether column.
                let startsNextRow = index + 4 < texts.count && percent(texts[index + 4]) != nil
                let nether = index + 3 < texts.count && !startsNextRow ? coordinates(texts[index + 3]) : nil
                // Then the angle ("118.30") and its turn (" (<- 113.7)"), after the Nether column when it's shown.
                let angleIndex = index + (nether != nil ? 4 : 3)
                let angle = angleIndex < texts.count ? Double(texts[angleIndex]) : nil
                let change = angle != nil && angleIndex + 1 < texts.count ? turn(texts[angleIndex + 1]) : nil
                predictions.append(NBBEvents.Prediction(
                    chunkX: Int((block.x / 16).rounded(.down)), chunkZ: Int((block.z / 16).rounded(.down)),
                    certainty: certainty / 100, overworldDistance: Double(texts[index + 2]) ?? 0,
                    shownAngle: angle, shownAngleChange: change,
                    shownLocation: whole(block), shownNether: nether.flatMap(whole), shownDistance: Int(texts[index + 2])))
                index += 3
            } else {
                index += 1
            }
        }
        return predictions
    }

    /// Each row sits after a remove button: x, z, the angle before the correction, the correction when the angle was
    /// adjusted, then the error when the window shows errors. Ninjabrain Bot always signs a correction ("+6" as the number
    /// of adjustments, "+0.01" or "-0.013" as the angle change) and never an error's plus, and writes the number of
    /// adjustments without a decimal point, which tells a lone fourth text apart. The window's own correction text is kept
    /// (`shownCorrection`); an angle change also gives the corrected angle, a number of adjustments doesn't (the window
    /// doesn't say how far each one turns).
    private static func parseThrows(_ items: [Item], from start: Int, showsErrors: Bool) -> [NBBEvents.EyeThrow] {
        var rows: [[String]] = [[]]
        for item in items[min(start, items.count)...] {
            if item.role == "AXButton" {
                rows.append([])
                continue
            }
            let text = item.text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            guard Double(text.replacingOccurrences(of: "+", with: "")) != nil else { break }
            rows[rows.count - 1].append(text)
        }
        return rows.compactMap { row in
            guard (3...5).contains(row.count), let x = Double(row[0]), let z = Double(row[1]), let angle = Double(row[2]) else { return nil }
            var rest = Array(row.dropFirst(3))
            var errorText: String?
            if showsErrors, let last = rest.last, rest.count == 2 || !isCorrection(last) { errorText = rest.removeLast() }
            guard rest.count <= 1 else { return nil }
            let shownCorrection = rest.first
            let increments = shownCorrection.flatMap { $0.contains(".") ? nil : Int($0.replacingOccurrences(of: "+", with: "")) }
            let degrees = shownCorrection.flatMap { $0.contains(".") ? Double($0.replacingOccurrences(of: "+", with: "")) : nil } ?? 0
            return NBBEvents.EyeThrow(
                xInOverworld: x, zInOverworld: z, angle: angle + degrees, angleWithoutCorrection: angle, correction: degrees,
                correctionIncrements: increments, error: errorText.flatMap(Double.init) ?? 0, type: "NORMAL",
                shownCorrection: shownCorrection, showsError: errorText != nil)
        }
    }

    /// A text only a correction can be: signed with a plus, or a whole number of adjustments.
    private static func isCorrection(_ text: String) -> Bool {
        text.hasPrefix("+") || !text.contains(".")
    }

    /// The texts a quick look between full reads asks for again: the predictions table's first row and the eye throws.
    /// Whatever Ninjabrain Bot changes there shows in them: a throw adds a row and changes the top prediction, an angle
    /// adjustment changes its throw's correction, an F3+C moves the top row's angle and turn, and a reset or undo clears
    /// or shifts the rows. Notes and the rows below the top one alone wait for the next full read. Indices into `items`;
    /// buttons are left out, as their titles are kept from the walk.
    static func watchedIndices(_ items: [Item]) -> [Int] {
        let texts = items.map { $0.text.trimmingCharacters(in: .whitespaces) }
        guard let header = indexOfSequence(["Location", "%", "Dist."], in: texts) else { return [] }
        let stops: Set<String> = ["s1", "Safe:", "Ender eye throws"]
        var watched: [Int] = []
        var index = header + 3
        while index < texts.count, texts[index] == "Nether" || texts[index] == "Angle" { index += 1 }
        var taken = 0
        while index < texts.count, taken < 6, !stops.contains(texts[index]) {
            if items[index].role != "AXButton" { watched.append(index) }
            index += 1
            taken += 1
        }
        if let throwsHeader = indexOfSequence(["x", "z", "Angle"], in: texts, from: header) {
            let first = throwsHeader + (throwsHeader + 3 < texts.count && texts[throwsHeader + 3] == "Error" ? 4 : 3)
            watched += (first..<min(texts.count, first + 60)).filter { items[$0].role != "AXButton" }
        }
        return watched
    }

    private static func indexOfSequence(_ sequence: [String], in texts: [String], from start: Int = 0) -> Int? {
        guard texts.count >= sequence.count, start <= texts.count - sequence.count else { return nil }
        return (start...(texts.count - sequence.count)).first { Array(texts[$0..<($0 + sequence.count)]) == sequence }
    }

    static func coordinates(_ text: String) -> (x: Double, z: Double)? {
        guard text.hasPrefix("("), text.hasSuffix(")") else { return nil }
        let parts = text.dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let x = Double(parts[0]), let z = Double(parts[1]) else { return nil }
        return (x, z)
    }

    /// The window's "(x, z)" as the whole numbers it writes.
    private static func whole(_ pair: (x: Double, z: Double)) -> NBBBlock? {
        guard let x = Int(exactly: pair.x), let z = Int(exactly: pair.z) else { return nil }
        return NBBBlock(x: x, z: z)
    }

    /// "(-> 47.4)" is a turn right (+), "(<- 113.7)" a turn left (−).
    static func turn(_ text: String) -> Double? {
        let inner = text.trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
        if inner.hasPrefix("->"), let value = Double(inner.dropFirst(2).trimmingCharacters(in: .whitespaces)) { return value }
        if inner.hasPrefix("<-"), let value = Double(inner.dropFirst(2).trimmingCharacters(in: .whitespaces)) { return -value }
        return nil
    }

    static func percent(_ text: String) -> Double? {
        guard text.hasSuffix("%"), text != "%" else { return nil }
        return Double(text.dropLast())
    }

    /// A note under the table: a sentence, not a label or a number.
    private static func isMessage(_ text: String) -> Bool {
        text.split(separator: " ").count >= 5 && text.first?.isLetter == true && !text.hasPrefix("Waiting for")
    }
}

// MARK: - Accessibility

/// One element of another app's Accessibility tree: an `AXUIElement` for the live reader, a made-up node in tests.
struct NBBAXElement {
    let reference: AnyObject
}

/// What reading a text from an element gave.
enum NBBAXText: Equatable {
    case text(String?)
    /// The element is gone (the window changed shape or closed): walk again.
    case gone
    /// The app didn't answer in time (it's busy or hung): stop this read.
    case noAnswer
}

/// The Accessibility calls a window read makes, each a message to the other app. The live one is `AXUIElement`;
/// tests use a fake.
protocol NBBAccessibility: Sendable {
    func isTrusted() -> Bool
    func windows(ofApp pid: Int32) -> [NBBAXElement]
    func role(of element: NBBAXElement) -> String?
    func children(of element: NBBAXElement) -> [NBBAXElement]
    /// A static text's value or a button's title.
    func text(of element: NBBAXElement, isButton: Bool) -> NBBAXText
}

struct LiveAccessibility: NBBAccessibility {
    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func windows(ofApp pid: Int32) -> [NBBAXElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return (copy(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).map(NBBAXElement.init)
    }

    func role(of element: NBBAXElement) -> String? { copy(ax(element), kAXRoleAttribute) as? String }

    func children(of element: NBBAXElement) -> [NBBAXElement] {
        (copy(ax(element), kAXChildrenAttribute) as? [AXUIElement] ?? []).map(NBBAXElement.init)
    }

    func text(of element: NBBAXElement, isButton: Bool) -> NBBAXText {
        var value: AnyObject?
        let attribute = isButton ? kAXTitleAttribute : kAXValueAttribute
        switch AXUIElementCopyAttributeValue(ax(element), attribute as CFString, &value) {
        case .invalidUIElement: return .gone
        case .cannotComplete: return .noAnswer
        default: return .text(value as? String)
        }
    }

    private func ax(_ element: NBBAXElement) -> AXUIElement {
        // Only this type makes elements, always from an AXUIElement.
        unsafeDowncast(element.reference, to: AXUIElement.self)
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}

// MARK: - Reader

/// Reads a copy's window through Accessibility, on a queue of its own (never the main actor, and never the shared
/// threads the app's tasks run on, as each call waits for the other app). sTools already holds Accessibility for
/// finding Minecraft; without it, nothing is read.
///
/// It walks the window (about 170 elements for Ninjabrain Bot 1.5.2, 60–75 ms) and keeps its static texts and buttons
/// with what they said, which is that read's result. Ninjabrain Bot doesn't announce its label changes through
/// Accessibility (Java posts a value change for text fields, sliders and tables, not for a label's new text), so the
/// window is looked at often, and most looks are small: between full reads a read asks only the texts that change
/// whenever Ninjabrain Bot's result does (`NBBWindowParser.watchedIndices`: the top prediction row and the eye throws,
/// about a third of the texts) and gives the last result back when none changed. When one did, it reads every static
/// text at once (about 20 ms, nearly all of it waiting for Ninjabrain Bot's answers; the buttons' titles, "Undo",
/// "Reset" …, are kept from the walk) and walks again on the next read, in case a row came or went. A full read comes
/// at least every second anyway, for the notes, and a walk every 5 s, when the copy changes and when an element went
/// away (then at once, in the same read, so a reset doesn't blank the overlay). A copy that doesn't answer in time
/// keeps its last result. A walk that finds no predictions table (the window is closed, or Accessibility lists the app
/// itself as its window) is tried again only after 2 s, and a walk never goes into menus or the app's own element,
/// which Accessibility can list inside its windows, endlessly.
public actor AXNBBWindowReader: NBBWindowReading {
    private struct Walked {
        var pid: Int32
        var elements: [(element: NBBAXElement, isButton: Bool, walkedText: String)]
        var walkedAt: ContinuousClock.Instant
        /// What each element said at the last full read.
        var texts: [String]
        /// The elements a look between full reads asks.
        var watched: [Int]
        var readAt: ContinuousClock.Instant
        var snapshot: NBBWindowSnapshot?
        /// A look saw a change: the next read walks, in case a row came or went.
        var walksNext = false
    }

    private enum TextsRead {
        case texts([String])
        /// An element is gone (the window changed shape or closed): walk again.
        case gone
        /// The app didn't answer in time.
        case noAnswer
    }

    private let accessibility: any NBBAccessibility
    private let now: @Sendable () -> ContinuousClock.Instant
    private var walked: Walked?
    private var failedWalk: (pid: Int32, at: ContinuousClock.Instant)?
    /// Walks again at least this often, in case a panel changed which labels it shows.
    private let rewalkInterval: Duration = .seconds(5)
    /// Reads every static text at least this often; the reads in between ask only the watched ones.
    static let fullReadInterval: Duration = .seconds(1)
    /// How long a walk that found no predictions table waits before the next try.
    private let retryInterval: Duration = .seconds(2)
    /// Ninjabrain Bot's window has about 170 elements; a walk stops at this many.
    static let walkLimit = 1_000
    private let queue = DispatchSerialQueue(label: "com.ducky8x.sTools.nbb-window-reader", qos: .utility)

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init() {
        self.init(accessibility: LiveAccessibility())
    }

    init(accessibility: any NBBAccessibility, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.accessibility = accessibility
        self.now = now
    }

    public func read(pid: Int32) -> NBBWindowSnapshot? {
        guard accessibility.isTrusted() else { return nil }
        let now = now()
        if var current = walked, current.pid == pid, !current.walksNext, now - current.walkedAt < rewalkInterval {
            if now - current.readAt < Self.fullReadInterval, !current.watched.isEmpty {
                switch readTexts(of: current, at: current.watched) {
                case .texts(let texts) where zip(current.watched, texts).allSatisfy({ current.texts[$0] == $1 }):
                    return current.snapshot
                case .noAnswer:
                    return current.snapshot
                case .gone:
                    return walkAndParse(pid: pid, at: now)
                case .texts:
                    current.walksNext = true
                }
            }
            switch readTexts(of: current, at: Array(current.elements.indices)) {
            case .texts(let texts):
                current.texts = texts
                current.readAt = now
                current.snapshot = Self.parse(current.elements, texts)
                walked = current
                return current.snapshot
            case .noAnswer:
                return current.snapshot
            case .gone:
                break
            }
        }
        return walkAndParse(pid: pid, at: now)
    }

    private func walkAndParse(pid: Int32, at now: ContinuousClock.Instant) -> NBBWindowSnapshot? {
        if let failedWalk, failedWalk.pid == pid, now - failedWalk.at < retryInterval {
            walked = nil
            return nil
        }
        guard let found = walk(pid: pid, at: now) else {
            walked = nil
            failedWalk = (pid, now)
            return nil
        }
        walked = found
        failedWalk = nil
        return found.snapshot
    }

    /// The static texts at `indices` now; a button's title is the walk's.
    private func readTexts(of walked: Walked, at indices: [Int]) -> TextsRead {
        var texts: [String] = []
        texts.reserveCapacity(indices.count)
        for index in indices {
            let (element, isButton, walkedText) = walked.elements[index]
            if isButton {
                texts.append(walkedText)
                continue
            }
            switch accessibility.text(of: element, isButton: false) {
            case .text(let text): texts.append(text ?? "")
            case .gone: return .gone
            case .noAnswer: return .noAnswer
            }
        }
        return .texts(texts)
    }

    private static func parse(_ elements: [(element: NBBAXElement, isButton: Bool, walkedText: String)], _ texts: [String]) -> NBBWindowSnapshot? {
        NBBWindowParser.parse(zip(elements, texts).map { item($0.0.isButton, $0.1) })
    }

    private static func item(_ isButton: Bool, _ text: String) -> NBBWindowParser.Item {
        NBBWindowParser.Item(role: isButton ? "AXButton" : "AXStaticText", text: text)
    }

    private func walk(pid: Int32, at time: ContinuousClock.Instant) -> Walked? {
        // Menus and the app's own element hold nothing of the window, and Accessibility can list the app inside it.
        let skipped: Set<String> = ["AXApplication", "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem"]
        var elements: [(element: NBBAXElement, isButton: Bool)] = []
        var visited = 0
        func visit(_ element: NBBAXElement, depth: Int) {
            guard depth < 30, visited < Self.walkLimit else { return }
            visited += 1
            let role = accessibility.role(of: element) ?? ""
            if skipped.contains(role) { return }
            if role == "AXStaticText" || role == "AXButton" { elements.append((element, role == "AXButton")) }
            for child in accessibility.children(of: element) { visit(child, depth: depth + 1) }
        }
        // Ninjabrain Bot's main window is the one with the predictions table.
        for window in accessibility.windows(ofApp: pid) {
            elements = []
            visited = 0
            visit(window, depth: 0)
            var kept: [(element: NBBAXElement, isButton: Bool, walkedText: String)] = []
            kept.reserveCapacity(elements.count)
            for (element, isButton) in elements {
                guard case .text(let text) = accessibility.text(of: element, isButton: isButton) else { return nil }
                kept.append((element, isButton, text ?? ""))
            }
            let texts = kept.filter { !$0.isButton }.map(\.walkedText)
            if texts.contains("Location") && texts.contains("Dist.") {
                let allTexts = kept.map(\.walkedText)
                let items = kept.map { Self.item($0.isButton, $0.walkedText) }
                return Walked(
                    pid: pid, elements: kept, walkedAt: time, texts: allTexts, watched: NBBWindowParser.watchedIndices(items),
                    readAt: time, snapshot: NBBWindowParser.parse(items))
            }
        }
        return nil
    }
}
