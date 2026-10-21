import STDesign
import SwiftUI

/// A section heading, marked as a header for VoiceOver.
struct RecordingHeading: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).stStyle(.sectionTitle).foregroundStyle(STColor.ink).accessibilityAddTraits(.isHeader)
    }
}

/// The video sources in stack order, Add Source, and the selected source's fields (spec 5.4.3).
struct RecordingSourcesSection: View {
    @Bindable var controller: ScreenRecordingController
    @Binding var selection: UUID?

    @State private var showsAdd = false
    @Environment(\.stTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                RecordingHeading("Sources")
                Spacer()
                Button("Add Source\u{2026}") { showsAdd = true }
                    .buttonStyle(STButtonStyle(.secondary))
                    .disabled(controller.isLayoutLocked)
                    .popover(isPresented: $showsAdd, arrowEdge: .bottom) {
                        // A popover is a window of its own, so it gets its own motion root.
                        AddSourcePopover(controller: controller) { showsAdd = false }.stMotionRoot(theme)
                    }
            }
            Text("Minecraft and sTools\u{2019} overlays are always the bottom layer. Sources stack on top, front first.")
                .stStyle(.caption).foregroundStyle(theme.inkTertiary)
            let ordered = Array(controller.layout.orderedVideoSources.reversed())
            if ordered.isEmpty {
                Text("No sources yet.").stStyle(.body).foregroundStyle(theme.inkSecondary)
            }
            ForEach(ordered) { source in
                Button { selection = selection == source.id ? nil : source.id } label: {
                    HStack {
                        Text(source.title).stStyle(.body).foregroundStyle(STColor.ink).lineLimit(1)
                        Spacer()
                        Text(kindName(source.kind)).stStyle(.label).foregroundStyle(theme.inkTertiary)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(source.id == selection ? STColor.raised : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(source.id == selection ? [.isSelected] : [])
            }
            if let id = selection, let source = controller.layout.videoSources.first(where: { $0.id == id }) {
                SourceInspector(controller: controller, source: source) { selection = nil }
            }
        }
    }

    private func kindName(_ kind: VideoSourceKind) -> String {
        switch kind {
        case .window: "Window"
        case .display: "Display"
        case .camera: "Camera"
        case .browser: "Web page"
        }
    }
}

/// X, Y, W, H and crop as numbers (spec 5.4.3: every source has these fields), plus look and stack order.
struct SourceInspector: View {
    @Bindable var controller: ScreenRecordingController
    let source: VideoSource
    let onRemove: () -> Void

    @Environment(\.stTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 14) {
            Text(source.title).stStyle(.body).foregroundStyle(STColor.ink).lineLimit(2)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    PixelField("X", value: frameBinding(\.x))
                    PixelField("Y", value: frameBinding(\.y))
                    PixelField("W", value: frameBinding(\.width))
                    PixelField("H", value: frameBinding(\.height))
                }
                GridRow {
                    PixelField("Crop left", value: cropBinding(0))
                    PixelField("Crop top", value: cropBinding(1))
                    PixelField("Crop right", value: cropBinding(2))
                    PixelField("Crop bottom", value: cropBinding(3))
                }
            }
            Text("Drag a corner or edge on the canvas to resize; hold \u{2325} while dragging to crop.")
                .stStyle(.caption).foregroundStyle(theme.inkTertiary)
            STSettingsRow("Opacity") {
                STSlider(value: binding(\.opacity, scale: 100), in: 5...100, label: "Opacity", valueText: { "\(Int($0))%" })
            }
            STSettingsRow("Corner radius") {
                STSlider(value: binding(\.cornerRadius), in: 0...200, label: "Corner radius", valueText: { "\(Int($0)) px" })
            }
            STSettingsRow("Border") {
                HStack(spacing: 12) {
                    STSlider(value: binding(\.border.width), in: 0...40, label: "Border width", valueText: { "\(Int($0)) px" })
                    STColorWell(hex: Binding(get: { String(source.border.colorHex.prefix(7)) },
                                             set: { hex in edit { $0.border.colorHex = hex } }), label: "Border color")
                }
            }
            HStack(spacing: 8) {
                Button("To Front") { controller.updateLayout { $0.bringToFront(source.id) } }
                Button("Forward") { controller.updateLayout { $0.moveForward(source.id) } }
                Button("Backward") { controller.updateLayout { $0.moveBackward(source.id) } }
                Button("To Back") { controller.updateLayout { $0.sendToBack(source.id) } }
                Spacer()
                Button("Remove") {
                    controller.updateLayout { $0.removeVideoSource(source.id) }
                    onRemove()
                }
            }
            .buttonStyle(STButtonStyle(.quiet))
        }
        .padding(16)
        .background(STColor.surface, in: shape)
        .overlay { shape.strokeBorder(STColor.rule, lineWidth: 1) }
        .disabled(controller.isLayoutLocked)
    }

    private func edit(_ change: @escaping (inout VideoSource) -> Void) {
        let id = source.id
        controller.updateLayout { layout in
            guard let index = layout.videoSources.firstIndex(where: { $0.id == id }) else { return }
            change(&layout.videoSources[index])
        }
    }

    private func frameBinding(_ keyPath: WritableKeyPath<PixelRect, Double>) -> Binding<Int> {
        Binding(get: { Int(source.frame[keyPath: keyPath].rounded()) },
                set: { value in edit { $0.frame[keyPath: keyPath] = Double(value) } })
    }

    private func binding(_ keyPath: WritableKeyPath<VideoSource, Double>, scale: Double = 1) -> Binding<Double> {
        Binding(get: { source[keyPath: keyPath] * scale },
                set: { value in edit { $0[keyPath: keyPath] = value / scale } })
    }

    /// Crop in pixels of the source's content (its latest frame, or its frame before the first one arrives).
    private func cropBinding(_ side: Int) -> Binding<Int> {
        let size = controller.contentSize(of: source.id)
            ?? PixelSize(width: Int(source.frame.width), height: Int(source.frame.height))
        return Binding(
            get: {
                let pixels = source.crop.pixels(of: size)
                return [pixels.left, pixels.top, pixels.right, pixels.bottom][side]
            },
            set: { value in
                var pixels = source.crop.pixels(of: size)
                switch side {
                case 0: pixels.left = max(0, value)
                case 1: pixels.top = max(0, value)
                case 2: pixels.right = max(0, value)
                default: pixels.bottom = max(0, value)
                }
                let crop = CropInsets(left: pixels.left, top: pixels.top, right: pixels.right, bottom: pixels.bottom, of: size)
                edit { $0.crop = crop }
            })
    }
}

/// A labeled whole-number field.
struct PixelField: View {
    let label: String
    @Binding var value: Int
    @Environment(\.stTheme) private var theme

    init(_ label: String, value: Binding<Int>) {
        self.label = label
        _value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).stStyle(.label).foregroundStyle(theme.inkTertiary)
            TextField(label, value: $value, format: .number)
                .textFieldStyle(.plain)
                .font(STFont.figures(13))
                .foregroundStyle(STColor.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(STColor.raised, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(STColor.rule, lineWidth: 1) }
                .frame(minWidth: 70)
                .labelsHidden()
        }
    }
}

/// Windows, displays, cameras, a web page, app sound and microphones (spec 5.4.3).
struct AddSourcePopover: View {
    @Bindable var controller: ScreenRecordingController
    let close: () -> Void

    @State private var address = ""
    @Environment(\.stTheme) private var theme

    var body: some View {
        let available = controller.available
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !available.canListScreens {
                    Text("Windows and displays need the Screen & System Audio Recording permission.")
                        .stStyle(.caption).foregroundStyle(STColor.danger)
                }
                group("Windows", available.windows.map { window in
                    (title: window.title.isEmpty ? window.appName : "\(window.appName) \u{2014} \(window.title)", action: {
                        controller.addVideo(.window(window), contentSize: available.windowSizes[window.windowID] ?? PixelSize(width: 1280, height: 720))
                    })
                })
                group("Displays", available.displays.map { display in
                    (title: display.name, action: {
                        controller.addVideo(.display(display), contentSize: available.displaySizes[display.displayID] ?? PixelSize(width: 1920, height: 1080))
                    })
                })
                group("Cameras", available.cameras.map { camera in
                    (title: camera.name, action: { controller.addVideo(.camera(camera), contentSize: PixelSize(width: 1920, height: 1080)) })
                })
                VStack(alignment: .leading, spacing: 6) {
                    Text("Web page").stStyle(.label).foregroundStyle(theme.inkTertiary)
                    HStack {
                        STTextField("Address", text: $address)
                        Button("Add") {
                            controller.addBrowserSource(url: address)
                            close()
                        }
                        .buttonStyle(STButtonStyle(.secondary))
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("A web page\u{2019}s own sound isn\u{2019}t recorded yet.").stStyle(.caption).foregroundStyle(theme.inkTertiary)
                }
                group("App sound", available.apps.map { app in
                    (title: app.name, action: { controller.addAudio(.app(bundleID: app.bundleID), name: app.name) })
                })
                group("Microphones", available.microphones.map { microphone in
                    (title: microphone.name, action: { controller.addAudio(.microphone(uniqueID: microphone.uniqueID), name: microphone.name) })
                })
            }
            .padding(16)
        }
        .frame(width: 380, height: 460)
        .background(STColor.surface)
        .task { await controller.refreshAvailableSources() }
    }

    @ViewBuilder private func group(_ title: String, _ items: [(title: String, action: () -> Void)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).stStyle(.label).foregroundStyle(theme.inkTertiary)
            if items.isEmpty {
                Text("None found").stStyle(.caption).foregroundStyle(theme.inkTertiary).padding(.vertical, 4)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button {
                    item.action()
                    close()
                } label: {
                    Text(item.title).stStyle(.body).foregroundStyle(STColor.ink).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Minecraft's sound and the added sound sources, each with a volume (spec 5.4.1).
struct RecordingSoundSection: View {
    @Bindable var controller: ScreenRecordingController
    @Environment(\.stTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RecordingHeading("Sound")
            Text("Track 1 of the file is the mix; each source also gets its own track, named after it.")
                .stStyle(.caption).foregroundStyle(theme.inkTertiary)
                .padding(.bottom, 6)
            STSettingsRow("Minecraft") {
                HStack(spacing: 14) {
                    if controller.layout.includesMinecraftAudio {
                        STSlider(value: Binding(get: { controller.layout.minecraftAudioVolume * 100 },
                                                set: { value in controller.updateLayout { $0.minecraftAudioVolume = value / 100 } }),
                                 in: 0...150, label: "Minecraft volume", valueText: { "\(Int($0))%" })
                    }
                    STSwitch(isOn: Binding(get: { controller.layout.includesMinecraftAudio },
                                           set: { on in controller.updateLayout { $0.includesMinecraftAudio = on } }), label: "Record Minecraft's sound")
                }
            }
            ForEach(controller.layout.audioSources) { source in
                STSettingsRow(source.name) {
                    HStack(spacing: 14) {
                        STSlider(value: Binding(get: { source.volume * 100 },
                                                set: { value in controller.updateLayout { $0.setVolume(value / 100, forAudioSource: source.id) } }),
                                 in: 0...150, label: "\(source.name) volume", valueText: { "\(Int($0))%" })
                        Button("Remove") { controller.updateLayout { $0.removeAudioSource(source.id) } }
                            .buttonStyle(STButtonStyle(.quiet))
                    }
                }
            }
        }
        .disabled(controller.isLayoutLocked)
    }
}
