import CoreGraphics
import Foundation
@testable import STPlatform

/// Stands in for the window server: it keeps what's registered by name and records every apply, restore and read, and
/// never touches the real pointer.
@MainActor
final class FakeCursorSwapper: CursorSwapping {
    enum Call: Equatable {
        case read(String)
        case apply
        case restore
    }

    var isSupported: Bool
    /// What's registered now, by name: macOS 27.2's two arrow names until something is applied.
    private(set) var current: [String: RegisteredCursor] = FakeCursorSwapper.systemArrows
    private(set) var calls: [Call] = []
    private(set) var applied: [CursorImage] = []
    private(set) var restored: [[RegisteredCursor]] = []
    /// Run during an apply or a restore, so a test can look at the marker at that moment.
    var duringApply: (() -> Void)?
    var duringRestore: (() -> Void)?

    static let systemArrows: [String: RegisteredCursor] = Dictionary(uniqueKeysWithValues: CursorNames.arrow.prefix(2).map {
        ($0, RegisteredCursor.systemArrow(name: $0))
    })

    init(isSupported: Bool = true) {
        self.isSupported = isSupported
    }

    var applyCount: Int { applied.count }
    var restoreCount: Int { restored.count }

    func registered(_ name: String) -> RegisteredCursor? {
        calls.append(.read(name))
        return current[name]
    }

    func apply(_ cursor: CursorImage, names: [String]) {
        calls.append(.apply)
        applied.append(cursor)
        duringApply?()
        for name in names {
            current[name] = RegisteredCursor(name: name, size: cursor.size, hotSpot: cursor.hotSpot, frameCount: 1, frameDuration: 0,
                                             images: cursor.images)
        }
    }

    func restore(_ originals: [RegisteredCursor]) {
        calls.append(.restore)
        restored.append(originals)
        duringRestore?()
        current = Self.systemArrows
        for original in originals { current[original.name] = original }
    }
}

extension RegisteredCursor {
    /// A stand-in for macOS 27's arrow: 28 × 40 points, clicking at 5, 5, with four images.
    static func systemArrow(name: String) -> RegisteredCursor {
        RegisteredCursor(name: name, size: CGSize(width: 28, height: 40), hotSpot: CGPoint(x: 5, y: 5), frameCount: 1, frameDuration: 0,
                         images: [1, 2, 3, 4].map { makeImage(width: 28 * $0, height: 40 * $0) })
    }
}

/// A `width` × `height` opaque red image.
func makeImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// A plain 12 × 12 pointer at every scale.
func makeCursor() -> CursorImage {
    CursorImage(size: CGSize(width: 12, height: 12), hotSpot: CGPoint(x: 6, y: 6),
                images: CursorImage.scales.map { makeImage(width: 12 * $0, height: 12 * $0) })
}

func pointerTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "sTools-pointer-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
