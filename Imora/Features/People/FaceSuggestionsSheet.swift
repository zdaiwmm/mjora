import Foundation
import SwiftUI

/// gallery's near-miss faces for one person: confirm the ones that are them,
/// reject the rest. each answer drops the face from the list.
struct FaceSuggestionsSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    let person: Person
    let onChanged: () -> Void

    @State private var suggestions: [FaceSuggestion] = []
    @State private var total = 0
    @State private var isLoading = true
    @State private var workingIDs = Set<String>()
    @State private var didChange = false

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(suggestions) { suggestion in
                        card(suggestion)
                    }
                }
                .padding(16)
            }
            .navigationTitle(person.name.isEmpty ? "Suggestions" : "Is This \(person.name)?")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if suggestions.isEmpty {
                    if isLoading {
                        ProgressView()
                    } else {
                        ContentUnavailableView("All Caught Up", systemImage: "checkmark.circle")
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .onDisappear {
                if didChange { onChanged() }
            }
        }
    }

    private func card(_ suggestion: FaceSuggestion) -> some View {
        VStack(spacing: 8) {
            FaceCrop(
                assetID: suggestion.assetId,
                box: CGRect(
                    x: suggestion.boundingBoxX1,
                    y: suggestion.boundingBoxY1,
                    width: suggestion.boundingBoxX2 - suggestion.boundingBoxX1,
                    height: suggestion.boundingBoxY2 - suggestion.boundingBoxY1
                ),
                imageSize: CGSize(width: suggestion.imageWidth, height: suggestion.imageHeight)
            )
            .frame(width: 104, height: 104)
            .clipShape(.circle)
            .accessibilityLabel("Suggested face")
            HStack(spacing: 10) {
                Button {
                    Task { await answer(suggestion, confirm: false) }
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 36, height: 30)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Not \(person.name.isEmpty ? String(localized: "this person") : person.name)")
                Button {
                    Task { await answer(suggestion, confirm: true) }
                } label: {
                    Image(systemName: "checkmark")
                        .frame(width: 36, height: 30)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("This is \(person.name.isEmpty ? String(localized: "them") : person.name)")
            }
            .disabled(workingIDs.contains(suggestion.id))
        }
    }

    private func load() async {
        defer { isLoading = false }
        guard let page = try? await session.client?.faceSuggestions(personID: person.id) else { return }
        suggestions = page.items
        total = page.total
    }

    private func answer(_ suggestion: FaceSuggestion, confirm: Bool) async {
        guard let client = session.client, !workingIDs.contains(suggestion.id) else { return }
        workingIDs.insert(suggestion.id)
        defer { workingIDs.remove(suggestion.id) }
        let snapshot = suggestions
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't save your answer."),
            apply: { withAnimation(PhotosMotion.layout) { suggestions.removeAll { $0.id == suggestion.id } } },
            rollback: { suggestions = snapshot },
            request: {
                if confirm {
                    try await client.confirmFaceSuggestion(personID: person.id, faceID: suggestion.id)
                } else {
                    try await client.rejectFaceSuggestion(personID: person.id, faceID: suggestion.id)
                }
            },
            commit: { _ in didChange = true }
        )
        // the first page ran out but more remain on the server.
        if suggestions.isEmpty, total > snapshot.count {
            await load()
        }
    }
}

/// a face cut out of an asset's preview, the box in the detected image's pixels.
struct FaceCrop: View {
    @Environment(SessionStore.self) private var session
    let assetID: String
    let box: CGRect
    let imageSize: CGSize

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            // a little room around the face, like the server's own crops.
            let padded = box.insetBy(dx: -box.width * 0.2, dy: -box.height * 0.2)
            let scale = side / max(padded.width, padded.height, 1)
            if let client = session.client {
                RemoteImage(url: client.thumbnailURL(assetID: assetID, size: "preview"), targetPixelSize: 720)
                    .frame(width: imageSize.width * scale, height: imageSize.height * scale)
                    .offset(
                        x: -padded.midX * scale + side / 2,
                        y: -padded.midY * scale + side / 2
                    )
            }
        }
        .clipped()
        .background(Color(.secondarySystemFill))
    }
}
