import Foundation
import SwiftUI

/// the photos stacked with the one on screen. owners pick which photo leads
/// the stack, take photos out, or unstack them all. the stacks api is on
/// every immich 3.x, gallery 5.x and imora server.
struct AssetStackSection: View {
    @Environment(SessionStore.self) private var session
    let stackInfo: AssetStackInfo
    let isOwner: Bool

    @State private var stack: AssetStack?
    @State private var isGone = false
    @State private var isWorking = false
    @State private var confirmUnstack = false

    var body: some View {
        if isGone {
            Text("These photos are no longer stacked.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let stack {
                            ForEach(stack.assets) { item in
                                thumbnail(item, isPrimary: item.id == stack.primaryAssetId)
                            }
                        } else {
                            ForEach(0..<min(stackInfo.assetCount, 6), id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(.secondarySystemFill))
                                    .frame(width: 72, height: 72)
                            }
                        }
                    }
                }
                if isOwner {
                    Button("Unstack", role: .destructive) { confirmUnstack = true }
                        .font(.subheadline)
                        .disabled(isWorking)
                        .confirmationDialog("Unstack these photos?", isPresented: $confirmUnstack,
                                            titleVisibility: .visible) {
                            Button("Unstack", role: .destructive) { Task { await unstack() } }
                        } message: {
                            Text("Every photo stays, shown on its own again.")
                        }
                }
            }
            .task(id: stackInfo.id) { await load() }
        }
    }

    private func thumbnail(_ item: AssetDetail, isPrimary: Bool) -> some View {
        Group {
            if let client = session.client {
                RemoteImage(url: client.thumbnailURL(assetID: item.id), targetPixelSize: 220, thumbhash: item.thumbhash)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(.rect(cornerRadius: 10))
        .overlay(alignment: .topLeading) {
            if isPrimary {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.45), in: .circle)
                    .padding(4)
            }
        }
        .contextMenu {
            if isOwner {
                if !isPrimary {
                    Button {
                        Task { await setPrimary(item.id) }
                    } label: {
                        Label("Set as Primary", systemImage: "star")
                    }
                }
                Button(role: .destructive) {
                    Task { await remove(item.id) }
                } label: {
                    Label("Remove from Stack", systemImage: "square.stack.3d.down.forward")
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(isPrimary ? String(localized: "\(item.originalFileName), primary") : item.originalFileName)
    }

    private func load() async {
        do {
            stack = try await session.client?.stack(id: stackInfo.id)
        } catch ImoraError.http(404, _) {
            isGone = true
        } catch {}
    }

    private func setPrimary(_ assetID: String) async {
        guard let client = session.client, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let previous = stack?.primaryAssetId
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't change the primary photo."),
            apply: { stack?.primaryAssetId = assetID },
            rollback: { if let previous { stack?.primaryAssetId = previous } },
            request: { try await client.setStackPrimary(stackID: stackInfo.id, assetID: assetID) }
        )
    }

    private func remove(_ assetID: String) async {
        guard let client = session.client, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.removeFromStack(stackID: stackInfo.id, assetID: assetID)
            await load()
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't remove the photo from the stack."), error: error)
        }
    }

    private func unstack() async {
        guard let client = session.client, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.deleteStack(id: stackInfo.id)
            isGone = true
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't unstack the photos."), error: error)
        }
    }
}
