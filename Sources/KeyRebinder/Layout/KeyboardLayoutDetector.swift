import Carbon.HIToolbox
import Foundation
import IOKit.ps

/// The layout to preselect when sTools first asks which keyboard to draw (spec 5.5.2).
public enum KeyboardLayoutDetector {
    /// What macOS says the current keyboard is.
    public static func detectedShape() -> KeyboardShape {
        shape(forLayoutType: KBGetLayoutType(Int16(LMGetKbdType())))
    }

    /// Laptop when this Mac has an internal battery, full-size otherwise. (`hw.model` can't tell: Apple
    /// silicon laptops report `Mac14,2`-style names.)
    public static func detectedFormFactor() -> KeyboardFormFactor {
        hasInternalBattery() ? .laptop : .fullSize
    }

    static func shape(forLayoutType type: UInt32) -> KeyboardShape {
        switch Int(type) {
        case kKeyboardISO: .iso
        case kKeyboardJIS: .jis
        default: .ansi
        }
    }

    private static func hasInternalBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }
}
