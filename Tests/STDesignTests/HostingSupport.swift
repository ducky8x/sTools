import AppKit
import STDesign
import SwiftUI

// Every view these tests host or render is made here, and each maker registers the bundled fonts first, as the app
// does at launch, so no text in this process is ever laid out before they are registered. Text laid out earlier
// falls back to the system font, and SwiftUI moves later text to the bundled fonts only some time after they are
// registered: two renders on either side of that moment (a field drawn natively and through its overlay, a hosted
// view and a fresh one) draw different fonts, and their comparison fails by when the move landed.

/// An `NSHostingView` for `root`, made once the bundled fonts are registered.
@MainActor
func hostingView<Content: View>(_ root: Content) -> NSHostingView<Content> {
    hostingView(root, as: NSHostingView<Content>.self)
}

/// A hosting view of class `Host` for `root`, made once the bundled fonts are registered.
@MainActor
func hostingView<Content: View, Host: NSHostingView<Content>>(_ root: Content, as _: Host.Type) -> Host {
    STFont.register()
    return Host(rootView: root)
}

/// An `ImageRenderer` for `content`, made once the bundled fonts are registered.
@MainActor
func imageRenderer<Content: View>(_ content: Content) -> ImageRenderer<Content> {
    STFont.register()
    return ImageRenderer(content: content)
}
