import AppKit
import STDesign
import STPlatform
import SwiftUI

/// Home (spec 3.5): every tool at a glance in sidebar order, the six with a switch three to a row and the Key Rebinder
/// across the page, each with its status, its switch and its key, and Minecraft, Ninjabrain Bot and Karabiner-Elements as drawn visuals: in a column beside the tools where
/// the window has room, in a strip beside the title where it hasn't. It fits the window without scrolling from the
/// 680 × 500 minimum up at the default text size; larger text may scroll.
///
/// Its checks cost nothing while it's away: Karabiner-Elements (which starts `karabiner_cli`) and, with the NBB Overlay
/// off, Ninjabrain Bot are looked at as Home appears and as sTools comes to the front, and never on a timer. Minecraft,
/// Accessibility and a running NBB Overlay report through what already watches them.
struct HomePage: View {
    /// The line under the page's title.
    nonisolated static let tagline = "Your tools, their keys and what they need."

    let model: AppModel

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                HomePageContent(model: model, layout: HomeLayout(pageWidth: proxy.size.width))
                    // As tall as the window when it fits, so the tiles share its height; at larger text it scrolls.
                    .frame(minHeight: proxy.size.height, alignment: .top)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
        }
        .task { await model.refreshHomeStatuses() }
        .onReceive(model.appNotifications.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Not while another page slides in over it.
            guard model.route == .home else { return }
            Task { await model.refreshHomeStatuses() }
        }
        // The tiles offer Allow… while Accessibility is missing, so the page watches it while it's on screen.
        .pollsPermissions(model.permissions)
    }
}

/// How Home sets itself out for the room it has.
struct HomeLayout: Equatable {
    /// Room at the page's sides, top and bottom.
    static let sidePadding: CGFloat = 24
    static let topPadding: CGFloat = 16
    static let bottomPadding: CGFloat = 14
    /// Between tiles, and between rows; tight tiles' rows sit a little closer.
    static let gap: CGFloat = 10
    static let tightRowGap: CGFloat = 8
    /// The least room for three tiles side by side at their full room; narrower, they sit tight.
    static let roomyTiles: CGFloat = 440
    /// The column of visuals beside the tools, and the room before it.
    static let lampColumnWidth: CGFloat = 112
    static let lampColumnGap: CGFloat = 14
    /// The widest the dashboard grows, column included; past it the page keeps to the left like every other.
    static let widest: CGFloat = 920
    /// The tallest a tile grows in a tall window.
    static let tallestTile: CGFloat = 176
    /// The least room for the tools and the column side by side; narrower, the visuals go beside the title.
    static let columnRoom: CGFloat = 600

    /// Whether the visuals stand in a column beside the tools, rather than in a strip beside the title.
    let showsLampColumn: Bool
    /// Whether the tiles keep less room above and below and start their controls at their edge, as in the narrowest
    /// window, so seven tiles fit its height and a tile offering Allow… fits its width.
    let tilesAreTight: Bool

    /// `pageWidth` is the page's whole width, right of the sidebar.
    init(pageWidth: CGFloat) {
        showsLampColumn = pageWidth - 2 * Self.sidePadding >= Self.columnRoom
        tilesAreTight = pageWidth - 2 * Self.sidePadding < Self.roomyTiles
    }

    var rowGap: CGFloat { tilesAreTight ? Self.tightRowGap : Self.gap }
}

/// Everything on Home, at its natural height: the header, the tiles and, while hotkeys are off, the line that says so.
struct HomePageContent: View {
    let model: AppModel
    let layout: HomeLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            STPageHeader(title: "Home", tagline: HomePage.tagline) {
                if !layout.showsLampColumn { HomeLampStrip(model: model) }
            }
            HomeDashboard(model: model, layout: layout)
                .padding(.top, 14)
                .frame(maxHeight: .infinity, alignment: .top)
            if !model.hotkeys.isEnabled {
                HomeHotkeysOffLine(model: model)
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: HomeLayout.widest, alignment: .leading)
        .padding(.horizontal, HomeLayout.sidePadding)
        .padding(.top, HomeLayout.topPadding)
        .padding(.bottom, HomeLayout.bottomPadding)
    }
}

/// The tiles in sidebar order (`HomeToolGrid`), and in a wide window the visuals beside them, each by a row with a tool
/// it serves (`HomeToolGrid.lamps`).
private struct HomeDashboard: View {
    let model: AppModel
    let layout: HomeLayout

    var body: some View {
        VStack(spacing: layout.rowGap) {
            ForEach(Array(HomeToolGrid.rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: HomeLayout.gap) {
                    ForEach(row) { tool in
                        Group {
                            if tool == .keyRebinder {
                                HomeKeyRebinderTile(model: model)
                            } else {
                                HomeToolTile(model: model, tool: tool)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if layout.showsLampColumn {
                        HomeLampView(model: model, kind: HomeToolGrid.lamps[index], showsName: true)
                            .frame(width: HomeLayout.lampColumnWidth)
                            .frame(maxHeight: .infinity)
                            .padding(.leading, HomeLayout.lampColumnGap - HomeLayout.gap)
                    }
                }
                .frame(maxHeight: HomeLayout.tallestTile)
            }
        }
        .environment(\.homeTilesAreTight, layout.tilesAreTight)
    }
}

/// While hotkeys are off: one quiet line under the tiles, with Turn On. Keys can be set meanwhile.
struct HomeHotkeysOffLine: View {
    static let text = "Hotkeys are off. Turn them on to use these keys."

    let model: AppModel
    @Environment(\.stTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Self.text)
                .stStyle(.caption)
                .foregroundStyle(theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Turn On", action: turnOn)
                .buttonStyle(STButtonStyle(.quiet))
                .accessibilityLabel("Turn on hotkeys")
        }
    }

    func turnOn() {
        model.hotkeys.isEnabled = true
    }
}
