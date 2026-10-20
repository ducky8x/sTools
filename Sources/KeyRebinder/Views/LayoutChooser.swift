import STDesign
import SwiftUI

/// Asked once, before the first keyboard is drawn (spec 5.5.2): which layout, with this Mac's own preselected.
struct LayoutChooser: View {
    let controller: KeyRebinderController

    @State private var shape = KeyboardLayoutDetector.detectedShape()
    @State private var formFactor = KeyboardLayoutDetector.detectedFormFactor()
    @Environment(\.stTheme) private var theme

    var body: some View {
        let layout = KeyboardLayout(shape: shape, formFactor: formFactor)
        let reference = BoardGeometry.preview(layout: layout, width: 1000).size
        STPlate {
            VStack(alignment: .leading, spacing: 16) {
                Text("Which keyboard should sTools draw?").stStyle(.sectionTitle).foregroundStyle(STColor.ink)
                Text("The guess comes from this Mac. Legends are US labels. You can change it later in the settings below.")
                    .stStyle(.body).foregroundStyle(theme.inkSecondary)
                HStack(spacing: 28) {
                    STSegmented(selection: $shape, options: KeyboardShape.allCases.map { STSegmentedOption($0, $0.title) })
                    STSegmented(selection: $formFactor, options: KeyboardFormFactor.allCases.map { STSegmentedOption($0, $0.title) })
                }
                GeometryReader { proxy in
                    KeyboardBoard(
                        layout: layout, geometry: BoardGeometry.preview(layout: layout, width: proxy.size.width),
                        state: { _ in KeyCapState() }, arcTarget: { _ in nil }, describe: { _ in "" }, onSelect: nil)
                }
                .aspectRatio(reference.width / reference.height, contentMode: .fit)
                .accessibilityHidden(true)
                Button("Use This Keyboard") { controller.chooseLayout(shape: shape, formFactor: formFactor) }
                    .buttonStyle(STButtonStyle(.primary))
            }
            .padding(20)
        }
    }
}
