import CoreGraphics
import Foundation

/// One row of the window server's window list (metadata only).
public struct WindowListEntry: Equatable, Sendable {
    public var number: UInt32
    public var processID: Int32
    public var bounds: CGRect
    public var layer: Int

    public init(number: UInt32, processID: Int32, bounds: CGRect, layer: Int) {
        self.number = number
        self.processID = processID
        self.bounds = bounds
        self.layer = layer
    }
}

/// Maps an Accessibility window to its window server id by process and bounds. Public API only; no window images.
public enum CGWindowMatcher {
    /// Parses `CGWindowListCopyWindowInfo` dictionaries; rows missing a field are skipped.
    public static func entries(from info: [[String: Any]]) -> [WindowListEntry] {
        info.compactMap { row in
            guard let number = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDictionary = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { return nil }
            let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            return WindowListEntry(number: number, processID: pid, bounds: bounds, layer: layer)
        }
    }

    /// The first (front-most) normal-layer window of `processID` whose bounds equal `frame` within `tolerance` points.
    public static func windowNumber(processID: Int32, frame: CGRect, in entries: [WindowListEntry],
                                    tolerance: CGFloat = 1) -> UInt32? {
        entries.first { entry in
            entry.processID == processID && entry.layer == 0
                && abs(entry.bounds.minX - frame.minX) <= tolerance
                && abs(entry.bounds.minY - frame.minY) <= tolerance
                && abs(entry.bounds.width - frame.width) <= tolerance
                && abs(entry.bounds.height - frame.height) <= tolerance
        }?.number
    }
}

public enum DisplayLookup {
    /// The display whose area overlaps `frame` (Core Graphics coordinates) the most; nil when it is on no display.
    public static func largestOverlapDisplayID(for frame: CGRect) -> UInt32? {
        guard !frame.isEmpty else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetDisplaysWithRect(frame, UInt32(ids.count), &ids, &count) == .success, count > 0 else { return nil }
        return ids.prefix(Int(count)).max { lhs, rhs in
            let lhsArea = CGDisplayBounds(lhs).intersection(frame).area
            let rhsArea = CGDisplayBounds(rhs).intersection(frame).area
            return lhsArea < rhsArea
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
