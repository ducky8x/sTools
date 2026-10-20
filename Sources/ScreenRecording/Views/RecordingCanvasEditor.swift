import AppKit
import STDesign
import SwiftUI

/// The page's plate (spec 5.4.3): the live composite, with every source's frame drawn over it. Drag a source to
/// move it (snapping to edges, center and other sources), drag a corner or edge to resize, ⌥-drag to crop.
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

    var body: some View {
        let canvas = controller.canvas
        GeometryReader { proxy in
            let scale = proxy.size.width / CGFloat(max(1, canvas.width))
            ZStack(alignment: .topLeading) {
                previewLayer
                ForEach(controller.layout.orderedVideoSources) { source in
                    outline(source, scale: scale)
                }
                ForEach(Array(guides.enumerated()), id: \.offset) { _, guide in
                    guideLine(guide, scale: scale, size: proxy.size)
                }
                if let selected = selectedSource, !controller.isLayoutLocked {
                    handles(for: selected, scale: scale)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(editGesture(scale: scale, canvas: canvas))
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

    private func outline(_ source: VideoSource, scale: CGFloat) -> some View {
        let rect = source.frame.cgRect.applying(CGAffineTransform(scaleX: scale, y: scale))
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

    private func handles(for source: VideoSource, scale: CGFloat) -> some View {
        let rect = source.frame.cgRect.applying(CGAffineTransform(scaleX: scale, y: scale))
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

    private func guideLine(_ guide: SnapGuide, scale: CGFloat, size: CGSize) -> some View {
        let position = CGFloat(guide.position) * scale
        return Path { path in
            switch guide.axis {
            case .vertical:
                path.move(to: CGPoint(x: position, y: 0))
                path.addLine(to: CGPoint(x: position, y: size.height))
            case .horizontal:
                path.move(to: CGPoint(x: 0, y: position))
                path.addLine(to: CGPoint(x: size.width, y: position))
            }
        }
        .stroke(theme.accent.opacity(0.9), lineWidth: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Dragging

    private func editGesture(scale: CGFloat, canvas: PixelSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard !controller.isLayoutLocked, scale > 0 else { return }
                if drag == nil { beginDrag(at: value.startLocation, scale: scale) }
                guard let drag else { return }
                let delta = (dx: Double(value.translation.width / scale), dy: Double(value.translation.height / scale))
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
    private func beginDrag(at point: CGPoint, scale: CGFloat) {
        let canvasPoint = (x: Double(point.x / scale), y: Double(point.y / scale))
        let tolerance = Double(8 / scale)
        let cropping = NSEvent.modifierFlags.contains(.option)
        if let selected = selectedSource,
           let handle = CanvasEditing.handle(at: canvasPoint, frame: selected.frame, tolerance: tolerance, cropping: cropping) {
            drag = DragState(id: selected.id, handle: handle == .body && cropping ? .body : handle, start: selected)
            return
        }
        for source in controller.layout.orderedVideoSources.reversed() {
            guard CanvasEditing.handle(at: canvasPoint, frame: source.frame, tolerance: 0, cropping: false) != nil else { continue }
            selection = source.id
            drag = DragState(id: source.id, handle: .body, start: source)
            return
        }
        selection = nil
    }
}
