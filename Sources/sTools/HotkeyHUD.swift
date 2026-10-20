import AppKit
import STDesign
import STPlatform
import SwiftUI

/// Shows a hotkey press's confirmation line. A protocol so tests can watch presses without windows.
@MainActor
protocol HotkeyConfirmationPresenting: AnyObject {
    /// `sealed`: whether the seal stamps in beside the line (the press changed something).
    func present(_ line: String, sealed: Bool, on display: DisplayInfo)
}

/// The hotkey confirmation (spec 6.1, motion per 3.4): a gold seal stamping in beside one line of what
/// changed, low and centered on Minecraft's display. It lives in a click-through panel that never takes
/// focus from the game and never appears in recordings. It fades out after a moment; a new press starts
/// it over.
@MainActor
final class HotkeyHUD: HotkeyConfirmationPresenting {
    private let theme: STTheme
    private let hold: Duration
    private let fadeInDuration: TimeInterval
    private let fadeOutDuration: TimeInterval
    /// Made up front, not on the first press, so a whole-display recording that started earlier
    /// already knows to leave it out (`OverlayPanel.captureExcludedWindowNumbers()`).
    let panel = OverlayPanel(role: .topmost, isExcludedFromCapture: true)
    private var dismissal: Task<Void, Never>?

    init(theme: STTheme, hold: Duration = .seconds(1.2),
         fadeInDuration: TimeInterval = 0.12, fadeOutDuration: TimeInterval = 0.3) {
        self.theme = theme
        self.hold = hold
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
    }

    var isShowing: Bool { panel.isVisible }

    func present(_ line: String, sealed: Bool, on display: DisplayInfo) {
        dismissal?.cancel()
        // Fresh content each press, so the seal stamps in again.
        let content = HotkeyHUDView(line: line, sealed: sealed).environment(\.stTheme, theme)
        panel.setContent(content)
        // The panel's host doesn't size itself, so measure the content separately.
        let size = NSHostingController(rootView: content)
            .sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        let wasShowing = panel.isVisible
        if !wasShowing { panel.alphaValue = 0 }
        panel.show(frame: HotkeyHUDLayout.frame(contentSize: size, displayFrame: display.frame))
        animateAlpha(to: 1, duration: wasShowing ? 0.05 : fadeInDuration)
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: line, .priority: NSAccessibilityPriorityLevel.high.rawValue])

        dismissal = Task { [weak self, hold, fadeOutDuration] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled, let self else { return }
            animateAlpha(to: 0, duration: fadeOutDuration)
            try? await Task.sleep(for: .seconds(fadeOutDuration))
            guard !Task.isCancelled else { return }
            panel.hide()
        }
    }

    /// Animating to a new value replaces any fade still running, so a press mid-fade-out comes back at once.
    private func animateAlpha(to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = alpha
        }
    }
}

/// Where the confirmation goes.
enum HotkeyHUDLayout {
    /// The bottom edge sits this far up the display, above Minecraft's hotbar and health at common GUI scales.
    static let bottomFraction: CGFloat = 0.22
    /// The least room kept between the confirmation and the display's center, where the crosshair is.
    static let centerClearance: CGFloat = 48

    /// Minecraft's display, or the main display when Minecraft isn't on one sTools knows.
    static func display(minecraftDisplayID: UInt32?, in displays: [DisplayInfo]) -> DisplayInfo? {
        if let minecraftDisplayID, let display = displays.first(where: { $0.id == minecraftDisplayID }) {
            return display
        }
        return displays.first(where: \.isMain) ?? displays.first
    }

    /// Horizontally centered and low on the display (AppKit coordinates), never reaching up to the
    /// center, even on a very short display.
    static func frame(contentSize: CGSize, displayFrame: CGRect) -> CGRect {
        let width = min(contentSize.width.rounded(.up), displayFrame.width)
        let height = contentSize.height.rounded(.up)
        let low = displayFrame.minY + displayFrame.height * bottomFraction
        let highest = displayFrame.midY - centerClearance - height
        let y = max(displayFrame.minY, min(low, highest))
        return CGRect(x: (displayFrame.midX - width / 2).rounded(), y: y.rounded(), width: width, height: height)
    }
}

/// The confirmation itself: the seal and the line on a plate.
struct HotkeyHUDView: View {
    let line: String
    var sealed = true
    @State private var isStamped = false

    var body: some View {
        STPlate {
            HStack(spacing: 10) {
                if sealed { STSeal(isStamped: isStamped) }
                Text(line)
                    .stStyle(.body)
                    .foregroundStyle(STColor.ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, sealed ? 12 : 16)
            .padding(.trailing, 16)
            .padding(.vertical, 10)
        }
        .fixedSize()
        .onAppear { isStamped = true }
        .accessibilityElement(children: .combine)
    }
}
