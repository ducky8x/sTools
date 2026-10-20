import Foundation

/// One section of Karabiner's key picker ("Letter keys", "Mouse buttons"...).
public struct KeyCategory: Hashable, Sendable, Identifiable {
    /// Karabiner's own slug, e.g. `letters`, `mouse_buttons`.
    public let id: String
    /// English title as the key picker shows it.
    public let title: String
}

/// One choice in Karabiner's key picker: a key, consumer key, pointing button or one of the other event kinds.
public struct KeyEntry: Hashable, Sendable, Identifiable {
    /// The event this entry sends or receives. Entries that send several events are `.other(.array(...))`.
    public let event: KarabinerEvent
    public let category: String
    /// English label as the key picker shows it.
    public let label: String
    /// False for entries Karabiner only offers as an output.
    public let canBeSource: Bool
    /// False for entries Karabiner only offers as an input.
    public let canBeTarget: Bool
    /// Karabiner warns that rebinding this input can lock you out (the primary mouse button).
    public let isUnsafeSource: Bool

    public var id: KarabinerEvent { event }
}

/// Karabiner-Elements' canonical key list, generated at development time by `scripts/generate-key-table.swift`
/// from `simple_modifications.json`, plus the macOS virtual key code (kVK_*) each key_code arrives as.
public struct KeyTable: Sendable {
    public let categories: [KeyCategory]
    /// Every entry in Karabiner's picker order.
    public let entries: [KeyEntry]

    private let entriesByEvent: [KarabinerEvent: KeyEntry]
    private let otherEntries: [KeyEntry]
    private let keyCodesByVirtualKey: [Int: [String]]
    private let virtualKeyByKeyCode: [String: Int]

    /// The bundled table.
    public static let shared: KeyTable = {
        guard let url = KeyTableResources.tableURL(), let data = try? Data(contentsOf: url),
              let table = try? KeyTable(data: data) else {
            fatalError("KeyTable.json is missing or unreadable in the KeyRebinder resource bundle")
        }
        return table
    }()

    /// Reads a table from the generator's JSON.
    public init(data: Data) throws {
        let root = try JSONValue.parse(data: data)
        guard root["format"]?.intValue == 1, let categoryValues = root["categories"]?.arrayValue,
              let keyValues = root["keys"]?.arrayValue, let virtualValues = root["virtualKeys"]?.arrayValue else {
            throw KeyTableError.unexpectedFormat
        }
        categories = try categoryValues.map { value in
            guard let id = value["id"]?.stringValue, let title = value["title"]?.stringValue else {
                throw KeyTableError.unexpectedFormat
            }
            return KeyCategory(id: id, title: title)
        }
        entries = try keyValues.map { value in
            guard let category = value["category"]?.stringValue, let label = value["label"]?.stringValue,
                  let events = value["events"]?.arrayValue, !events.isEmpty else {
                throw KeyTableError.unexpectedFormat
            }
            return KeyEntry(
                event: KarabinerEvent(toValue: .array(events)),
                category: category,
                label: label,
                canBeSource: value["noFrom"]?.boolValue != true,
                canBeTarget: value["noTo"]?.boolValue != true,
                isUnsafeSource: value["unsafeFrom"]?.boolValue == true
            )
        }
        var byEvent: [KarabinerEvent: KeyEntry] = [:]
        var others: [KeyEntry] = []
        for entry in entries {
            if case .other = entry.event { others.append(entry) } else if byEvent[entry.event] == nil { byEvent[entry.event] = entry }
        }
        entriesByEvent = byEvent
        otherEntries = others

        var byVirtualKey: [Int: [String]] = [:]
        var byKeyCode: [String: Int] = [:]
        for value in virtualValues {
            guard let virtualKey = value["vk"]?.intValue, let codes = value["keyCodes"]?.arrayValue?.compactMap(\.stringValue),
                  !codes.isEmpty else { throw KeyTableError.unexpectedFormat }
            byVirtualKey[virtualKey] = codes
            for code in codes { byKeyCode[code] = virtualKey }
        }
        keyCodesByVirtualKey = byVirtualKey
        virtualKeyByKeyCode = byKeyCode
    }

    // MARK: Lookups

    /// The picker entry for `event`, or `nil` for events the picker does not list.
    public func entry(for event: KarabinerEvent) -> KeyEntry? {
        if case .other(let value) = event {
            return otherEntries.first { entry in
                if case .other(let candidate) = entry.event { candidate.semanticallyEquals(value) } else { false }
            }
        }
        return entriesByEvent[event]
    }

    /// A human label: the picker's label, or the raw code (or compact JSON) for events the picker does not list.
    public func label(for event: KarabinerEvent) -> String {
        if let entry = entry(for: event) { return entry.label }
        switch event {
        case .key(let code), .consumer(let code), .pointing(let code): return code
        case .other(let value): return value.serialized()
        }
    }

    /// The category slug for `event`, if the picker lists it.
    public func category(for event: KarabinerEvent) -> String? {
        entry(for: event)?.category
    }

    /// Entries of one category in picker order.
    public func entries(forCategory id: String) -> [KeyEntry] {
        entries.filter { $0.category == id }
    }

    /// Events of one category in picker order.
    public func events(forCategory id: String) -> [KarabinerEvent] {
        entries(forCategory: id).map(\.event)
    }

    /// Modifier keys, including `caps_lock`, `fn` and the `*_alt` / `*_gui` aliases.
    public func isModifier(_ event: KarabinerEvent) -> Bool {
        guard case .key(let code) = event else { return false }
        return Self.modifierKeyCodes.contains(code)
    }

    static let modifierKeyCodes: Set<String> = {
        let sides = ["left", "right"]
        let names = ["control", "shift", "option", "command", "alt", "gui"]
        return Set(sides.flatMap { side in names.map { "\(side)_\($0)" } } + ["caps_lock", "fn"])
    }()

    // MARK: Virtual key codes

    /// The key_code an event with macOS virtual key code `virtualKey` (kVK_*) stands for. When Karabiner gives
    /// several names to one code (`f13` and `print_screen`, `insert` and `help`), this is the first in the
    /// picker's order, which is the one macOS apps see the key as.
    public func entry(forVirtualKeyCode virtualKey: Int) -> KeyEntry? {
        keyCodesByVirtualKey[virtualKey]?.first.flatMap { entriesByEvent[.key($0)] }
    }

    /// Every key_code Karabiner maps to `virtualKey`, primary first.
    public func keyCodes(forVirtualKeyCode virtualKey: Int) -> [String] {
        keyCodesByVirtualKey[virtualKey] ?? []
    }

    /// The virtual key code Karabiner uses for a `key_code`; `nil` for events that have none.
    public func virtualKeyCode(for event: KarabinerEvent) -> Int? {
        guard case .key(let code) = event else { return nil }
        return virtualKeyByKeyCode[code]
    }

    /// The primary name of a key that has several (`left_alt` → `left_option`); other events come back unchanged.
    public func canonical(_ event: KarabinerEvent) -> KarabinerEvent {
        guard case .key(let code) = event, let virtualKey = virtualKeyByKeyCode[code],
              let first = keyCodesByVirtualKey[virtualKey]?.first else { return event }
        return .key(first)
    }

    /// `event` followed by every other name the same key arrives as on a Mac (`left_option` and `left_alt`,
    /// `japanese_eisuu` and `lang2`...), so a rebind written under either name is found on the key.
    public func aliases(of event: KarabinerEvent) -> [KarabinerEvent] {
        guard case .key(let code) = event, let virtualKey = virtualKeyByKeyCode[code] else { return [event] }
        return [event] + (keyCodesByVirtualKey[virtualKey] ?? []).filter { $0 != code }.map(KarabinerEvent.key)
    }
}

/// The generated table could not be read.
public enum KeyTableError: Error, Equatable, Sendable {
    case unexpectedFormat
}

/// Finds `KeyTable.json` in a packaged app and in a SwiftPM build.
enum KeyTableResources {
    static let bundleName = "sTools_KeyRebinder.bundle"

    /// `KeyTable.json` in the packaged resource bundle (`Contents/Resources` of an app, or next to the executable
    /// in a SwiftPM build), falling back to `Bundle.module`.
    static func tableURL(mainResourceURL: URL? = Bundle.main.resourceURL) -> URL? {
        if let packaged = locate(mainResourceURL: mainResourceURL) { return packaged }
        return Bundle.module.url(forResource: "KeyTable", withExtension: "json", subdirectory: "Resources")
    }

    /// The table inside `mainResourceURL/sTools_KeyRebinder.bundle`, or `nil` when that bundle is not there.
    static func locate(mainResourceURL: URL?) -> URL? {
        guard let bundleURL = mainResourceURL?.appendingPathComponent(bundleName, isDirectory: true),
              let bundle = Bundle(url: bundleURL) else { return nil }
        return bundle.url(forResource: "KeyTable", withExtension: "json", subdirectory: "Resources")
    }
}
