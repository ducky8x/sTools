import STDesign
import SwiftUI

/// The scrolling, padded column every page sits in.
struct PageContainer<Content: View>: View {
    private let content: Content
    private let maxWidth: CGFloat
    @Binding private var anchor: PageAnchor?
    private let accepts: Set<PageAnchor>

    /// `maxWidth` widens the column for a page whose plate needs the room (the Key Rebinder's keyboard). `anchor`
    /// scrolls the page to the view marked with the anchor's `scrollID` when it's set to one this page `accepts`, then
    /// clears it; an anchor meant for another page is left for that page.
    init(maxWidth: CGFloat = 640, anchor: Binding<PageAnchor?> = .constant(nil), accepts: Set<PageAnchor> = [],
         @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        _anchor = anchor
        self.accepts = accepts
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
        guard let target = anchor, accepts.contains(target) else { return }
        // A moment later, once a newly opened page has laid out what it scrolls to.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            proxy.scrollTo(target.scrollID, anchor: target.scrollAnchor)
            if anchor == target { anchor = nil }
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
