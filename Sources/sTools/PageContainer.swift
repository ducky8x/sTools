import STDesign
import SwiftUI

/// The scrolling, padded column every page sits in.
struct PageContainer<Content: View>: View {
    private let content: Content
    private let maxWidth: CGFloat

    /// `maxWidth` widens the column for a page whose plate needs the room (the Key Rebinder's keyboard).
    init(maxWidth: CGFloat = 640, @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, 40)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

/// A section heading inside a page, marked as a header for VoiceOver.
struct PageSectionTitle: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .stStyle(.sectionTitle)
            .foregroundStyle(STColor.ink)
            .accessibilityAddTraits(.isHeader)
    }
}
