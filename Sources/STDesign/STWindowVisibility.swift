import SwiftUI

public extension EnvironmentValues {
    /// Whether the window a view is in can be seen right now: open, not minimized, and not wholly covered by other
    /// windows (or a locked or sleeping screen). Pages pause their background work — permission polls, live
    /// previews — while it's false. True unless the app sets it, so previews and tests behave as before.
    @Entry var stWindowIsVisible: Bool = true
}
