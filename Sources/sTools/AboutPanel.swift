import AppKit

/// sTools ▸ About sTools: the standard About window with this copy's version and build, sTools' license and the
/// third-party notices (spec 8, README).
@MainActor
enum AboutPanel {
    /// The notices under the icon.
    static let creditsText = """
        sTools is released under the MIT License.
        Updates by Sparkle, under the MIT License. The fonts Bodoni Moda, Source Serif 4 and DM Serif Display, \
        under the SIL Open Font License 1.1.
        """

    /// What the window shows; the standard panel writes them as "Version 0.1.0 (build 68)".
    static func options(version: AppVersion) -> [NSApplication.AboutPanelOptionKey: Any] {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .credits: NSAttributedString(string: creditsText, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]),
        ]
        if let short = version.short { options[.applicationVersion] = short }
        if let build = version.build { options[.version] = "build \(build)" }
        return options
    }

    static func show(version: AppVersion) {
        NSApp.orderFrontStandardAboutPanel(options: options(version: version))
        NSApp.activate()
    }
}
