import STDesign
import SwiftUI

/// The profile menu on the page's title row (spec 5.5.6): every profile, the current one checked; choosing
/// one switches Karabiner to it.
public struct KeyRebinderProfileMenu: View {
    @Bindable private var controller: KeyRebinderController
    @State private var showsNew = false
    @State private var showsManage = false
    @Environment(\.stTheme) private var theme

    public init(controller: KeyRebinderController) {
        self.controller = controller
    }

    public var body: some View {
        Menu {
            ForEach(controller.profileNames, id: \.self) { name in
                Button {
                    Task { await controller.selectProfile(name) }
                } label: {
                    if name == controller.currentProfile { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            Divider()
            Button("New Profile\u{2026}") { showsNew = true }
            Button("Manage Profiles\u{2026}") { showsManage = true }
        } label: {
            STMenuLabel(controller.currentProfile ?? "No profile")
        }
        .stMenuStyle()
        .disabled(!controller.canEdit || controller.isBusy)
        .accessibilityLabel("Karabiner profile: \(controller.currentProfile ?? "none")")
        // Sheets are windows of their own, so each gets its own motion root.
        .sheet(isPresented: $showsNew) { NewProfileSheet(controller: controller).stMotionRoot(theme) }
        .sheet(isPresented: $showsManage) { ProfileManagerSheet(controller: controller).stMotionRoot(theme) }
    }
}

/// New Profile…: a name, then empty or a copy of the current profile.
struct NewProfileSheet: View {
    let controller: KeyRebinderController

    @Environment(\.dismiss) private var dismiss
    @Environment(\.stTheme) private var theme
    @State private var name = ""
    @State private var duplicatesCurrent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Profile").stStyle(.sectionTitle).foregroundStyle(STColor.ink)
            STTextField("Name", text: $name, isInvalid: problem != nil)
            if let problem {
                Text(problem).stStyle(.caption).foregroundStyle(STColor.danger)
            }
            STSegmented(selection: $duplicatesCurrent, options: [
                STSegmentedOption(false, "Empty"),
                STSegmentedOption(true, "Copy of \u{201C}\(controller.currentProfile ?? "")\u{201D}"),
            ])
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(STButtonStyle(.quiet)).keyboardShortcut(.cancelAction)
                Button("Create") {
                    let chosen = name
                    let copy = duplicatesCurrent
                    Task {
                        await controller.createProfile(named: chosen, duplicatingCurrent: copy)
                        dismiss()
                    }
                }
                .buttonStyle(STButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(STColor.background)
        .onAppear { name = controller.suggestedNewProfileName() }
    }

    private var problem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "A profile needs a name." }
        if controller.profileNames.contains(trimmed) { return "There is already a profile with this name." }
        return nil
    }
}

/// Rename, duplicate, delete and reorder profiles. Each change goes through the write-safety steps.
struct ProfileManagerSheet: View {
    let controller: KeyRebinderController

    @Environment(\.dismiss) private var dismiss
    @Environment(\.stTheme) private var theme
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Profiles").stStyle(.sectionTitle).foregroundStyle(STColor.ink)
            Text("Drag to reorder. The current profile can\u{2019}t be deleted; switch to another one first.")
                .stStyle(.caption).foregroundStyle(theme.inkTertiary)
            List {
                ForEach(controller.profileNames, id: \.self) { name in row(name) }
                    .onMove { source, offset in
                        guard let from = source.first else { return }
                        let to = offset > from ? offset - 1 : offset
                        guard to != from else { return }
                        Task { await controller.moveProfile(from: from, to: to) }
                    }
                    .listRowBackground(STColor.surface)
            }
            .scrollContentBackground(.hidden)
            .background(STColor.surface, in: RoundedRectangle(cornerRadius: 10))
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(STButtonStyle(.primary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 440)
        .background(STColor.background)
        .disabled(controller.isBusy)
        .confirmationDialog(
            "Delete the profile \u{201C}\(deleting ?? "")\u{201D}?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { name in
            Button("Delete", role: .destructive) { Task { await controller.deleteProfile(name) } }
        } message: { _ in
            Text("Its rebinds go with it. A backup of karabiner.json is made first.")
        }
    }

    @ViewBuilder private func row(_ name: String) -> some View {
        HStack(spacing: 10) {
            if renaming == name {
                STTextField("Name", text: $newName)
                Button("Save") {
                    let target = newName
                    renaming = nil
                    Task { await controller.renameProfile(name, to: target) }
                }
                .buttonStyle(STButtonStyle(.primary))
                .disabled(!isValidRename(from: name))
                Button("Cancel") { renaming = nil }.buttonStyle(STButtonStyle(.quiet))
            } else {
                Text(name).stStyle(.body).foregroundStyle(STColor.ink)
                if name == controller.currentProfile {
                    Text("Current").stStyle(.label).foregroundStyle(theme.accent)
                }
                Spacer()
                Button("Rename") {
                    newName = name
                    renaming = name
                }
                .buttonStyle(STButtonStyle(.quiet))
                Button("Duplicate") {
                    let copy = controller.suggestedCopyName(of: name)
                    Task { await controller.duplicateProfile(name, as: copy) }
                }
                .buttonStyle(STButtonStyle(.quiet))
                Button("Delete\u{2026}") { deleting = name }
                    .buttonStyle(STButtonStyle(.quiet))
                    .disabled(name == controller.currentProfile)
            }
        }
        .padding(.vertical, 4)
    }

    private func isValidRename(from old: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && (trimmed == old || !controller.profileNames.contains(trimmed))
    }
}
