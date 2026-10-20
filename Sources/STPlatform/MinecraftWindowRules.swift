import Foundation

/// Decides which windows are Minecraft: Java Edition game windows.
public enum MinecraftWindowRules {
    /// The version token of a game window title: "Minecraft 1.16.1", "Minecraft* 1.16.1 - Singleplayer",
    /// "Minecraft* 24w14a". Titles that merely start with "Minecraft" ("Minecraft Launcher", a browser tab) have no version.
    public static func version(fromTitle title: String) -> String? {
        guard title.hasPrefix("Minecraft") else { return nil }
        var rest = title.dropFirst("Minecraft".count)
        if rest.first == "*" { rest = rest.dropFirst() }
        guard rest.first == " " else { return nil }
        let token = rest.dropFirst().prefix { !$0.isWhitespace }
        guard let first = token.first, first.isASCII, first.isNumber else { return nil }
        return String(token)
    }

    public static func isMinecraftTitle(_ title: String) -> Bool {
        version(fromTitle: title) != nil
    }

    /// Minecraft runs inside a Java process; Ninjabrain Bot is Java too, but its window title never matches.
    public static func isJavaExecutable(named name: String) -> Bool {
        name == "java" || name == "javaw"
    }
}
