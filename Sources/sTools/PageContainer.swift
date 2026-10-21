import STDesign
import SwiftUI

/// The scrolling, padded column every page sits in.
struct PageContainer<Content: View>: View {
    private let content: Content
    private let maxWidth: CGFloat
    @Binding private var anchor: PageAnchor?

    /// `maxWidth` widens the column for a page whose plate needs the room (the Key Rebinder's keyboard). `anchor`
    /// scrolls the page to the view marked `.id(anchor)` when it's set, then clears it.
    init(maxWidth: CGFloat = 640, anchor: Binding<PageAnchor?> = .constant(nil), @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        _anchor = anchor
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
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
            .onAppear { scroll(proxy) }
            .onChange(of: anchor) { scroll(proxy) }
        }
    }

    /// Jumps rather than glides, so it needs nothing from Reduce animations.
    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target = anchor else { return }
        // A moment later, once a newly opened page has laid out what it scrolls to.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            proxy.scrollTo(target, anchor: .top)
            anchor = nil
        }
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
