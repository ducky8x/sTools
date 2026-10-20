import Foundation

/// A game action a key can be bound to in Minecraft 1.16.1.
public enum MinecraftAction: Hashable, Sendable {
    case attack, use, forward, strafeLeft, back, strafeRight, jump, sneak, sprint
    case dropItem, inventory, chat, playerList, pickBlock, command, screenshot, perspective
    case cinematicCamera, fullscreen, spectatorOutlines, swapHands, saveHotbar, loadHotbar, advancements
    /// Hotbar slot 1 through 9.
    case hotbar(Int)
    /// Hard-wired keys that are not in `options.txt`.
    case debugScreen, hideHUD, pauseMenu
    /// An `options.txt` key this version does not know (mods, newer versions); holds the id after `key_`.
    case custom(String)

    private static let known: [(id: String, action: MinecraftAction, display: String)] = [
        ("key.attack", .attack, "Attack/Destroy"),
        ("key.use", .use, "Use Item/Place Block"),
        ("key.forward", .forward, "Forward"),
        ("key.left", .strafeLeft, "Left"),
        ("key.back", .back, "Back"),
        ("key.right", .strafeRight, "Right"),
        ("key.jump", .jump, "Jump"),
        ("key.sneak", .sneak, "Sneak"),
        ("key.sprint", .sprint, "Sprint"),
        ("key.drop", .dropItem, "Drop item"),
        ("key.inventory", .inventory, "Inventory"),
        ("key.chat", .chat, "Chat"),
        ("key.playerlist", .playerList, "Player list"),
        ("key.pickItem", .pickBlock, "Pick block"),
        ("key.command", .command, "Command"),
        ("key.screenshot", .screenshot, "Screenshot"),
        ("key.togglePerspective", .perspective, "Perspective"),
        ("key.smoothCamera", .cinematicCamera, "Cinematic camera"),
        ("key.fullscreen", .fullscreen, "Fullscreen"),
        ("key.spectatorOutlines", .spectatorOutlines, "Spectator outlines"),
        ("key.swapOffhand", .swapHands, "Swap hands"),
        ("key.swapHands", .swapHands, "Swap hands"),
        ("key.saveToolbarActivator", .saveHotbar, "Save hotbar"),
        ("key.loadToolbarActivator", .loadHotbar, "Load hotbar"),
        ("key.advancements", .advancements, "Advancements"),
    ]

    /// The action for an `options.txt` id such as `key.attack` (case-sensitive, as Minecraft writes it).
    public init(optionsID id: String) {
        if let match = Self.known.first(where: { $0.id == id }) {
            self = match.action
        } else if id.hasPrefix("key.hotbar."), let slot = Int(id.dropFirst("key.hotbar.".count)), (1...9).contains(slot) {
            self = .hotbar(slot)
        } else {
            self = .custom(id)
        }
    }

    /// The short label drawn on a key.
    public var displayName: String {
        switch self {
        case .hotbar(let slot): "Hotbar \(slot)"
        case .debugScreen: "Debug screen"
        case .hideHUD: "Hide HUD"
        case .pauseMenu: "Pause menu"
        case .custom(let id): id
        default: Self.known.first { $0.action == self }?.display ?? ""
        }
    }
}

/// One Minecraft key binding.
public struct MinecraftKeybind: Hashable, Sendable {
    public var action: MinecraftAction
    /// The label shown on the diagram, e.g. "Attack/Destroy".
    public var display: String
    /// The Karabiner event the game receives; `nil` when unbound or when Karabiner has no name for the key.
    public var event: KarabinerEvent?
    /// The key exactly as the file spells it (`key.keyboard.e`, `-100`), for keys with no `event`.
    public var minecraftKey: String

    public init(action: MinecraftAction, display: String? = nil, event: KarabinerEvent?, minecraftKey: String = "key.keyboard.unknown") {
        self.action = action
        self.display = display ?? action.displayName
        self.event = event
        self.minecraftKey = minecraftKey
    }
}

/// Reads the key bindings of a Minecraft `options.txt`.
public enum MinecraftKeybinds {
    /// Keys the game hard-wires, so they never appear in `options.txt`: F3 (debug screen), F1 (hide HUD),
    /// Escape (pause menu).
    public static let fixedKeybinds: [MinecraftKeybind] = [
        MinecraftKeybind(action: .debugScreen, event: .key("f3"), minecraftKey: "key.keyboard.f3"),
        MinecraftKeybind(action: .hideHUD, event: .key("f1"), minecraftKey: "key.keyboard.f1"),
        MinecraftKeybind(action: .pauseMenu, event: .key("escape"), minecraftKey: "key.keyboard.escape"),
    ]

    /// Parses `key_<id>:<key>` lines (1.16.1 names, or the numeric codes of 1.12 and older), in file order,
    /// then appends `fixedKeybinds`. Older versions hard-wire Fullscreen to F11, so when the file has no
    /// `key.fullscreen` line, that fixed key is appended too. Every other line is ignored.
    public static func parse(optionsText: String) -> [MinecraftKeybind] {
        var result: [MinecraftKeybind] = []
        for rawLine in optionsText.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("key_"), let colon = line.firstIndex(of: ":") else { continue }
            let id = String(line[line.index(line.startIndex, offsetBy: 4)..<colon])
            guard !id.isEmpty else { continue }
            let parts = line[line.index(after: colon)...].split(separator: ":", omittingEmptySubsequences: false)
            let key = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            let hasModifier = parts.count > 1 && parts[1].trimmingCharacters(in: .whitespaces).uppercased() != "NONE"
            let action = MinecraftAction(optionsID: id)
            result.append(MinecraftKeybind(
                action: action, event: hasModifier ? nil : event(forKey: key), minecraftKey: key.isEmpty ? "key.keyboard.unknown" : key))
        }
        if !result.contains(where: { $0.action == .fullscreen }) {
            result.append(MinecraftKeybind(action: .fullscreen, event: .key("f11"), minecraftKey: "key.keyboard.f11"))
        }
        return result + fixedKeybinds
    }

    private static func event(forKey key: String) -> KarabinerEvent? {
        if let code = Int(key) { return MinecraftKeyNames.event(forLegacyCode: code) }
        return MinecraftKeyNames.event(forName: key)
    }

    /// `options.txt` inside `gameDirectory`, or inside its `.minecraft` / `minecraft` subfolder (launcher
    /// instance folders), checked in that order. `nil` when no file exists.
    public static func locateOptionsFile(
        gameDirectory: URL,
        fileExists: (URL) -> Bool = { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    ) -> URL? {
        let candidates = [
            gameDirectory,
            gameDirectory.appending(path: ".minecraft", directoryHint: .isDirectory),
            gameDirectory.appending(path: "minecraft", directoryHint: .isDirectory),
        ]
        return candidates.map { $0.appending(path: "options.txt") }.first(where: fileExists)
    }
}
