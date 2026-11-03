import KeyRebinder
import STDesign
import SwiftUI

/// The Key Rebinder on Home: its number, name and status like every tile, and Karabiner-Elements' profiles as chips with
/// the current one filled. One click switches Karabiner-Elements to a profile, through the page's own path
/// (`KeyRebinderController.selectProfile`). The chips wrap under the status into the room the tile has; a long name is
/// cut off, whole in its help tag and for VoiceOver, and profiles past the tile's room scroll. Until Karabiner-Elements
/// is ready a line says why, and the tile opens the page where it's set up. Clicking the tile opens the Key Rebinder.
///
/// The profiles come from `profiles`, `current` and `setupNote`, and Home's check refreshes them
/// (`AppModel.refreshHomeStatuses`), so another source of profiles takes those three and that one call.
struct HomeKeyRebinderTile: View {
    let model: AppModel

    @Environment(\.stTheme) private var theme
    @Environment(\.stSoundPlayer) private var sound
    @State private var isHovering = false
    /// Why the last click didn't switch the profile, until the next click.
    @State private var switchError: String?
    /// The chips' height and the room they're shown in, to fade the last row out while there are more to scroll to.
    @State private var chipsHeight: CGFloat = 0
    @State private var chipsRoom: CGFloat = 0

    private var keyRebinder: KeyRebinderController? { model.keyRebinder }
    private let tool = ToolID.keyRebinder

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button { model.navigate(to: .tool(tool)) } label: {
                HomeTileLabel(tool: tool, status: status, isMessage: switchError != nil)
            }
            .buttonStyle(HomeTileStyle(isHovering: isHovering))
            .focusEffectDisabled()
            .accessibilityLabel("\(tool.number), \(tool.title)")
            .accessibilityValue(model.status(of: tool).label.capitalized)
            .accessibilityHint("Opens the \(tool.title) page")
            VStack(alignment: .leading, spacing: 0) {
                // The heading's own room, so the profiles start under the status line at every text size.
                HomeTileHeading(tool: tool, status: status, isMessage: switchError != nil)
                    .hidden()
                    .accessibilityHidden(true)
                profilesArea
                    .padding(.top, HomeTileLabel.controlsGap)
                    .padding(.leading, HomeTileLabel.numberColumn(theme.textScale))
                    // As tall as the other tiles' controls when sized alone, so many profiles never make the tile taller;
                    // in a taller tile, as tall as its room.
                    .frame(minHeight: HomeTileLabel.controlsHeight(theme.textScale),
                           idealHeight: HomeTileLabel.controlsHeight(theme.textScale), maxHeight: .infinity, alignment: .top)
            }
            .padding(.leading, HomeTileLabel.leadingPadding)
            .padding(.trailing, HomeTileLabel.trailingPadding)
            .padding(.top, HomeTileLabel.topPadding)
            .padding(.bottom, HomeTileLabel.bottomPadding)
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tool.title)
    }

    /// Room around the chips inside their scroll view.
    private static let chipInset: CGFloat = 4

    /// The tool's status, or why the last profile didn't switch.
    private var status: HomeToolTile.StatusLine {
        if let switchError { return HomeToolTile.StatusLine(text: switchError, tone: .danger) }
        let status = model.status(of: tool)
        return HomeToolTile.StatusLine(text: status.label, tone: status.isLit ? .accent : .quiet)
    }

    // MARK: The profiles

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
            .frame(maxWidth: .infinity, alignment: .leading)
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
                        HomeProfileChip(name: name, shown: HomeProfileChip.shownName(of: name, among: profiles),
                                        isCurrent: name == current) {
                            sound.play(.click)
                            Task {
                                let switched = await choose(name)
                                switchError = switched ? nil : Self.switchFailure(name, reason: keyRebinder?.errorMessage)
                            }
                        }
                        .id(name)
                    }
                }
                // Room for a chip's edge and its focus ring, which the scroll view would otherwise cut off.
                .padding(Self.chipInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chipsHeight = $0 }
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chipsRoom = $0 }
            // More profiles than fit: the last row fades out, so it reads as more to scroll to and not as cut off.
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: chipsHeight > chipsRoom + 1 ? 0.62 : 1),
                                       .init(color: chipsHeight > chipsRoom + 1 ? .clear : .black, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            // The inset reaches out past the area's edges, so the chips line up with the status line above them.
            .padding(-Self.chipInset)
            .onAppear { if let current { proxy.scrollTo(current) } }
            .onChange(of: current) { _, now in if let now { proxy.scrollTo(now) } }
        }
        .disabled(keyRebinder.map { $0.isBusy || !$0.canSwitchProfile } ?? true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Karabiner profiles")
    }

    /// Karabiner-Elements' profiles while it's ready; none otherwise.
    var profiles: [String] {
        guard let keyRebinder, keyRebinder.requirement == .ready else { return [] }
        return keyRebinder.profileNames
    }

    var current: String? { keyRebinder?.currentProfile }

    /// Why there are no profiles to pick, in the words of the introduction's Karabiner-Elements step; nil while
    /// Karabiner-Elements is ready, and without a Key Rebinder.
    var setupNote: String? {
        guard let keyRebinder else { return nil }
        guard let requirement = keyRebinder.requirement else { return "Looking for Karabiner-Elements\u{2026}" }
        return requirement.isReady ? nil : PrologueCopy.karabinerDetail(requirement)
    }

    /// The fix, as the Key Rebinder's page words it, for the note's help tag.
    var setupHelp: String? {
        guard let requirement = keyRebinder?.requirement, !requirement.isReady else { return nil }
        return requirement.fixText
    }

    /// Switches Karabiner-Elements to `name`, as the page's profile menu does, then lets the parsed `karabiner.json` go
    /// again unless the Key Rebinder's page has opened meanwhile: Home keeps none of it. True once `name` is current.
    @discardableResult
    func choose(_ name: String) async -> Bool {
        guard let keyRebinder else { return false }
        await keyRebinder.selectProfile(name)
        if model.route != .tool(.keyRebinder) { keyRebinder.releaseLoadedFile() }
        return keyRebinder.currentProfile == name
    }

    /// What the tile says when a click didn't switch to `name`: Karabiner-Elements' own reason when it gave one.
    static func switchFailure(_ name: String, reason: String?) -> String {
        reason ?? "Karabiner-Elements didn\u{2019}t switch to \(name)."
    }
}

/// One Karabiner-Elements profile on Home: a chip, filled while it's the current profile. A long name is cut to fit
/// `widest` so that it stays apart from the others (`shownName`), and its help tag and VoiceOver have it whole.
struct HomeProfileChip: View {
    let name: String
    /// The name as the chip shows it, from `shownName(of:among:)`.
    let shown: String
    let isCurrent: Bool
    let choose: () -> Void

    @Environment(\.stTheme) private var theme

    /// The widest a chip's name gets, in points at a text scale of 1.
    static let widest: CGFloat = 112
    /// About how many characters of a name fit in `widest`, in the chips' small capitals.
    static let room = 14

    /// The name as its chip shows it. A name too long for its chip that starts like another profile's for most of the
    /// chip's room would be cut to the same few words as that one, so it starts after an ellipsis, a word before where the
    /// two differ ("…number 2 with a long name"). Any other name is shown whole and cut in the middle if it must be, which
    /// keeps its end in view.
    static func shownName(of name: String, among names: [String]) -> String {
        guard name.count > room else { return name }
        let shared = names.filter { $0 != name }.map { name.commonPrefix(with: $0).count }.max() ?? 0
        guard shared >= room - 3 else { return name }
        let characters = Array(name)
        // Back to the start of the word where the names differ, then one word further, for context.
        var start = min(shared, characters.count)
        while start > 0, characters[start - 1] != " " { start -= 1 }
        if start > 0 {
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
            Text(shown)
                .lineLimit(1)
                .truncationMode(Self.truncation(of: shown))
                .frame(maxWidth: Self.widest * theme.textScale)
                .fixedSize()
        }
        .buttonStyle(STChipStyle(isSelected: isCurrent))
        .help(name)
        .accessibilityLabel(name)
        .accessibilityHint(isCurrent ? "The current profile" : "Switches Karabiner-Elements to this profile")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
