import STDesign
import SwiftUI

/// The scrolling, padded column every page sits in.
struct PageContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: 640, alignment: .leading)
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
