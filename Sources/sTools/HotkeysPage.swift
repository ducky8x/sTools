import STDesign
import SwiftUI

/// The Hotkeys page (spec 6.1), right under Home in the sidebar and ⌃⌘H in the Go menu: every hotkey, where hotkeys
/// work, the key sets and Advanced (`HotkeysSection`). A tool's own key can also be set on Home and on the tool's page.
struct HotkeysPage: View {
    /// The line under the page's title.
    nonisolated static let tagline = "Keys that switch tools, start the timer and record."

    let model: AppModel

    var body: some View {
        PageContainer {
            STPageHeader(title: "Hotkeys", tagline: Self.tagline) { EmptyView() }
            VStack(alignment: .leading, spacing: 0) {
                HotkeysSection(model: model)
            }
            .padding(.top, 18)
        }
        // Where hotkeys work says so while Accessibility is missing, so the page watches it while it's on screen.
        .pollsPermissions(model.permissions)
    }
}
