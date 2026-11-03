import NBBOverlay
import STPlatform

extension AppModel {
    /// Home's checks (spec 3.5): Karabiner-Elements and its profiles through `karabiner_cli`, and, while the NBB Overlay is
    /// off, one look at Ninjabrain Bot's API. Home runs them as it appears and as sTools comes to the front, and nothing
    /// runs them on a timer. Minecraft, Accessibility and a running NBB Overlay report on their own.
    func refreshHomeStatuses() async {
        async let karabiner: Void = refreshKarabinerForHome()
        async let ninjabrainBot: Void = refreshNinjabrainBotForHome()
        _ = await (karabiner, ninjabrainBot)
    }

    private func refreshKarabinerForHome() async {
        await keyRebinder?.refreshStatus()
    }

    private func refreshNinjabrainBotForHome() async {
        guard runningNBBOverlay == nil else { return }
        let answers = await pingNinjabrainBot()
        if ninjabrainAnswers != answers { ninjabrainAnswers = answers }
    }

    /// The NBB Overlay's controller while the tool is on, which knows whether Ninjabrain Bot is linked.
    private var runningNBBOverlay: NBBOverlayController? {
        guard isOn(.nbbOverlay) else { return nil }
        return controller(for: .nbbOverlay, as: NBBOverlayController.self)
    }

    /// What one of Home's status visuals shows now.
    func homeLamp(_ kind: HomeLampKind) -> HomeLamp {
        switch kind {
        case .minecraft:
            return HomeLamps.minecraft(
                active: minecraft.active, others: Array(minecraft.instances.dropFirst()), conflict: minecraft.conflict,
                displays: displays.displays, accessibilityGranted: accessibilityGranted)
        case .ninjabrainBot:
            let overlay = runningNBBOverlay
            return HomeLamps.ninjabrainBot(overlayIsOn: overlay != nil, reachable: overlay?.isReachable ?? false,
                                           readsWindow: overlay?.readsWindow ?? false, answers: ninjabrainAnswers)
        case .karabiner:
            let requirement = keyRebinder?.requirement
            return HomeLamps.karabiner(requirement, profile: requirement == .ready ? keyRebinder?.currentProfile : nil)
        }
    }
}
