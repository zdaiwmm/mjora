import Foundation
import Observation
import SwiftUI

/// Filtered cloud views keep their paged loader. This metadata-only supplement
/// supplies the matching device originals without downloading photo contents.
@MainActor @Observable
final class PhotosLocalMediaLibrary {
    private(set) var assets: [Asset] = []
    private(set) var error: String?
    @ObservationIgnored private var projectionTask: Task<Void, Never>?

    func project(cloud: [Asset], includesDevice: Bool, remoteByLocal: [String: String], into timeline: TimelineModel) {
        projectionTask?.cancel()
        let device = assets
        projectionTask = Task {
            let combined = includesDevice ? await Self.merged(cloud: cloud, device: device, remoteByLocal: remoteByLocal) : cloud
            guard !Task.isCancelled else { return }
            timeline.replaceSuppliedAssets(combined, groupsByDate: true)
        }
    }

    func refresh(media: PhotoMediaFilter, session: SessionStore) async {
        let client = session.client
        guard let backup = session.backup else { assets = []; return }
        var local = await backup.localTimelineAssets().map { $0.device.asAsset(backedUp: $0.backedUp) }
        guard !Task.isCancelled, session.client === client else { return }
        do {
            if media == .edited { local = await PhotoFilterMetadata.editedDeviceAssets(local) }
            if media == .notInAlbum {
                let pairs = backup.remoteIdentifierByLocalId
                let verified = pairs.filter { backup.hasVerifiedBackup(localIdentifier: $0.key) }
                let uncertain = Set(pairs.keys).subtracting(verified.keys)
                let unfiled: Set<String>
                if !verified.isEmpty {
                    guard let client else { throw PhotoFilterMetadataError.albumMembershipUnavailable }
                    unfiled = try await PhotoAppAlbumMembershipCache.shared.unfiledIDs(
                        account: client.offlineAccountKey, remoteIDs: Set(verified.values)) { id in
                            try await !client.albums(assetID: id).isEmpty
                        }
                } else { unfiled = [] }
                local = try PhotoFilterMetadata.applyingAppAlbumMembership(to: local, verifiedRemoteByLocal: verified,
                    unfiledRemoteIDs: unfiled, uncertainLocalIDs: uncertain)
            }
            guard !Task.isCancelled, session.client === client else { return }
            assets = local.filter { media.includes($0) }
            error = nil
        } catch {
            guard !Task.isCancelled, session.client === client else { return }
            self.error = error.localizedDescription
        }
    }

    @concurrent
    nonisolated static func merged(cloud: [Asset], device: [Asset], remoteByLocal: [String: String]) async -> [Asset] {
        let cloudIDs = Set(cloud.map(\.id))
        return (cloud + device.filter { asset in
            guard asset.isLocalBackedUp, let localID = asset.localIdentifier, let remoteID = remoteByLocal[localID] else { return true }
            return !cloudIDs.contains(remoteID)
        }).sorted { $0.localDate == $1.localDate ? $0.id < $1.id : $0.localDate < $1.localDate }
    }
}

struct PhotosLocalMediaNotice: View {
    let library: PhotosLocalMediaLibrary
    let retry: () async -> Void

    var body: some View {
        if let error = library.error {
            VStack(spacing: 8) {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                Button("Retry Device Photos") { Task { await retry() } }
            }
            .padding()
        }
    }
}
