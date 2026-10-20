import STDesign
import SwiftUI

/// Everything Simple Modifications can send, grouped as Karabiner's own picker groups it (spec 5.5.3).
struct KeyPicker: View {
    let onPick: (KarabinerEvent) -> Void

    @State private var query = ""
    @Environment(\.stTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            STTextField("Search", text: $query)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections, id: \.category.id) { section in
                        Section {
                            ForEach(section.entries) { entry in row(entry) }
                        } header: {
                            Text(section.category.title)
                                .stStyle(.label)
                                .foregroundStyle(theme.inkTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .background(STColor.surface)
                        }
                    }
                    if sections.isEmpty {
                        Text("Nothing matches \u{201C}\(query)\u{201D}.").stStyle(.body).foregroundStyle(theme.inkSecondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340, height: 420)
        .background(STColor.surface)
    }

    private func row(_ entry: KeyEntry) -> some View {
        let name = KeyNames.name(for: entry.event)
        return Button { onPick(entry.event) } label: {
            HStack {
                Text(name).stStyle(.body).foregroundStyle(STColor.ink)
                Spacer(minLength: 8)
                if entry.label.lowercased() != name.lowercased() {
                    Text(entry.label).stStyle(.caption).foregroundStyle(theme.inkTertiary).lineLimit(1)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sections: [(category: KeyCategory, entries: [KeyEntry])] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return KeyTable.shared.categories.compactMap { category in
            let entries = KeyTable.shared.entries(forCategory: category.id).filter { entry in
                entry.canBeTarget && (needle.isEmpty
                    || KeyNames.name(for: entry.event).lowercased().contains(needle)
                    || entry.label.lowercased().contains(needle))
            }
            return entries.isEmpty ? nil : (category, entries)
        }
    }
}
