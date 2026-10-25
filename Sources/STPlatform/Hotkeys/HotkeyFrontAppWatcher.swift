import AppKit
import Observation

/// Which app is in front. The app's is `WorkspaceFrontmostApp`; tests use a fake they switch by hand.
@MainActor
public protocol FrontmostAppObserving: AnyObject {
    /// The process id of the app in front, or nil when there is none.
    var frontmostProcessID: Int32? { get }
    /// Called after each switch, once `frontmostProcessID` reads the new app.
    var onChange: (@MainActor () -> Void)? { get set }
}

/// Follows NSWorkspace's activations: one notification per app switch, nothing polled.
@MainActor
public final class WorkspaceFrontmostApp: FrontmostAppObserving {
    public private(set) var frontmostProcessID: Int32?
    public var onChange: (@MainActor () -> Void)?
    private var token: NSObjectProtocol?

    public init() {
        frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated { self?.switched(to: pid) }
        }
    }

    isolated deinit {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    private func switched(to pid: Int32?) {
        frontmostProcessID = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        onChange?()
    }
}

/// Tells a `HotkeyCenter` which app is in front, for Where hotkeys work (spec 6.1): sTools itself, a Minecraft
/// instance the locator knows, or another app. Event driven: it sorts the app again on each app switch and each
/// change to the locator's instances (a window that opens while its game is already in front), never on a timer.
///
/// Minecraft is recognized by its process, from the locator's instances, so recognizing it needs Accessibility, as
/// every tool a hotkey switches does; without it, hotkeys work only in sTools under the default. A game's process,
/// once listed, counts until it quits: the locator lists only the windows Accessibility can read right now, and a
/// full-screen game on its own Space, or a game on another Space, drops out of that list while you're elsewhere, so
/// switching back to it (⌘-Tab, a Spaces swipe) would otherwise find its hotkeys unregistered.
@MainActor
public final class HotkeyFrontAppWatcher {
    private let center: HotkeyCenter
    private let frontmost: any FrontmostAppObserving
    private let minecraft: MinecraftLocator
    private let ownProcessID: Int32
    private let isRunning: @MainActor (Int32) -> Bool
    private var isFollowingMinecraft = false
    /// Every Minecraft process the locator has listed whose process still runs (`isRunning`).
    private var minecraftProcesses: Set<Int32> = []

    /// - Parameter isRunning: whether a process still runs, so a game that quit is forgotten (and a later process
    ///   with its number isn't taken for Minecraft). The app's asks `NSRunningApplication`; tests pass a fake.
    public init(center: HotkeyCenter, frontmost: any FrontmostAppObserving, minecraft: MinecraftLocator,
                ownProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
                isRunning: @escaping @MainActor (Int32) -> Bool = HotkeyFrontAppWatcher.processIsRunning) {
        self.center = center
        self.frontmost = frontmost
        self.minecraft = minecraft
        self.ownProcessID = ownProcessID
        self.isRunning = isRunning
    }

    /// Tells the center about the app in front now, then after every switch. Calling it twice is harmless.
    public func start() {
        frontmost.onChange = { [weak self] in self?.update() }
        if !isFollowingMinecraft { followMinecraft() }
        update()
    }

    /// Sorts the app in front again and tells the center: remembers the games the locator lists now, forgets the ones
    /// that quit.
    public func update() {
        minecraftProcesses.formUnion(minecraft.instances.map(\.window.processID))
        minecraftProcesses = minecraftProcesses.filter(isRunning)
        center.setFrontApp(Self.sort(frontmost.frontmostProcessID, ownProcessID: ownProcessID,
                                     minecraftProcesses: minecraftProcesses))
    }

    /// sTools when `pid` is sTools' own process, Minecraft when it is one of `minecraft`'s processes, else other.
    public static func sort(_ pid: Int32?, ownProcessID: Int32, minecraft: [MinecraftInstance]) -> HotkeyFrontApp {
        sort(pid, ownProcessID: ownProcessID, minecraftProcesses: Set(minecraft.map(\.window.processID)))
    }

    /// sTools when `pid` is sTools' own process, Minecraft when it is one of `minecraftProcesses`, else other.
    public static func sort(_ pid: Int32?, ownProcessID: Int32, minecraftProcesses: Set<Int32>) -> HotkeyFrontApp {
        guard let pid else { return .other }
        if pid == ownProcessID { return .sTools }
        return minecraftProcesses.contains(pid) ? .minecraft : .other
    }

    /// Whether `pid` belongs to an app that still runs: the app's check that a remembered game hasn't quit.
    public nonisolated static func processIsRunning(_ pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false
    }

    /// Re-arms itself after each change, one main-actor turn later, once the locator has its new instances.
    private func followMinecraft() {
        isFollowingMinecraft = true
        withObservationTracking {
            _ = minecraft.instances
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                update()
                followMinecraft()
            }
        }
    }
}
