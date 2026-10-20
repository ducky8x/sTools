import STPlatform

/// Decides, from the current Minecraft/display state, which displays should show a backdrop panel and
/// what each one orders itself directly below (spec 5.2.1, 5.2.2). A pure function of its inputs, so the
/// re-ordering state machine can be pinned down with synthetic events instead of a real window server.
enum BackdropOrdering {
    /// What a single covered display's panel should do right now.
    struct DisplayPlan: Equatable {
        var displayID: UInt32
        var isVisible: Bool
        /// The window number the panel orders itself directly below, when `isVisible`.
        var orderBelowWindowNumber: UInt32?
    }

    /// - Parameters:
    ///   - coveredDisplayIDs: Minecraft's own display plus any additional ones the user checked.
    ///   - minecraft: The followed instance's window, or nil when no instance is running.
    ///   - minecraftDisplayID: The display `minecraft` mostly sits on.
    ///   - isMinecraftFocused: Whether Minecraft's app is currently frontmost.
    ///   - hideOnFullScreenScope: Whether a full-screen Minecraft hides just its own display's backdrop
    ///     or every covered display's.
    ///   - hidesWhenMinecraftNotFocused: An independent restriction (not an alternative to being "on"):
    ///     every covered display hides whenever Minecraft isn't the frontmost app, same setting shape
    ///     as Crosshair's and NBB Overlay's focus restriction.
    static func plan(
        coveredDisplayIDs: [UInt32],
        minecraft: MinecraftWindow?,
        minecraftDisplayID: UInt32?,
        isMinecraftFocused: Bool,
        hideOnFullScreenScope: BackdropSettings.FullScreenScope,
        hidesWhenMinecraftNotFocused: Bool = false
    ) -> [DisplayPlan] {
        guard let minecraft, !minecraft.isMinimized, !(hidesWhenMinecraftNotFocused && !isMinecraftFocused) else {
            return coveredDisplayIDs.map { DisplayPlan(displayID: $0, isVisible: false, orderBelowWindowNumber: nil) }
        }
        return coveredDisplayIDs.map { displayID in
            let isMinecraftDisplay = displayID == minecraftDisplayID
            let hidden = minecraft.isFullScreen && (hideOnFullScreenScope == .allDisplays || isMinecraftDisplay)
            return DisplayPlan(
                displayID: displayID, isVisible: !hidden,
                orderBelowWindowNumber: hidden ? nil : minecraft.windowNumber)
        }
    }
}
