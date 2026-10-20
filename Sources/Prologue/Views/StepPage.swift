import STDesign
import SwiftUI

/// The column a step's page sits in, centered in the window.
struct StepPage<Content: View>: View {
    var maxWidth: CGFloat = 600
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxWidth: maxWidth)
            .padding(.horizontal, 40)
            .padding(.top, 30)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }
}

/// A step's title, typewritten (spec 3.4: Prologue step titles typewrite), a gilt rule and a standfirst that
/// arrives with the page.
struct StepTitle: View {
    let model: PrologueModel
    let title: String
    var standfirst: String?

    @Environment(\.stTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TypewriterText(text: title, isStarted: true, completionCount: model.animations.completionCount)
                .stStyle(.pageTitle)
                .foregroundStyle(STColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            STGiltRule()
                .padding(.top, 6)
            if let standfirst {
                Text(standfirst)
                    .stStyle(.standfirst)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
        .onAppear { model.animations.run(for: TypewriterText.duration(of: title)) }
    }
}
