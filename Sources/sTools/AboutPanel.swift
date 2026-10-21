import AppKit

/// sTools ▸ About sTools: the standard About window with this copy's version and build, and the third-party
/// notices (spec 8).
@MainActor
enum AboutPanel {
    /// The notices under the icon: Sparkle (MIT) and DM Serif Display (SIL Open Font License).
    static let creditsText = """
        Updates by Sparkle, \u{00A9} the Sparkle Project contributors, used under the MIT License.
        DM Serif Display, \u{00A9} the DM Serif Display Project Authors, used under the SIL Open Font License 1.1.
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
