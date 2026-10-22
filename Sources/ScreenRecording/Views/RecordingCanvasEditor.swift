import AppKit
import STDesign
import SwiftUI

/// The page's plate (spec 5.4.3): the live composite, with every source's frame drawn over it. Drag a source to
/// move it (snapping to edges, center and other sources), drag a corner or edge to resize, ⌥-drag to crop.
/// Outlines and handles go through the same `CanvasMapping` as the compositor, so they sit exactly on the preview.
struct RecordingCanvasEditor: View {
    @Bindable var controller: ScreenRecordingController
    @Binding var selection: UUID?

    @State private var drag: DragState?
    @State private var guides: [SnapGuide] = []
    @Environment(\.stTheme) private var theme

    private struct DragState {
        var id: UUID
        var handle: CanvasEditing.Handle
        var start: VideoSource
    }

    /// Where a source's outline is drawn on a plate `plate` big (points).
    static func outlineRect(of source: VideoSource, on plate: CanvasMapping) -> CGRect {
        plate.rect(source.frame).cgRect
    }

    var body: some View {
        let canvas = controller.canvas
        GeometryReader { proxy in
            let plate = CanvasMapping(width: proxy.size.width, height: proxy.size.height)
            ZStack(alignment: .topLeading) {
                previewLayer
                ForEach(controller.layout.orderedVideoSources) { source in
                    outline(source, on: plate)
                }
                ForEach(Array(guides.enumerated()), id: \.offset) { _, guide in
                    guideLine(guide, on: plate, canvas: canvas)
                }
                if let selected = selectedSource, !controller.isLayoutLocked {
                    handles(for: selected, on: plate)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(editGesture(plate: plate, canvas: canvas))
        }
        .aspectRatio(canvas.aspectRatio, contentMode: .fit)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording canvas")
    }

    private var selectedSource: VideoSource? {
        selection.flatMap { id in controller.layout.videoSources.first { $0.id == id } }
    }

    // MARK: Layers

    @ViewBuilder private var previewLayer: some View {
        if controller.isRecording, !controller.options.livePreview {
            message("Live preview is off while recording.")
        } else if let image = controller.preview {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.medium)
                .accessibilityHidden(true)
        } else if !controller.isEnabled {
            message("Switch Screen Recording on to see the live canvas.")
        } else if let text = controller.previewMessage {
            message(text)
        } else {
            message("Starting\u{2026}")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .stStyle(.body)
            .foregroundStyle(theme.inkSecondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func outline(_ source: VideoSource, on plate: CanvasMapping) -> some View {
        let rect = Self.outlineRect(of: source, on: plate)
        let isSelected = source.id == selection
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(isSelected ? theme.accent : STColor.ink.opacity(0.45),
                              style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: isSelected ? [] : [4, 3]))
            if isSelected || controller.preview == nil {
                Text(source.title)
                    .stStyle(.caption)
                    .foregroundStyle(STColor.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .background(STColor.background.opacity(0.75))
                    .padding(2)
            }
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(source.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func handles(for source: VideoSource, on plate: CanvasMapping) -> some View {
        let rect = Self.outlineRect(of: source, on: plate)
        let points = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ]
        return ZStack(alignment: .topLeading) {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                Rectangle()
                    .fill(theme.accent)
                    .frame(width: 8, height: 8)
                    .position(point)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Guides come in canvas pixels.
    private func guideLine(_ guide: SnapGuide, on plate: CanvasMapping, canvas: PixelSize) -> some View {
        Path { path in
            switch guide.axis {
            case .vertical:
                let x = CGFloat(guide.position / Double(max(1, canvas.width)) * plate.width)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: plate.height))
            case .horizontal:
                let y = CGFloat(guide.position / Double(max(1, canvas.height)) * plate.height)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: plate.width, y: y))
            }
        }
        .stroke(theme.accent.opacity(0.9), lineWidth: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Dragging

    private func editGesture(plate: CanvasMapping, canvas: PixelSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard !controller.isLayoutLocked, plate.width > 0, plate.height > 0 else { return }
                if drag == nil { beginDrag(at: value.startLocation, on: plate) }
                guard let drag else { return }
                // Points on the plate to pixels of the canvas, for the drag math.
                let delta = (dx: Double(value.translation.width) / plate.width * Double(canvas.width),
                             dy: Double(value.translation.height) / plate.height * Double(canvas.height))
                let others = controller.layout.videoSources.filter { $0.id != drag.id }.map(\.frame)
                let result = CanvasEditing.drag(
                    drag.handle, source: drag.start, by: delta, canvas: canvas, others: others,
                    contentSize: controller.contentSize(of: drag.id))
                guides = result.guides
                controller.updateLayout { layout in
                    guard let index = layout.videoSources.firstIndex(where: { $0.id == drag.id }) else { return }
                    layout.videoSources[index].frame = result.frame
                    layout.videoSources[index].crop = result.crop
                }
            }
            .onEnded { _ in
                drag = nil
                guides = []
            }
    }

    /// The selected source's handles win; otherwise the topmost source under the press is selected and moved.
    /// Hit-testing runs in the plate's points, on the outlines as drawn.
    private func beginDrag(at point: CGPoint, on plate: CanvasMapping) {
        let press = (x: Double(point.x), y: Double(point.y))
        let cropping = NSEvent.modifierFlags.contains(.option)
        if let selected = selectedSource,
           let handle = CanvasEditing.handle(at: press, frame: plate.rect(selected.frame), tolerance: 8, cropping: cropping) {
            drag = DragState(id: selected.id, handle: handle == .body && cropping ? .body : handle, start: selected)
            return
        }
        for source in controller.layout.orderedVideoSources.reversed() {
            guard CanvasEditing.handle(at: press, frame: plate.rect(source.frame), tolerance: 0, cropping: false) != nil else { continue }
            selection = source.id
            drag = DragState(id: source.id, handle: .body, start: source)
            return
        }
        selection = nil
    }
}
