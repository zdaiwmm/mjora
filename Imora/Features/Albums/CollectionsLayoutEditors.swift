import SwiftUI

struct CollectionsLayoutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var layout: CollectionsLayout

    var body: some View {
        NavigationStack {
            List {
                Section("Collection Previews") {
                    Picker("Preview Size", selection: $layout.previewSize) {
                        ForEach(CollectionPreviewSize.allCases) { size in Text(size.title).tag(size) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("collections-preview-size")
                }
                Section("Sections") {
                ForEach(layout.sections) { section in
                    Toggle(section.title, isOn: Binding(
                        get: { !layout.collapsed.contains(section) },
                        set: { expanded in
                            if expanded == layout.collapsed.contains(section) { layout.toggleCollapsed(section) }
                        }))
                }
                .onMove { layout.moveSections(from: $0, to: $1) }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customize Collections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct PinnedCollectionsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @Binding var layout: CollectionsLayout
    let albums: [Album]

    var body: some View {
        NavigationStack {
            List {
                Section("Collections") {
                    ForEach(["favorites", "recent", "places", "people", "archive", "locked", "trash", "duplicates", "largeFiles", "cleanup"], id: \.self) { id in
                        if session.collectionsAvailability.allows(id) {
                            pinRow(id: id, title: shortcutTitle(id), symbol: shortcutSymbol(id))
                        }
                    }
                }
                Section("Albums") {
                    ForEach(albums.filter { !$0.isPending }) { album in
                        pinRow(id: "album:\(album.id)", title: album.albumName, symbol: "rectangle.stack")
                    }
                }
            }
            .navigationTitle("Pinned Collections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func pinRow(id: String, title: String, symbol: String) -> some View {
        Button { layout.togglePin(id) } label: {
            HStack {
                Label(title, systemImage: symbol).foregroundStyle(.primary)
                Spacer()
                Image(systemName: layout.pinnedIDs.contains(id) ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(.tint)
            }
        }
        .accessibilityIdentifier("collections-pin-\(id)")
        .accessibilityValue(layout.pinnedIDs.contains(id) ? "Pinned" : "Not Pinned")
    }
}
