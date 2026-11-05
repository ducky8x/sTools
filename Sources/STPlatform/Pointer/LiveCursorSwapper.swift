import AppKit
import CoreGraphics
import Darwin

/// Swaps the pointer through the window server's private calls, the ones other cursor tools use (spec 5.7.1). They're
/// looked up by name when sTools starts, in CoreGraphics and then HIServices, and never linked, so a macOS without them
/// still opens sTools; the Crosshair then says it can't be the pointer there.
///
/// What this registers stays after sTools quits, for every app, until it's restored or the person logs out. Only the app's
/// own wiring builds one, through the factory beside `CursorSwapping`; a test that names this type fails
/// (`LiveSwapperGuardTests`), and inside a test process it does nothing at all.
@MainActor
final class LiveCursorSwapper: CursorSwapping {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias Register = @convention(c) (
        Int32, UnsafePointer<CChar>, Bool, Bool, CGSize, CGPoint, UInt, CGFloat, CFArray, UnsafeMutablePointer<Int32>) -> Int32
    private typealias CopyRegistered = @convention(c) (
        Int32, UnsafePointer<CChar>, UnsafeMutablePointer<CGSize>, UnsafeMutablePointer<CGPoint>, UnsafeMutablePointer<UInt>,
        UnsafeMutablePointer<CGFloat>, UnsafeMutablePointer<Unmanaged<CFArray>?>) -> Int32
    private typealias SetRegistered = @convention(c) (Int32, UnsafePointer<CChar>, UnsafeMutablePointer<Int32>) -> Int32
    private typealias ConnectionOnly = @convention(c) (Int32) -> Int32
    private typealias ConnectionAndNumber = @convention(c) (Int32, Int32) -> Int32
    private typealias ConnectionAndFlag = @convention(c) (Int32, Bool) -> Void
    private typealias GetScale = @convention(c) (Int32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetScale = @convention(c) (Int32, Float) -> Int32

    private struct Calls {
        let mainConnection: MainConnection
        let register: Register
        let copyRegistered: CopyRegistered
        let setRegistered: SetRegistered
        let unregisterAll: ConnectionOnly
        let setCoreCursor: ConnectionAndNumber
        let setSystemDefined: ConnectionAndNumber
        let dockOverride: ConnectionAndFlag
        let getScale: GetScale
        let setScale: SetScale
    }

    /// The core cursors macOS numbers 0 to 43; a restore sets each back.
    private static let coreCursors: ClosedRange<Int32> = 0...43
    private static let log = STLog.logger("Pointer")

    private let calls: Calls?

    init() {
        calls = Self.isInTestProcess ? nil : Self.lookUp()
        if calls == nil { Self.log.notice("The pointer calls are missing, so the pointer can't be swapped here") }
    }

    var isSupported: Bool { calls != nil }

    func registered(_ name: String) -> RegisteredCursor? {
        guard let calls else { return nil }
        var size = CGSize.zero, hotSpot = CGPoint.zero, frames: UInt = 0, duration: CGFloat = 0
        var array: Unmanaged<CFArray>?
        guard calls.copyRegistered(calls.mainConnection(), name, &size, &hotSpot, &frames, &duration, &array) == 0,
              let array else { return nil }
        let images = (array.takeRetainedValue() as [AnyObject]).compactMap { object -> CGImage? in
            guard CFGetTypeID(object) == CGImage.typeID else { return nil }
            return (object as! CGImage)
        }
        guard !images.isEmpty else { return nil }
        return RegisteredCursor(name: name, size: size, hotSpot: hotSpot, frameCount: Int(frames), frameDuration: duration,
                                images: images)
    }

    func apply(_ cursor: CursorImage, names: [String]) {
        guard let calls else { return }
        let connection = calls.mainConnection()
        for name in names {
            var seed: Int32 = 0
            let registered = calls.register(connection, name, true, true, cursor.size, cursor.hotSpot, 1, 0,
                                            cursor.images as CFArray, &seed)
            let set = calls.setRegistered(connection, name, &seed)
            Self.log.notice("Applied the pointer as \(name, privacy: .public): register \(registered), set \(set)")
        }
        calls.dockOverride(connection, true)
        redraw(calls, connection)
    }

    func restore(_ originals: [RegisteredCursor]) {
        guard let calls else { return }
        let connection = calls.mainConnection()
        _ = calls.unregisterAll(connection)
        for number in Self.coreCursors { _ = calls.setCoreCursor(connection, number) }
        for original in originals {
            var seed: Int32 = 0
            let registered = calls.register(
                connection, original.name, true, true, original.size, original.hotSpot, UInt(max(original.frameCount, 1)),
                original.frameDuration, original.images as CFArray, &seed)
            _ = calls.setRegistered(connection, original.name, &seed)
            Self.log.notice("Restored \(original.name, privacy: .public): register \(registered)")
        }
        _ = calls.setSystemDefined(connection, 0)
        calls.dockOverride(connection, false)
        redraw(calls, connection)
        Self.log.notice("Restored the pointer")
    }

    /// Nudges the pointer's scale up and back so the window server draws the new images, then asks for the arrow.
    private func redraw(_ calls: Calls, _ connection: Int32) {
        var scale: Float = 1
        if calls.getScale(connection, &scale) == 0 {
            _ = calls.setScale(connection, scale + 0.1)
            _ = calls.setScale(connection, scale)
        }
        _ = calls.setSystemDefined(connection, 0)
    }

    // MARK: Looking the calls up

    private static func lookUp() -> Calls? {
        let paths: [String] = [
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
        ]
        let libraries = paths.compactMap { path in dlopen(path, RTLD_LAZY) }
        func find<T>(_ name: String, as type: T.Type) -> T? {
            for library in libraries {
                if let symbol = dlsym(library, name) { return unsafeBitCast(symbol, to: type) }
            }
            log.notice("Pointer call \(name, privacy: .public) not found")
            return nil
        }
        guard let mainConnection = find("CGSMainConnectionID", as: MainConnection.self),
              let register = find("CGSRegisterCursorWithImages", as: Register.self),
              let copyRegistered = find("CGSCopyRegisteredCursorImages", as: CopyRegistered.self),
              let setRegistered = find("CGSSetRegisteredCursor", as: SetRegistered.self),
              let unregisterAll = find("CoreCursorUnregisterAll", as: ConnectionOnly.self),
              let setCoreCursor = find("CoreCursorSet", as: ConnectionAndNumber.self),
              let setSystemDefined = find("CGSSetSystemDefinedCursor", as: ConnectionAndNumber.self),
              let dockOverride = find("CGSSetDockCursorOverride", as: ConnectionAndFlag.self),
              let getScale = find("CGSGetCursorScale", as: GetScale.self),
              let setScale = find("CGSSetCursorScale", as: SetScale.self) else { return nil }
        return Calls(mainConnection: mainConnection, register: register, copyRegistered: copyRegistered,
                     setRegistered: setRegistered, unregisterAll: unregisterAll, setCoreCursor: setCoreCursor,
                     setSystemDefined: setSystemDefined, dockOverride: dockOverride, getScale: getScale, setScale: setScale)
    }

    /// A test run: the XCTest or Swift Testing runner, or XCTest loaded into the process.
    private static var isInTestProcess: Bool {
        let process = ProcessInfo.processInfo
        let environment = process.environment
        return ["xctest", "swiftpm-testing-helper"].contains(process.processName)
            || environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil || NSClassFromString("XCTestCase") != nil
    }
}
