import AppKit
import ApplicationServices

/// Reads Minecraft's windows through the Accessibility API and wakes the locator when anything changes.
///
/// Public API only: window lists come from Accessibility, window numbers from window-server metadata
/// (`CGWindowListCopyWindowInfo`, never window images). Without Accessibility trust it reports no windows.
@MainActor
public final class AXMinecraftSource: MinecraftWindowSource {
    private var continuation: AsyncStream<Void>.Continuation?
    private var stream: AsyncStream<Void>?
    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []

    private static let notifications: [String] = [
        kAXWindowCreatedNotification, kAXUIElementDestroyedNotification, kAXWindowMovedNotification,
        kAXWindowResizedNotification, kAXTitleChangedNotification, kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXApplicationActivatedNotification, kAXApplicationDeactivatedNotification,
    ]

    public init() {}

    isolated deinit {
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }

    public func changes() -> AsyncStream<Void> {
        if let stream { return stream }
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.stream = stream
        self.continuation = continuation
        let center = NSWorkspace.shared.notificationCenter
        // Accessibility lists only the windows on the current Space, so a full-screen game (its own Space) or one on
        // another Space appears only once its Space is the active one: a Space switch reads the windows again, after
        // the switch has finished, which an app activation during it can't.
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        workspaceTokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.continuation?.yield() }
            }
        }
        return stream
    }

    public func snapshot() -> [MinecraftInstance] {
        let javaApps = NSWorkspace.shared.runningApplications.filter { app in
            guard let name = app.executableURL?.lastPathComponent else { return false }
            return MinecraftWindowRules.isJavaExecutable(named: name)
        }
        syncObservers(for: javaApps)
        // Every app switch anywhere lands here; with no Java process there's no Minecraft, so skip the window list,
        // which walks every window on the system.
        guard !javaApps.isEmpty, AXIsProcessTrusted() else { return [] }

        let windowInfo = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        let entries = CGWindowMatcher.entries(from: windowInfo)
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        var result: [MinecraftInstance] = []
        for app in javaApps {
            let pid = app.processIdentifier
            for element in Self.windows(of: pid) {
                guard let window = Self.minecraftWindow(from: element, processID: pid, entries: entries) else { continue }
                result.append(MinecraftInstance(
                    window: window,
                    launchDate: ProcessStartTime.date(for: pid) ?? app.launchDate ?? .distantFuture,
                    isFrontmost: pid == frontmostPID,
                    displayID: DisplayLookup.largestOverlapDisplayID(for: window.frame)))
            }
        }
        return result
    }

    // MARK: Accessibility reading

    private static func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private static func minecraftWindow(from element: AXUIElement, processID: pid_t, entries: [WindowListEntry]) -> MinecraftWindow? {
        guard let title = string(kAXTitleAttribute, of: element), MinecraftWindowRules.isMinecraftTitle(title) else { return nil }
        let origin = point(kAXPositionAttribute, of: element) ?? .zero
        let size = self.size(kAXSizeAttribute, of: element) ?? .zero
        let frame = CGRect(origin: origin, size: size)
        return MinecraftWindow(
            windowNumber: CGWindowMatcher.windowNumber(processID: processID, frame: frame, in: entries) ?? 0,
            processID: processID,
            title: title,
            frame: frame,
            isMinimized: bool(kAXMinimizedAttribute, of: element) ?? false,
            isFullScreen: bool("AXFullScreen", of: element) ?? false)
    }

    private static func string(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ attribute: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func point(_ attribute: String, of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ attribute: String, of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    // MARK: Observers

    /// Keeps one `AXObserver` per running Java process and drops observers of processes that have quit.
    private func syncObservers(for javaApps: [NSRunningApplication]) {
        let live = Set(javaApps.map(\.processIdentifier))
        for pid in observers.keys where !live.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
        }
        guard AXIsProcessTrusted() else { return }
        for pid in live where observers[pid] == nil {
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, _, _, refcon in
                guard let refcon else { return }
                let source = Unmanaged<AXMinecraftSource>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { _ = source.continuation?.yield() }
            }
            guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { continue }
            let app = AXUIElementCreateApplication(pid)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for name in Self.notifications {
                _ = AXObserverAddNotification(observer, app, name as CFString, refcon)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = observer
        }
    }
}
