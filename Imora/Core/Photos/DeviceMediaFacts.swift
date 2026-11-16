import CryptoKit
import Foundation
import Observation
import Photos
import UniformTypeIdentifiers

nonisolated enum MediaCategory: String, CaseIterable, Codable, Sendable {
    case photo, video, livePhoto, screenshot, panorama, selfPortrait, highFrameRate
    case slowMotion, timeLapse, screenRecording, raw, burst, hdr, edited
}

nonisolated struct MediaFact: Equatable, Sendable {
    enum Value: String, Sendable { case yes, no, unknown }
    enum Evidence: String, Sendable { case photoKitSubtype, smartAlbumMembership, resourceType, burstIdentifier, unavailable }
    let value: Value
    let evidence: Evidence
    /// Classification metadata only. This is never original-file evidence.
    let sourceRevision: String
    let extractorVersion = 1
}

nonisolated struct AccessiblePhotoSnapshot: Sendable {
    enum Coverage: String, Sendable { case fullLibrary, selectedPhotos, unavailable }
    struct Resource: Codable, Sendable {
        let type: Int
        let uniformTypeIdentifier: String
    }
    struct Metadata: Sendable {
        let device: DeviceAsset
        let subtypes: UInt
        let resources: [Resource]
        let burstIdentifier: String?
        let selfPortraitMember: Bool?
    }
    let coverage: Coverage
    let visibleIdentifiers: Set<String>
    let assets: [Metadata]
}

nonisolated struct MediaFactsSnapshot: Sendable {
    let coverage: AccessiblePhotoSnapshot.Coverage
    let revision: String
    let factsByIdentifier: [String: [MediaCategory: MediaFact]]

    func value(_ category: MediaCategory, for identifier: String) -> MediaFact.Value {
        factsByIdentifier[identifier]?[category]?.value ?? .unknown
    }

    func identifiers(in category: MediaCategory) -> Set<String> {
        Set(factsByIdentifier.keys.filter { value(category, for: $0) == .yes })
    }

    func counts(in category: MediaCategory) -> (knownYes: Int, unknown: Int) {
        let values = factsByIdentifier.keys.map { value(category, for: $0) }
        return (values.filter { $0 == .yes }.count, values.filter { $0 == .unknown }.count)
    }
}

nonisolated struct DeviceMediaInventory: Sendable {
    let assets: [DeviceAsset]
    let facts: MediaFactsSnapshot
}

/// Reads metadata only. Resource enumeration never exports or downloads media.
nonisolated enum DeviceMediaFacts {
    private struct RevisionInput: Encodable {
        let subtypes: UInt
        let isVideo: Bool
        let resources: [AccessiblePhotoSnapshot.Resource]
        let burstIdentifier: String?
        let selfPortraitMember: Bool?
    }

    private static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try! encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    static func extract(snapshot: AccessiblePhotoSnapshot) -> MediaFactsSnapshot {
        let visible = snapshot.coverage == .unavailable ? [] : snapshot.visibleIdentifiers
        var result: [String: [MediaCategory: MediaFact]] = [:]
        for id in visible {
            result[id] = Dictionary(uniqueKeysWithValues: MediaCategory.allCases.map {
                ($0, .init(value: .unknown, evidence: .unavailable, sourceRevision: "unavailable"))
            })
        }
        for metadata in snapshot.assets where visible.contains(metadata.device.localIdentifier) {
            let resources = metadata.resources.sorted {
                $0.type == $1.type ? $0.uniformTypeIdentifier < $1.uniformTypeIdentifier : $0.type < $1.type
            }
            let revision = digest(RevisionInput(subtypes: metadata.subtypes, isVideo: metadata.device.isVideo,
                resources: resources, burstIdentifier: metadata.burstIdentifier, selfPortraitMember: metadata.selfPortraitMember))
            let subtypes = PHAssetMediaSubtype(rawValue: metadata.subtypes)
            let isVideo = metadata.device.isVideo
            func fact(_ value: MediaFact.Value, _ evidence: MediaFact.Evidence) -> MediaFact {
                .init(value: value, evidence: evidence, sourceRevision: revision)
            }
            func known(_ value: Bool, _ evidence: MediaFact.Evidence = .photoKitSubtype) -> MediaFact {
                fact(value ? .yes : .no, evidence)
            }
            let types = resources.compactMap { UTType($0.uniformTypeIdentifier) }
            let raw: MediaFact = isVideo ? known(false, .resourceType)
                : (types.contains { $0.conforms(to: .rawImage) } ? known(true, .resourceType)
                    : (resources.isEmpty || types.count != resources.count ? fact(.unknown, .unavailable) : known(false, .resourceType)))
            result[metadata.device.localIdentifier] = [
                .photo: known(!isVideo), .video: known(isVideo),
                .livePhoto: known(!isVideo && subtypes.contains(.photoLive)),
                .screenshot: known(!isVideo && subtypes.contains(.photoScreenshot)),
                .panorama: known(!isVideo && subtypes.contains(.photoPanorama)),
                .selfPortrait: metadata.selfPortraitMember.map { known($0, .smartAlbumMembership) } ?? fact(.unknown, .unavailable),
                .highFrameRate: known(isVideo && subtypes.contains(.videoHighFrameRate)),
                // High frame rate does not prove a retimed slow-motion edit.
                .slowMotion: isVideo ? fact(.unknown, .unavailable) : known(false),
                .timeLapse: known(isVideo && subtypes.contains(.videoTimelapse)),
                .screenRecording: known(isVideo && subtypes.contains(.videoScreenRecording)),
                .raw: raw, .burst: known(metadata.burstIdentifier?.isEmpty == false, .burstIdentifier),
                .hdr: isVideo ? fact(.unknown, .unavailable) : known(subtypes.contains(.photoHDR)),
                .edited: resources.isEmpty ? fact(.unknown, .unavailable)
                    : known(resources.contains { $0.type == PHAssetResourceType.adjustmentData.rawValue }, .resourceType)
            ]
        }
        let revision = digest(["device-media-facts-v1", snapshot.coverage.rawValue] + result.keys.sorted().flatMap { id in
            [id] + MediaCategory.allCases.map { category in
                let fact = result[id]![category]!
                return "\(fact.value.rawValue)|\(fact.evidence.rawValue)|\(fact.sourceRevision)"
            }
        })
        return .init(coverage: snapshot.coverage, revision: revision, factsByIdentifier: result)
    }

    @concurrent static func capture() async throws -> DeviceMediaInventory {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let coverage: AccessiblePhotoSnapshot.Coverage = status == .authorized ? .fullLibrary : (status == .limited ? .selectedPhotos : .unavailable)
        guard coverage != .unavailable else {
            return .init(assets: [], facts: extract(snapshot: .init(coverage: coverage, visibleIdentifiers: [], assets: [])))
        }
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetched = PHAsset.fetchAssets(with: options)
        let portraits = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumSelfPortraits, options: nil).firstObject
        let portraitIDs: Set<String>? = portraits.map { collection in
            let members = PHAsset.fetchAssets(in: collection, options: nil)
            return Set((0..<members.count).map { members.object(at: $0).localIdentifier })
        }
        var metadata: [AccessiblePhotoSnapshot.Metadata] = []
        for index in 0..<fetched.count {
            try Task.checkCancellation()
            let asset = fetched.object(at: index)
            guard !asset.isHidden, asset.mediaType == .image || asset.mediaType == .video else { continue }
            metadata.append(.init(device: PhotoLibraryService.snapshot(of: asset), subtypes: asset.mediaSubtypes.rawValue,
                resources: PHAssetResource.assetResources(for: asset).map { .init(type: $0.type.rawValue, uniformTypeIdentifier: $0.uniformTypeIdentifier) },
                burstIdentifier: asset.burstIdentifier, selfPortraitMember: portraitIDs.map { $0.contains(asset.localIdentifier) }))
        }
        try Task.checkCancellation()
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == status else { throw CancellationError() }
        let facts = extract(snapshot: .init(coverage: coverage,
            visibleIdentifiers: Set(metadata.map { $0.device.localIdentifier }), assets: metadata))
        return .init(assets: metadata.map(\.device), facts: facts)
    }
}

/// Shared by device filters and Collections. The observer also covers Limited
/// access, where the backup scanner intentionally does not register.
@Observable
final class DeviceMediaFactsStore: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = DeviceMediaFactsStore()
    private(set) var inventory: DeviceMediaInventory?
    private(set) var generation = 0
    @ObservationIgnored private var loadTask: Task<DeviceMediaInventory, Error>?
    @ObservationIgnored private var observing = false

    func startObserving() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard !observing, status == .authorized || status == .limited else { return }
        PHPhotoLibrary.shared().register(self); observing = true
    }

    func invalidate() {
        generation &+= 1
        inventory = nil
        loadTask?.cancel(); loadTask = nil
    }

    func refresh() async throws -> DeviceMediaInventory {
        startObserving()
        if let inventory {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            let current: AccessiblePhotoSnapshot.Coverage = status == .authorized ? .fullLibrary : (status == .limited ? .selectedPhotos : .unavailable)
            if inventory.facts.coverage == current { return inventory }
            invalidate()
        }
        let requested = generation
        let task: Task<DeviceMediaInventory, Error>
        if let current = loadTask { task = current }
        else {
            task = Task { try await DeviceMediaFacts.capture() }
            loadTask = task
        }
        do {
            let current = try await task.value
            guard requested == generation, !Task.isCancelled else { throw CancellationError() }
            inventory = current; loadTask = nil
            return current
        } catch {
            if requested == generation { loadTask = nil }
            throw error
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.invalidate()
            if !PhotoLibraryService.hasFullAccess { LocalImageLoader.shared.noteLibraryChange() }
        }
    }
}
