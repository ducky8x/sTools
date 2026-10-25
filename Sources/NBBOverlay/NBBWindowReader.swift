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

/// Reads a copy's window. The live one uses Accessibility; tests use a fake.
@MainActor
public protocol NBBWindowReading: AnyObject {
    /// The window's contents, or nil when it can't be read (no Accessibility, no window, the copy quit).
    func read(pid: Int32) -> NBBWindowSnapshot?
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
        let throwsHeader = indexOfSequence(["x", "z", "Angle", "Error"], in: texts, from: header)
        let eyeThrows = throwsHeader.map { parseThrows(items, from: $0 + 4) } ?? []
        let throwsTitle = texts.firstIndex(of: "Ender eye throws") ?? texts.count
        let messages = texts[header..<throwsTitle].filter(isMessage)
        let resultType: NBBEvents.ResultType = !predictions.isEmpty ? .triangulation : (eyeThrows.isEmpty ? .none : .failed)
        return NBBWindowSnapshot(
            stronghold: NBBEvents.Stronghold(resultType: resultType, predictions: predictions, eyeThrows: eyeThrows, playerPosition: nil),
            messages: resultType == .none ? [] : messages)
    }

    /// Rows of location "(x, z)", certainty "87.4%" and distance; the nether and angle columns after them are skipped
    /// (a nether location isn't followed by a certainty). Ninjabrain Bot names a chunk by a block inside it, so the chunk
    /// is that block divided by 16. The table ends at the next panel's first label.
    private static func parsePredictions(_ texts: [String], from start: Int) -> [NBBEvents.Prediction] {
        let stops: Set<String> = ["s1", "Safe:", "Ender eye throws"]
        var predictions: [NBBEvents.Prediction] = []
        var index = start
        while index + 2 < texts.count, !stops.contains(texts[index]) {
            if let block = coordinates(texts[index]), let certainty = percent(texts[index + 1]) {
                predictions.append(NBBEvents.Prediction(
                    chunkX: Int((block.x / 16).rounded(.down)), chunkZ: Int((block.z / 16).rounded(.down)),
                    certainty: certainty / 100, overworldDistance: Double(texts[index + 2]) ?? 0))
                index += 3
            } else {
                index += 1
            }
        }
        return predictions
    }

    /// Each row sits after a remove button: x, z, angle, perhaps a correction like "+6", then the error.
    private static func parseThrows(_ items: [Item], from start: Int) -> [NBBEvents.EyeThrow] {
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
            guard row.count >= 4, let x = Double(row[0]), let z = Double(row[1]), let angle = Double(row[2]),
                  let error = Double(row[row.count - 1]) else { return nil }
            let correction = row.count >= 5 ? Double(row[3].replacingOccurrences(of: "+", with: "")) ?? 0 : 0
            return NBBEvents.EyeThrow(
                xInOverworld: x, zInOverworld: z, angle: angle, angleWithoutCorrection: angle, correction: correction,
                correctionIncrements: nil, error: error, type: "NORMAL")
        }
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

    static func percent(_ text: String) -> Double? {
        guard text.hasSuffix("%"), text != "%" else { return nil }
        return Double(text.dropLast())
    }

    /// A note under the table: a sentence, not a label or a number.
    private static func isMessage(_ text: String) -> Bool {
        text.split(separator: " ").count >= 5 && text.first?.isLetter == true && !text.hasPrefix("Waiting for")
    }
}

/// Reads a copy's window through Accessibility. It walks the window once (about 50 ms for Ninjabrain Bot 1.5.2's
/// ~170 elements), keeps the static texts and buttons it found, and then reads only their values (a few ms) until the
/// window's shape changes or an element goes away, when it walks again. sTools already holds Accessibility for finding
/// Minecraft; without it, nothing is read.
@MainActor
public final class AXNBBWindowReader: NBBWindowReading {
    private struct Walked {
        var pid: Int32
        var elements: [(role: String, element: AXUIElement)]
        var walkedAt: Date
    }

    private var walked: Walked?
    /// Walks again at least this often, in case a panel changed which labels it shows.
    private let rewalkInterval: TimeInterval = 5

    public init() {}

    public func read(pid: Int32) -> NBBWindowSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        if walked?.pid != pid || Date().timeIntervalSince(walked?.walkedAt ?? .distantPast) > rewalkInterval {
            walked = walk(pid: pid)
        }
        guard let walked else { return nil }
        var items: [NBBWindowParser.Item] = []
        items.reserveCapacity(walked.elements.count)
        for (role, element) in walked.elements {
            var value: AnyObject?
            let attribute = role == "AXButton" ? kAXTitleAttribute : kAXValueAttribute
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if result == .invalidUIElement {
                self.walked = nil
                return nil
            }
            items.append(NBBWindowParser.Item(role: role, text: value as? String ?? ""))
        }
        return NBBWindowParser.parse(items)
    }

    private func walk(pid: Int32) -> Walked? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        var elements: [(String, AXUIElement)] = []
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 30, elements.count < 600 else { return }
            let role = copy(element, kAXRoleAttribute) as? String ?? ""
            if role == "AXStaticText" || role == "AXButton" { elements.append((role, element)) }
            for child in (copy(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { visit(child, depth: depth + 1) }
        }
        // Ninjabrain Bot's main window is the one with the predictions table.
        for window in windows {
            elements = []
            visit(window, depth: 0)
            let texts = elements.compactMap { copy($0.1, kAXValueAttribute) as? String }
            if texts.contains("Location") && texts.contains("Dist.") { return Walked(pid: pid, elements: elements, walkedAt: Date()) }
        }
        return nil
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}
