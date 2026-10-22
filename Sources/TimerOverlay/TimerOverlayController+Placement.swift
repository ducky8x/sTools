import Foundation
import STPlatform

/// Placement mode (spec 5.6.5, plan decision 13): the plate stays up and can be dragged into place, with snapping
/// and the rule guides, or placed by typing X/Y (`settings.offsetX`, `offsetY`).
///
/// - Idle, the plate shows the saved duration as a sample; a countdown that starts meanwhile counts on the same
///   plate, and when it ends the plate shows the sample again instead of leaving.
/// - Turning placement mode on switches the tool on first, as Start does; turning the tool off turns it off.
/// - The rule guides exist only from a drag's start to its end. Their zones are worked out once per drag (and again
///   only if the display changes during it); each move only asks which zones the plate covers.
/// - Test and placement mode ignore the focus settings (decision 8).
extension TimerOverlayController {
    /// Whether placement mode is on: the tool is on and "Move by dragging" is.
    public var isPlacing: Bool { isEnabled && settings.placementModeEnabled }

    /// Turns placement mode on or off. On switches the tool on first through `requestEnable`, as Start does, and
    /// stays off when it can't.
    public func setPlacementMode(_ isOn: Bool) {
        settings.placementModeEnabled = isOn
    }

    /// "Move by dragging" changed: on, the plate takes the mouse (switching the tool on first); off, it's
    /// click-through again and a drag under way ends where it started.
    func placementSettingChanged() {
        if settings.placementModeEnabled {
            guard switchOn() else {
                settings.placementModeEnabled = false
                services.settings.save(settings)
                return
            }
            presenter.setPlacementMode(true, onDragChanged: { [weak self] in self?.dragChanged(by: $0) },
                                       onDragEnded: { [weak self] in self?.dragEnded() })
        } else {
            cancelDrag()
            presenter.setPlacementMode(false, onDragChanged: { _ in }, onDragEnded: {})
        }
    }

    /// The plate is dragged by `translation` from where the drag started (screen points, +x right, +y down).
    func dragChanged(by translation: CGSize) {
        guard isPlacing, isOverlayUp else { return }
        if drag == nil {
            guard let start = presenter.plateFrame, let display = targetDisplay() else { return }
            drag = PlacementDrag(startFrame: start, display: display, frame: start)
            showGuides()
        }
        guard var current = drag else { return }
        current.frame = current.startFrame.offsetBy(dx: translation.width, dy: -translation.height)
        drag = current
        presenter.move(plateFrame: current.frame, displayFrame: current.display.frame)
        markCovered()
    }

    /// The drag ends: the plate settles (snapped when snapping is on, kept inside the display) and its offset is
    /// saved. The guides go.
    func dragEnded() {
        guard let current = drag else { return }
        drag = nil
        if current.zones != nil { guides.hide() }
        let settled = TimerPlacement.settle(current.frame, on: current.display, snapping: settings.snappingEnabled)
        presenter.move(plateFrame: settled.frame, displayFrame: current.display.frame)
        placedAt = (settled.offset, current.display.frame)
        setDangerEdge(false)
        var placed = settings
        placed.offsetX = settled.offset.x
        placed.offsetY = settled.offset.y
        settings = placed
    }

    /// Minecraft or the displays changed. During a drag onto another display, the guides follow it.
    func placementEnvironmentChanged() {
        guard var current = drag, let display = targetDisplay(), display != current.display else { return }
        current.display = display
        drag = current
        showGuides()
        markCovered()
    }

    /// Ends a drag without saving where it got to, as when placement mode goes off during one.
    private func cancelDrag() {
        guard let current = drag else { return }
        drag = nil
        if current.zones != nil { guides.hide() }
        setDangerEdge(false)
        // The plate goes back to its stored offset.
        placedAt = nil
    }

    /// Outlines the rule zones on the drag's display, when the guides are on.
    private func showGuides() {
        guard var current = drag else { return }
        current.zones = nil
        if settings.showsRuleGuides {
            let zones = RuleZones(settings: settings, display: current.display, minecraft: services.minecraft.active?.window)
            current.zones = zones
            guides.show(zones, on: current.display)
        }
        drag = current
    }

    /// Which zones the plate covers now: the guides mark them and the plate's edge turns `danger`.
    private func markCovered() {
        guard let current = drag, let zones = current.zones else { return }
        let covered = zones.covered(by: current.frame)
        guides.markCovered(covered, plateFrame: current.frame)
        setDangerEdge(!covered.isEmpty)
    }

    private func setDangerEdge(_ isOn: Bool) {
        guard isOn != showsDangerEdge else { return }
        showsDangerEdge = isOn
        refreshContent(at: clock.now())
    }
}

/// A drag of the plate in placement mode, from its start to its end.
struct PlacementDrag {
    /// The plate's frame when the drag started.
    let startFrame: CGRect
    /// The display it's dragged on.
    var display: DisplayInfo
    /// The rule zones on that display, while the guides are on.
    var zones: RuleZones?
    /// Where the plate is now.
    var frame: CGRect

    init(startFrame: CGRect, display: DisplayInfo, frame: CGRect) {
        self.startFrame = startFrame
        self.display = display
        self.frame = frame
    }
}
