import CoreGraphics
import Foundation

public struct MinecraftWindow: Equatable, Sendable {
    /// The window server's id for this window (0 when it could not be matched).
    public var windowNumber: UInt32
    public var processID: Int32
    public var title: String
    /// Core Graphics global coordinates (top-left origin).
    public var frame: CGRect
    public var isMinimized: Bool
    public var isFullScreen: Bool

    public init(windowNumber: UInt32, processID: Int32, title: String, frame: CGRect,
                isMinimized: Bool = false, isFullScreen: Bool = false) {
        self.windowNumber = windowNumber
        self.processID = processID
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
    }
}

public struct MinecraftInstance: Identifiable, Equatable, Sendable {
    public var id: Int32 { window.processID }
    public var window: MinecraftWindow
    /// When the Java process started; "the one opened first" wins ties.
    public var launchDate: Date
    /// Whether this instance's app is the frontmost application.
    public var isFrontmost: Bool
    /// The display the window mostly sits on, if any.
    public var displayID: UInt32?

    public init(window: MinecraftWindow, launchDate: Date, isFrontmost: Bool = false, displayID: UInt32? = nil) {
        self.window = window
        self.launchDate = launchDate
        self.isFrontmost = isFrontmost
        self.displayID = displayID
    }

    public var version: String? { MinecraftWindowRules.version(fromTitle: window.title) }
}

public enum InstanceConflict: Equatable, Sendable {
    case none
    /// More than one Minecraft window is open; `followingVersion` is the version of the one being followed.
    case multiple(count: Int, followingVersion: String?)
}

public struct InstanceSelection: Equatable, Sendable {
    public var active: MinecraftInstance?
    public var others: [MinecraftInstance]
    public var conflict: InstanceConflict

    public init(active: MinecraftInstance?, others: [MinecraftInstance], conflict: InstanceConflict) {
        self.active = active
        self.others = others
        self.conflict = conflict
    }

    /// Every instance, followed one first.
    public var all: [MinecraftInstance] { (active.map { [$0] } ?? []) + others }
}

public enum InstanceSelector {
    /// Rule R11: prefer instances running `preferredVersion`; among equals the one opened first;
    /// when none match, the one opened first overall. Ties break on process id so the choice is deterministic.
    public static func select(from instances: [MinecraftInstance], preferredVersion: String = "1.16.1") -> InstanceSelection {
        let ordered = instances.sorted { lhs, rhs in
            let lhsPreferred = lhs.version == preferredVersion
            let rhsPreferred = rhs.version == preferredVersion
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            if lhs.launchDate != rhs.launchDate { return lhs.launchDate < rhs.launchDate }
            return lhs.id < rhs.id
        }
        guard let active = ordered.first else {
            return InstanceSelection(active: nil, others: [], conflict: .none)
        }
        let conflict: InstanceConflict = ordered.count > 1
            ? .multiple(count: ordered.count, followingVersion: active.version)
            : .none
        return InstanceSelection(active: active, others: Array(ordered.dropFirst()), conflict: conflict)
    }
}
