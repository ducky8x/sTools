import KeyRebinder
import STDesign
import STPlatform
import SwiftUI

/// The Key Rebinder on Home: its number, name and status, a key cap bottom left as on every tile, and
/// Karabiner-Elements' profiles as chips beside the cap, with the current one filled.
///
/// One click on a chip switches Karabiner-Elements to that profile through the switch profile hotkeys use
/// (`KeyRebinderController.switchProfile(for:)`), which loads nothing while the page is closed. Each chip shows its
/// profile's own hotkey, when it has one and there's room, as a small legend, and its menu sets that key in place (Set
/// Key…, then the key) or removes it, with the tool pages' refusals and words. The key cap is Next profile's own
/// hotkey, recorded in place as on every tile; it waits until a profile can be switched to, unless it already has a
/// key.
///
/// The chips wrap beside the cap into the room the tile has, sitting on its bottom row while they fit. A long name is
/// cut to stay apart from the others, whole in its help tag and for VoiceOver, and profiles past the tile's room
/// scroll. Until a profile can be switched to, a line says why, and the tile opens the page where Karabiner-Elements
/// is set up. Clicking the tile opens the Key Rebinder.
///
/// The profiles are the Key Rebinder's one read of them (`profiles`, refreshed by `refreshProfiles()` as Home appears).
struct HomeKeyRebinderTile: View {
    let model: AppModel

    @Environment(\.stTheme) private var theme
    @Environment(\.homeTilesAreTight) private var isTight
    @Environment(\.stSoundPlayer) private var sound
    @State private var isHovering = false
    /// Why the last click didn't switch the profile, until the next click.
    @State private var switchError: String?
    /// The chips' height and the room they're shown in, to fade the last row out while there are more to scroll to.
    @State private var chipsHeight: CGFloat = 0
    @State private var chipsRoom: CGFloat = 0
    /// What the key cap is doing.
    @State private var keyActivity: STKeyCapActivity = .idle
    /// The profile whose chip listens for a key, after its menu's Set Key…, and what that chip is doing.
    @State private var listeningProfile: String?
    @State private var chipActivity: STKeyCapActivity = .idle

    private var keyRebinder: KeyRebinderController? { model.keyRebinder }
    private var hotkeys: HotkeyCenter { model.hotkeys }
    private let tool = ToolID.keyRebinder

    /// - Parameter profile: the profile whose chip starts out listening for a key, as after its menu's Set Key…; tests
    ///   and renders use it to see a key being set.
    init(model: AppModel, listeningTo profile: String? = nil) {
        self.model = model
        _listeningProfile = State(initialValue: profile)
    }

    var body: some View {
        let line = statusLine(activity, switchError: switchError)
        let isMessage = activity != .idle || switchError != nil
        ZStack(alignment: .topLeading) {
            Button { model.navigate(to: .tool(tool)) } label: {
                HomeTileLabel(tool: tool, status: line, isMessage: isMessage)
            }
            .buttonStyle(HomeTileStyle(isHovering: isHovering))
            .focusEffectDisabled()
            .accessibilityLabel("\(tool.number), \(tool.title)")
            .accessibilityValue(model.status(of: tool).label.capitalized)
            .accessibilityHint("Opens the \(tool.title) page")
            VStack(alignment: .leading, spacing: 0) {
                // The heading's own room, so the controls start under the status line at every text size.
                HomeTileHeading(tool: tool, status: line, isMessage: isMessage)
                    .hidden()
                    .accessibilityHidden(true)
                controls
                    .padding(.top, HomeTileLabel.controlsGap(tight: isTight))
                    // Under the status line, which a tight tile starts at its edge.
                    .padding(.leading, isTight ? 0 : HomeTileLabel.numberColumn(theme.textScale))
                    // As tall as the other tiles' controls when sized alone, so many profiles never make the tile taller;
                    // in a taller tile, as tall as its room.
                    .frame(minHeight: HomeTileLabel.controlsHeight(theme.textScale),
                           idealHeight: HomeTileLabel.controlsHeight(theme.textScale), maxHeight: .infinity, alignment: .bottom)
            }
            .padding(.leading, HomeTileLabel.leadingPadding)
            .padding(.trailing, HomeTileLabel.trailingPadding)
            .padding(.top, HomeTileLabel.topPadding(tight: isTight))
            .padding(.bottom, HomeTileLabel.bottomPadding(tight: isTight))
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tool.title)
    }

    /// Room around the chips inside their scroll view.
    private static let chipInset: CGFloat = 4

    /// Where the fade over chips that don't all fit starts, as a fraction of their room: the last 16 pt, so a row that
    /// is wholly in view keeps its color.
    static func fadeStart(in room: CGFloat) -> CGFloat {
        guard room > 0 else { return 1 }
        return max(0.5, 1 - 16 / room)
    }

    /// What the key cap or a chip is doing: whichever listens.
    private var activity: STKeyCapActivity {
        if keyActivity != .idle { return keyActivity }
        guard let listeningProfile, profiles.contains(listeningProfile) else { return .idle }
        return chipActivity
    }

    /// The line under the name: while a key is being set, how to finish and why a key was refused; then why the last
    /// click didn't switch the profile; else the tool's status.
    func statusLine(_ activity: STKeyCapActivity, switchError: String? = nil) -> HomeToolTile.StatusLine {
        if let recording = HomeToolTile.StatusLine.recording(activity) { return recording }
        if let switchError { return HomeToolTile.StatusLine(text: switchError, tone: .danger) }
        return HomeToolTile.StatusLine.status(model.status(of: tool))
    }

    // MARK: The controls

    /// The key cap, bottom left as on every tile, then the profiles or why there are none.
    private var controls: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if showsNextKey {
                STKeyCapRecorder(shortcut: nextKey, label: nextKeyLabel, spokenKey: nextSpokenKey, isDimmed: !hotkeys.isEnabled,
                                 problem: nextKeyProblem, revealsClear: isHovering, activity: $keyActivity,
                                 validate: nextKeyRefusal(for:))
                    .help(nextKeyHelp)
                    .frame(height: HomeTileLabel.controlsHeight(theme.textScale))
            }
            profilesArea
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                // The profiles take the room first; the cap keeps its least width, its plus alone while it has no key.
                .layoutPriority(1)
        }
    }

    @ViewBuilder private var profilesArea: some View {
        if let setupNote {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if keyRebinder?.requirement.map({ !$0.isReady && $0 != .notInstalled }) == true {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11 * theme.textScale))
                        .foregroundStyle(STColor.danger)
                        .accessibilityHidden(true)
                }
                Text(setupNote)
                    .stStyle(.caption)
                    .foregroundStyle(theme.inkTertiary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Under the status line, or beside a key cap that has a key.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: showsNextKey ? .bottomLeading : .topLeading)
            .allowsHitTesting(false)
            .help(setupHelp ?? setupNote)
            .accessibilityElement(children: .combine)
        } else if !profiles.isEmpty {
            chips
        }
    }

    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                STFlowLayout(spacing: 6) {
                    ForEach(profiles, id: \.self) { name in
                        chip(name)
                            .id(name)
                    }
                }
                // Room for a chip's edge and its rings, which the scroll view would otherwise cut off.
                .padding(Self.chipInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chipsHeight = $0 }
                // While they fit, the chips sit on the tile's bottom row, beside the key cap.
                .frame(minHeight: chipsRoom, alignment: .bottomLeading)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chipsRoom = $0 }
            // More profiles than fit: the bottom edge fades out, so it reads as more to scroll to and not as cut off.
            .mask {
                let overflows = chipsHeight > chipsRoom + 1
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: overflows ? Self.fadeStart(in: chipsRoom) : 1),
                                       .init(color: overflows ? .clear : .black, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            // The inset reaches out past the area's edges, so the chips line up with the cap and the status line.
            .padding(-Self.chipInset)
            // The profile in use stays in view, and so does a chip listening for its key.
            .onAppear { if let shown = listeningProfile ?? current { proxy.scrollTo(shown) } }
            .onChange(of: current) { _, now in if let now { proxy.scrollTo(now) } }
            .onChange(of: listeningProfile) { _, now in if let now { proxy.scrollTo(now) } }
        }
        .disabled(keyRebinder.map { $0.isBusy || $0.profiles.state != .ready } ?? true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Karabiner profiles")
    }

    private func chip(_ name: String) -> some View {
        HomeProfileChip(
            name: name, shown: HomeProfileChip.shownName(of: name, among: profiles),
            tight: HomeProfileChip.shownName(of: name, among: profiles, wordsBefore: 0), isCurrent: name == current,
            key: profileKey(for: name).map { own in
                HomeProfileChip.Key(display: own.combo.displayString, isDimmed: !hotkeys.isEnabled, problem: keyProblem(for: name))
            },
            help: chipHelp(for: name), spokenKey: spokenKey(for: name),
            isListening: isListening(name), activity: chipActivity(name),
            validate: { refusal(for: $0, profile: name) },
            setKey: { setKey($0, for: name) }
        ) {
            sound.play(.click)
            Task { switchError = Self.failure(await choose(name)) }
        }
    }

    /// Whether the chip for `name` listens for a key. One chip listens at a time.
    private func isListening(_ name: String) -> Binding<Bool> {
        Binding(get: { listeningProfile == name }, set: { listening in
            if listening {
                guard listeningProfile != name else { return }
                chipActivity = .idle
                listeningProfile = name
            } else if listeningProfile == name {
                listeningProfile = nil
            }
        })
    }

    /// What the chip for `name` is doing; a chip that has stopped listening can't overwrite the one that took over.
    private func chipActivity(_ name: String) -> Binding<STKeyCapActivity> {
        Binding(get: { listeningProfile == name ? chipActivity : .idle }, set: { now in
            if listeningProfile == name { chipActivity = now }
        })
    }

    // MARK: The profiles

    /// Karabiner-Elements' profiles while one can be switched to; none otherwise.
    var profiles: [String] {
        guard let profiles = keyRebinder?.profiles, profiles.state == .ready else { return [] }
        return profiles.names
    }

    var current: String? { keyRebinder?.profiles.current }

    /// Why no profile can be switched to, as a profile hotkey's row says it; nil while one can, and without a Key Rebinder.
    var setupNote: String? {
        guard let keyRebinder else { return nil }
        switch keyRebinder.profiles.state {
        case .unknown: return "Looking for Karabiner-Elements\u{2026}"
        case .ready: return nil
        case .unavailable(let problem): return HotkeyWording.profileProblem(problem) + "."
        }
    }

    /// How to fix it, as the Key Rebinder's page words it, for the note's help tag; nil when there's nothing to fix.
    var setupHelp: String? {
        guard let requirement = keyRebinder?.requirement, !requirement.isReady else { return nil }
        return requirement.fixText
    }

    /// Switches Karabiner-Elements to `name` through the switch profile hotkeys use, and says what it did. With the
    /// Key Rebinder's page closed it loads no `karabiner.json`.
    @discardableResult
    func choose(_ name: String) async -> HotkeyProfileSwitch {
        guard let keyRebinder else { return .unavailable(.notInstalled) }
        return await keyRebinder.switchProfile(for: .select(name))
    }

    /// What the tile says when a click didn't switch the profile, in the words of a profile hotkey's confirmation; nil
    /// when it switched, or the profile was already in use.
    static func failure(_ outcome: HotkeyProfileSwitch) -> String? {
        if case .alreadyCurrent = outcome { return nil }
        return outcome.changedProfile ? nil : HotkeyConfirmation.phrase(.profile(outcome))
    }

    // MARK: A profile's key

    /// The profile's own hotkey (`HotkeyCenter.profileHotkey(for:)`), which its chip shows and sets; nil without one.
    func profileKey(for name: String) -> HotkeyBinding? {
        hotkeys.profileHotkey(for: name)
    }

    /// Gives the profile `name` its own hotkey, moves it, or removes it (nil), as its chip's menu does.
    func setKey(_ shortcut: STShortcut?, for name: String) {
        hotkeys.setProfileHotkey(shortcut?.hotkeyCombo, for: name)
    }

    /// Why the chip refuses `shortcut` while it listens, in the tool pages' words; nil when it's fine.
    func refusal(for shortcut: STShortcut, profile name: String) -> String? {
        ToolHotkey.refusal(for: shortcut.hotkeyCombo, action: .profile(.select(name)), in: hotkeys)
    }

    /// What's wrong with the profile's key, as a hotkey's row says it; nil when nothing is.
    func keyProblem(for name: String) -> String? {
        profileKey(for: name).flatMap(problem(of:))
    }

    /// The chip's help tag: the whole name, what its key does and anything wrong with it, and how to set it.
    func chipHelp(for name: String) -> String {
        guard let own = profileKey(for: name) else { return "\(name). Control-click to give it a key." }
        var lines = ["\(name). \(own.combo.displayString) switches to it."]
        if let problem = problem(of: own) { lines.append(HomeToolTile.sentence(problem)) }
        if !hotkeys.isEnabled { lines.append("Hotkeys are off, so this key does nothing yet.") }
        lines += hotkeys.notes(for: own.combo).map(\.text)
        lines.append("Control-click to change its key.")
        return lines.joined(separator: " ")
    }

    /// The profile's key as VoiceOver says it, as a key cap says it: "Command 1", with what's wrong after it.
    func spokenKey(for name: String) -> String {
        guard let own = profileKey(for: name) else { return "No key" }
        let key = HotkeyWording.spokenName(for: own.combo)
        guard let problem = problem(of: own) else { return key }
        return "\(key), not working: \(problem)"
    }

    /// Why a profile hotkey doesn't work: its key isn't registered, or its profile can't be switched to.
    private func problem(of binding: HotkeyBinding) -> String? {
        guard let profiles = keyRebinder?.profiles else {
            return HotkeyWording.statusNote(hotkeys.status(of: binding.id), combo: binding.combo, inList: false)
        }
        return HotkeyWording.statusNote(hotkeys.status(of: binding.id), for: binding, profiles: profiles, inList: false)
    }

    // MARK: Next profile's key

    /// Whether the key cap shows: once a profile can be switched to, or while Next profile has a key, so a key that's
    /// set stays in view.
    var showsNextKey: Bool {
        guard let keyRebinder else { return false }
        return keyRebinder.profiles.state == .ready || nextOwn != nil
    }

    private var nextOwn: HotkeyBinding? { ToolHotkey.own(for: .profile(.next), in: hotkeys.bindings) }

    /// Next profile's own hotkey, set, changed or cleared through `ToolHotkey`, as a tool's tile sets its tool's.
    var nextKey: Binding<STShortcut?> {
        Binding(
            get: { ToolHotkey.own(for: .profile(.next), in: model.hotkeys.bindings)?.combo.asSTShortcut },
            set: { ToolHotkey.set($0?.hotkeyCombo, for: .profile(.next), in: model.hotkeys) })
    }

    /// Why the key cap refuses `shortcut` while it listens, in the tool pages' words; nil when it's fine.
    func nextKeyRefusal(for shortcut: STShortcut) -> String? {
        ToolHotkey.refusal(for: shortcut.hotkeyCombo, action: .profile(.next), in: hotkeys)
    }

    /// The key cap's name for VoiceOver.
    var nextKeyLabel: String { "\(HotkeyWording.nextProfileTitle) hotkey" }

    /// The key as VoiceOver says it ("Command 1"); nil without one.
    var nextSpokenKey: String? { nextOwn.map { HotkeyWording.spokenName(for: $0.combo) } }

    /// What's wrong with Next profile's key; nil when nothing is.
    var nextKeyProblem: String? { nextOwn.flatMap(problem(of:)) }

    /// The key cap's help tag: what Next profile does, why its key does nothing yet, and the notes a hotkey's row shows.
    private var nextKeyHelp: String {
        let purpose = "\(HotkeyWording.nextProfileTitle) switches Karabiner-Elements to the profile after the one in use."
        guard let own = nextOwn else { return purpose + " Click to give it a key." }
        var lines: [String] = []
        if let nextKeyProblem { lines.append(HomeToolTile.sentence(nextKeyProblem)) }
        if !hotkeys.isEnabled { lines.append("Hotkeys are off, so this key does nothing yet.") }
        lines.append(purpose)
        lines += hotkeys.notes(for: own.combo).map(\.text)
        lines.append("Click to change it.")
        return lines.joined(separator: " ")
    }
}

/// One Karabiner-Elements profile on Home: a chip, filled while it's the current profile, with the profile's own hotkey
/// as a small legend when it has one and the row has room for it. A long name is cut to fit `widest`, or its row where
/// that's narrower, so that it stays apart from the others (`shownName`), and its help tag and VoiceOver have it
/// whole. Its menu's Set Key… listens for the profile's new key in place, ringed in the accent until a key, Esc or a
/// click ends it (red while it refuses a key), and Remove Key clears it.
struct HomeProfileChip: View {
    /// The profile's key as the legend draws it.
    struct Key: Equatable {
        var display: String
        /// Hotkeys are off, so it does nothing yet.
        var isDimmed: Bool
        /// Why it doesn't work; nil when it does.
        var problem: String?
    }

    let name: String
    /// The name as the chip shows it, from `shownName(of:among:)`, and as it shows it in a row too narrow for that, from
    /// `shownName(of:among:wordsBefore:)` with no word before where the names differ.
    let shown: String
    let tight: String
    let isCurrent: Bool
    let key: Key?
    let help: String
    let spokenKey: String
    @Binding var isListening: Bool
    @Binding var activity: STKeyCapActivity
    let validate: (STShortcut) -> String?
    let setKey: (STShortcut?) -> Void
    let choose: () -> Void

    @Environment(\.stTheme) private var theme

    /// The widest a chip's name gets, in points at a text scale of 1.
    static let widest: CGFloat = 112
    /// About how many characters of a name fit in `widest`, in the chips' small capitals.
    static let room = 14

    /// The name as its chip shows it. A name too long for its chip that starts like another profile's for most of the
    /// chip's room would be cut to the same few words as that one, so it starts after an ellipsis, `wordsBefore` words
    /// before where the two differ: one for context ("…number 2 with a long name"), or none where the row is narrow
    /// ("…2 with a long name"). Any other name is shown whole and cut in the middle if it must be, which keeps its end in
    /// view.
    static func shownName(of name: String, among names: [String], wordsBefore: Int = 1) -> String {
        guard name.count > room else { return name }
        let shared = names.filter { $0 != name }.map { name.commonPrefix(with: $0).count }.max() ?? 0
        guard shared >= room - 3 else { return name }
        let characters = Array(name)
        // Back to the start of the word where the names differ, then the words before it, for context.
        var start = min(shared, characters.count)
        while start > 0, characters[start - 1] != " " { start -= 1 }
        for _ in 0..<wordsBefore where start > 0 {
            start -= 1
            while start > 0, characters[start - 1] != " " { start -= 1 }
        }
        return "\u{2026}" + String(characters[start...])
    }

    /// Where a shown name is cut when it still doesn't fit: one that starts after an ellipsis at its end, any other in its
    /// middle.
    static func truncation(of shown: String) -> Text.TruncationMode {
        shown.hasPrefix("\u{2026}") ? .tail : .middle
    }

    var body: some View {
        Button(action: choose) {
            // The key where there's room for it beside the name at its widest; in a narrower row the name keeps the room,
            // and in a narrower one still it's cut where it differs from the others, so names cut to fit stay apart. The
            // help tag and VoiceOver say the key either way.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 5 * theme.textScale) {
                    nameText(shown)
                    legend
                        .fixedSize()
                }
                nameText(shown)
                nameText(tight)
            }
        }
        .buttonStyle(STChipStyle(isSelected: isCurrent))
        .overlay {
            Capsule()
                .stroke(activity == .listening ? theme.accentStroke : STColor.danger, lineWidth: 1.5)
                .padding(-3)
                .opacity(activity == .idle ? 0 : 1)
                .allowsHitTesting(false)
        }
        .stAnimation(STMotion.quick, value: activity)
        .contextMenu {
            Button(key == nil ? "Set Key\u{2026}" : "Change Key\u{2026}") { isListening = true }
            Button("Remove Key") { setKey(nil) }
                .disabled(key == nil)
        }
        .stListensForKey($isListening, activity: $activity, validate: validate, onKey: setKey)
        .help(help)
        .accessibilityLabel(name)
        .accessibilityValue(activity == .idle ? spokenKey : "Recording")
        .accessibilityHint(activity == .idle
            ? (isCurrent ? "The current profile" : "Switches Karabiner-Elements to this profile")
            : "Press the new key or combination. Escape cancels, Delete clears.")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityActions {
            Button(key == nil ? "Set Key" : "Change Key") { isListening = true }
            if key != nil { Button("Remove Key") { setKey(nil) } }
        }
    }

    private func nameText(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(Self.truncation(of: text))
            .frame(maxWidth: Self.widest * theme.textScale)
    }

    /// The key, quieter than the name; while the chip listens, a keyboard in its place.
    @ViewBuilder private var legend: some View {
        if activity != .idle {
            Image(systemName: "keyboard")
                .font(.system(size: 10 * theme.textScale, weight: .semibold))
                .foregroundStyle(isCurrent ? STColor.background : (activity == .listening ? theme.accent : STColor.danger))
                .accessibilityHidden(true)
        } else if let key {
            Text(key.display)
                .font(STFont.figures(11 * theme.textScale, weight: .medium))
                .tracking(0)
                .foregroundStyle(legendColor(key))
        }
    }

    private func legendColor(_ key: Key) -> Color {
        // On the filled chip the legend keeps the chip's dark ink; its help and VoiceOver say what's wrong.
        if isCurrent { return STColor.background.opacity(key.isDimmed ? 0.5 : 0.72) }
        if key.problem != nil { return STColor.danger }
        return key.isDimmed ? theme.inkTertiary : theme.inkSecondary
    }
}
