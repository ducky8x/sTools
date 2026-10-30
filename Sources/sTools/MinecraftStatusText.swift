import Foundation
import STPlatform

/// The sentences Home uses for the Minecraft dependency (rule R11 wording).
enum MinecraftStatusText {
    /// The version the locator prefers; mirrors `MinecraftLocator`'s default.
    static let preferredVersion = "1.16.1"

    static func isConflict(_ conflict: InstanceConflict) -> Bool {
        if case .multiple = conflict { return true }
        return false
    }

    /// - Parameters:
    ///   - active: The instance the tools follow.
    ///   - others: The instances they do not follow.
    static func make(active: MinecraftInstance?, others: [MinecraftInstance], conflict: InstanceConflict,
                     displays: [DisplayInfo], accessibilityGranted: Bool) -> String {
        guard accessibilityGranted else { return "sTools can\u{2019}t look for Minecraft until Accessibility is allowed." }
        guard let active else { return "Minecraft isn\u{2019}t running." }
        if case .multiple(let count, let followingVersion) = conflict {
            return "\(count) Minecraft windows are open. Following \(followed(followingVersion, others: others))."
        }
        let name = active.version.map { "Minecraft \($0)" } ?? "Minecraft"
        guard let displayName = active.displayID.flatMap({ id in displays.first { $0.id == id }?.name }) else {
            return "\(name) is open."
        }
        return "\(name) is open on \(displayName)."
    }

    /// "1.16.1 (opened first)", or "1.16.1 (the preferred version)" when only the version decided.
    private static func followed(_ version: String?, others: [MinecraftInstance]) -> String {
        guard let version else { return "the one opened first" }
        let decidedByVersion = version == preferredVersion && !others.contains { $0.version == preferredVersion }
        return "\(version) (\(decidedByVersion ? "the preferred version" : "opened first"))"
    }
}
