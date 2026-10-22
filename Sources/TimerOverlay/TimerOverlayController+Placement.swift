import Foundation
import STPlatform

/// Placement mode (spec 5.6.5, plan decision 13): the plate stays up and can be dragged into place, with snapping
/// and the rule guides, or placed by typing X/Y (`settings.offsetX`, `offsetY`).
extension TimerOverlayController {
    /// Whether placement mode is on: the tool is on and "Move by dragging" is.
    public var isPlacing: Bool { isEnabled && settings.placementModeEnabled }

    /// Turns placement mode on or off. On switches the tool on first through `requestEnable`, as Start does, and
    /// stays off when it can't.
    public func setPlacementMode(_ isOn: Bool) {
        settings.placementModeEnabled = isOn
    }
}
