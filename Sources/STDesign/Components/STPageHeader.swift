import SwiftUI

/// The top of a page: the title with a trailing control (the app passes the tool's switch), a
/// gilt rule, and the tagline in standfirst style. The title is the page's accessibility header. It shrinks to fit
/// its row, and wraps where it can't (`STPageTitle`).
public struct STPageHeader<Trailing: View>: View {
    private let title: String
    private let tagline: String
    private let trailing: Trailing

    @Environment(\.stTheme) private var theme

    public init(title: String, tagline: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.tagline = tagline
        self.trailing = trailing()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                STPageTitle(title)
                Spacer(minLength: 16)
                trailing
            }
            STGiltRule()
                .padding(.top, 6)
            Text(tagline)
                .stStyle(.standfirst)
                .foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }
}
