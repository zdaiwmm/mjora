import CryptoKit
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import os

nonisolated enum PhotoLibraryError: LocalizedError {
    case assetMissing
    case resourceMissing
    case insufficientStorage
    case exportFailed
    case unexpectedSize

    var errorDescription: String? {
        switch self {
        case .assetMissing: String(localized: "the photo no longer exists on this device.")
        case .resourceMissing: String(localized: "the photo data could not be read.")
        case .insufficientStorage: String(localized: "not enough free space on this device. an upload needs about as much free space as the file itself.")
        case .exportFailed: String(localized: "the photo could not be exported.")
        case .unexpectedSize: String(localized: "the photo data did not match its reported size.")
        }
    }
}

/// sendable snapshot of the phasset fields backup cares about.
nonisolated struct DeviceAsset: Codable, Equatable, Sendable {
    let localIdentifier: String
    let isVideo: Bool
    let isLivePhoto: Bool
    let isScreenshot: Bool
    let creationDate: Date?
    let modificationDate: Date?
    let isFavorite: Bool
    let durationMs: Int
    let pixelWidth: Int
    let pixelHeight: Int

    /// timeline representation of a device asset that is not on the server
    /// yet. dates follow the photographer-local convention the grids use.
    func asAsset(backedUp: Bool) -> Asset {
        let created = creationDate ?? modificationDate ?? .distantPast
        return Asset(
            id: "local-\(localIdentifier)",
            ownerId: "",
            isImage: !isVideo,
            isFavorite: isFavorite,
            isTrashed: false,
            visibility: .timeline,
            thumbhash: nil,
            fileCreatedAt: created,
            localOffsetHours: Double(TimeZone.current.secondsFromGMT(for: created)) / 3600,
            duration: isVideo ? durationMs : nil,
            livePhotoVideoId: nil,
            ratio: pixelHeight > 0 ? Double(pixelWidth) / Double(pixelHeight) : 1,
            city: nil,
            country: nil,
            createdAt: nil,
            localIdentifier: localIdentifier,
            isLocalBackedUp: backedUp,
            hasLocalMotion: isLivePhoto
        )
    }
}

/// photokit wrapper for backup: scanning, hashing, exporting and deleting.
/// heavy functions are @concurrent so they never run on the main actor.
nonisolated enum PhotoLibraryService {
    /// minimum free space kept while exporting originals for upload.
    private static let storageFloor: Int64 = 512 << 20

    // MARK: - authorization

    /// backup and cleanup need full access: a limited scan hides assets, which
    /// would poison index pruning and make whole-library backup a lie.
    static var hasFullAccess: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    /// every request funnels through here so the observable mirror stays
    /// current no matter which action triggered the prompt.
    static func requestFullAccess() async -> Bool {
        let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized
        await PhotoAccess.shared.refresh()
        return granted
    }

    // MARK: - scanning

    /// the last full scan with the library change token it was taken at.
    /// a launch asks for the scan from several places within a second - the
    /// reconcile run, the timeline merge, a library change notice - and each
    /// walk of a large library is hundreds of milliseconds of photokit time
    /// the grid's own thumbnail requests then queue behind.
    private struct ScanMemo: @unchecked Sendable {
        let token: PHPersistentChangeToken
        let assets: [DeviceAsset]
    }

    private static let scanMemo = OSAllocatedUnfairLock<ScanMemo?>(initialState: nil)

    @concurrent
    static func scan() async -> [DeviceAsset] {
        let token = PHPhotoLibrary.shared().currentChangeToken
        if let memo = scanMemo.withLock({ $0 }), memo.token == token {
            return memo.assets
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        // the enumeration is serial and synchronous without the concurrent
        // option; the block's sendable signature just cannot say so.
        nonisolated(unsafe) var assets: [DeviceAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video else { return }
            assets.append(snapshot(of: asset))
        }
        scanMemo.withLock { $0 = ScanMemo(token: token, assets: assets) }
        return assets
    }

    @concurrent
    static func assetInfo(localIdentifier: String) async -> DeviceAsset? {
        fetchPHAsset(localIdentifier).map(snapshot)
    }

    @concurrent
    static func assetExists(localIdentifier: String) async -> Bool {
        fetchPHAsset(localIdentifier) != nil
    }

    private static func snapshot(of asset: PHAsset) -> DeviceAsset {
        DeviceAsset(
            localIdentifier: asset.localIdentifier,
            isVideo: asset.mediaType == .video,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            isFavorite: asset.isFavorite,
            durationMs: Int(asset.duration * 1000),
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight
        )
    }

    private static func fetchPHAsset(_ localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    // MARK: - local info

    /// camera fields read from the image file's own metadata.
    private struct CameraMetadata: Sendable {
        var make: String?
        var model: String?
        var lens: String?
        var fNumber: Double?
        var focalLength: Double?
        var iso: Double?
        var exposureTime: String?
    }

    /// synthesized detail for a device-only asset, so the info sheet renders
    /// local photos through the same layout it uses for server ones. server
    /// notions like people, caption or rating stay nil by construction.
    @concurrent
    static func localDetail(localIdentifier: String) async -> AssetDetail? {
        guard let asset = fetchPHAsset(localIdentifier) else { return nil }
        let resource = primaryResource(for: asset)
        let camera = await cameraMetadata(of: asset)
        let created = asset.creationDate ?? asset.modificationDate ?? .distantPast
        let isVideo = asset.mediaType == .video

        let exif = ExifInfo(
            make: camera?.make,
            model: camera?.model,
            exifImageWidth: asset.pixelWidth > 0 ? Double(asset.pixelWidth) : nil,
            exifImageHeight: asset.pixelHeight > 0 ? Double(asset.pixelHeight) : nil,
            fileSizeInByte: resource?.value(forKey: "fileSize") as? Int64,
            lensModel: camera?.lens,
            fNumber: camera?.fNumber,
            focalLength: camera?.focalLength,
            iso: camera?.iso,
            exposureTime: camera?.exposureTime,
            latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude,
            city: nil,
            state: nil,
            country: nil,
            dateTimeOriginal: nil,
            timeZone: nil,
            description: nil,
            rating: nil
        )
        return AssetDetail(
            id: "local-\(localIdentifier)",
            ownerId: "",
            type: isVideo ? .video : .image,
            originalFileName: resource?.originalFilename ?? String(localized: "Unknown"),
            originalMimeType: resource.flatMap { UTType($0.uniformTypeIdentifier)?.preferredMIMEType },
            thumbhash: nil,
            fileCreatedAt: created.ISO8601Format(),
            localDateTime: created.ISO8601Format(),
            createdAt: nil,
            isFavorite: asset.isFavorite,
            isArchived: nil,
            isTrashed: false,
            visibility: nil,
            width: asset.pixelWidth > 0 ? asset.pixelWidth : nil,
            height: asset.pixelHeight > 0 ? asset.pixelHeight : nil,
            duration: isVideo ? Int(asset.duration * 1000) : nil,
            exifInfo: exif,
            livePhotoVideoId: nil,
            people: nil,
            tags: nil,
            checksum: nil,
            isEdited: nil
        )
    }

    /// exif straight from the picture on device. icloud-offloaded originals
    /// are never downloaded for an info panel - the fields just stay empty.
    private static func cameraMetadata(of asset: PHAsset) async -> CameraMetadata? {
        guard asset.mediaType == .image else { return nil }
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, _ in
                guard let url = input?.fullSizeImageURL,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                else { return continuation.resume(returning: nil) }

                let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
                let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
                var metadata = CameraMetadata()
                metadata.make = tiff?[kCGImagePropertyTIFFMake] as? String
                metadata.model = tiff?[kCGImagePropertyTIFFModel] as? String
                metadata.lens = exif?[kCGImagePropertyExifLensModel] as? String
                metadata.fNumber = exif?[kCGImagePropertyExifFNumber] as? Double
                metadata.focalLength = exif?[kCGImagePropertyExifFocalLength] as? Double
                metadata.iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Double])?.first
                if let seconds = exif?[kCGImagePropertyExifExposureTime] as? Double, seconds > 0 {
                    metadata.exposureTime = seconds < 1
                        ? "1/\(Int((1 / seconds).rounded()))"
                        : "\(seconds.formatted(.number.precision(.fractionLength(0...1)))) s"
                }
                continuation.resume(returning: metadata)
            }
        }
    }

    // MARK: - resource selection

    /// prefers the edited render when one exists, matching what immich's own
    /// ios code hashes and uploads.
    private static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        let all = PHAssetResource.assetResources(for: asset)
        if asset.mediaType == .video {
            return all.first { $0.type == .fullSizeVideo } ?? all.first { $0.type == .video }
        }
        return all.first { $0.type == .fullSizePhoto } ?? all.first { $0.type == .photo }
    }

    private static func motionResource(for asset: PHAsset) -> PHAssetResource? {
        let all = PHAssetResource.assetResources(for: asset)
        return all.first { $0.type == .fullSizePairedVideo } ?? all.first { $0.type == .pairedVideo }
    }

    // MARK: - hashing

    /// base64 sha-1 of the current resource bytes, matching the server's
    /// checksum representation. streams via requestData, downloading from
    /// icloud when needed.
    @concurrent
    static func hash(
        localIdentifier: String,
        includeMotion: Bool,
        onICloudDownload: (@Sendable () -> Void)? = nil,
        onResourceProgress: (@Sendable (BackupResourceProgress) -> Void)? = nil
    ) async throws -> LocalResourceHashes {
        guard let asset = fetchPHAsset(localIdentifier) else { throw PhotoLibraryError.assetMissing }
        guard let primary = primaryResource(for: asset) else { throw PhotoLibraryError.resourceMissing }
        let primaryHash = try await sha1Base64(of: primary, onICloudDownload: onICloudDownload, onResourceProgress: onResourceProgress)
        var motionHash: ResourceDigest?
        if includeMotion {
            guard let motion = motionResource(for: asset) else { throw PhotoLibraryError.resourceMissing }
            motionHash = try await sha1Base64(of: motion, onICloudDownload: onICloudDownload, onResourceProgress: onResourceProgress)
        }
        return LocalResourceHashes(primaryDigest: primaryHash, motionDigest: motionHash)
    }

    private static func sha1Base64(
        of resource: PHAssetResource,
        onICloudDownload: (@Sendable () -> Void)?,
        onResourceProgress: (@Sendable (BackupResourceProgress) -> Void)?
    ) async throws -> ResourceDigest {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let box = DataRequestBox()
        let progress = PhotoResourceProgressEmitter(filename: resource.originalFilename,
            expectedBytes: resource.value(forKey: "fileSize") as? Int64, observer: onResourceProgress)
        progress.started()
        options.progressHandler = { fraction in
            box.reportICloudDownload(onICloudDownload)
            progress.downloading(fraction)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let requestID = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                    if let bytes = box.append(data) { progress.read(bytes) }
                } completionHandler: { error in
                    // photokit calls this exactly once, including after a cancel.
                    if let error {
                        continuation.resume(throwing: mapCancellation(error))
                    } else {
                        continuation.resume(returning: box.digest())
                    }
                }
                box.register(requestID)
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// base64 sha-1 of a plain file, streamed. used to verify downloads
    /// against the server checksum before importing them.
    @concurrent
    static func sha1Base64(ofFile url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        // drained per chunk - the autoreleased nsdata otherwise pile up to
        // the size of the file being hashed.
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            try Task.checkCancellation()
            return true
        }) {}
        return Data(hasher.finalize()).base64EncodedString()
    }

    // MARK: - import

    /// saves downloaded originals as one new library asset and returns its
    /// local identifier. source files are moved into the library on success.
    @concurrent
    static func importAsset(
        primaryURL: URL,
        isVideo: Bool,
        filename: String,
        motionURL: URL?
    ) async throws -> String {
        let placeholder = OSAllocatedUnfairLock<String?>(initialState: nil)
        try await PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            options.shouldMoveFile = true
            // photokit rejects files whose type it cannot determine; declare it
            // from the original filename rather than trusting the temp name.
            let ext = URL(fileURLWithPath: filename).pathExtension
            if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                options.uniformTypeIdentifier = type.identifier
            }
            creation.addResource(with: isVideo ? .video : .photo, fileURL: primaryURL, options: options)
            if let motionURL {
                let motionOptions = PHAssetResourceCreationOptions()
                motionOptions.shouldMoveFile = true
                motionOptions.uniformTypeIdentifier = UTType.quickTimeMovie.identifier
                creation.addResource(with: .pairedVideo, fileURL: motionURL, options: motionOptions)
            }
            let localId = creation.placeholderForCreatedAsset?.localIdentifier
            placeholder.withLock { $0 = localId }
        }
        guard let localId = placeholder.withLock({ $0 }) else {
            throw PhotoLibraryError.exportFailed
        }
        return localId
    }

    // MARK: - export

    nonisolated struct ExportedResource: Sendable {
        let fileURL: URL
        let filename: String
    }

    /// what `exportPrimary` would hand out, for callers that must describe
    /// the file before exporting it.
    nonisolated struct PrimaryResourceInfo: Sendable {
        let contentType: UTType?
        let filename: String
        let hasLocation: Bool
    }

    @concurrent
    static func primaryResourceInfo(localIdentifier: String) async -> PrimaryResourceInfo? {
        guard let asset = fetchPHAsset(localIdentifier), let resource = primaryResource(for: asset) else {
            return nil
        }
        return PrimaryResourceInfo(
            contentType: UTType(resource.uniformTypeIdentifier),
            filename: resource.originalFilename,
            hasLocation: asset.location != nil
        )
    }

    /// with a `form`, the file written is the whole multipart request body,
    /// so an upload never needs a second copy of the original on disk.
    @concurrent
    static func exportPrimary(
        localIdentifier: String,
        to directory: URL,
        form: MultipartBody.Form? = nil,
        progress: (@Sendable (Double) -> Void)? = nil,
        onResourceProgress: (@Sendable (BackupResourceProgress) -> Void)? = nil
    ) async throws -> ExportedResource {
        guard let asset = fetchPHAsset(localIdentifier) else { throw PhotoLibraryError.assetMissing }
        guard let resource = primaryResource(for: asset) else { throw PhotoLibraryError.resourceMissing }
        return try await export(resource, to: directory, form: form, progress: progress, onResourceProgress: onResourceProgress)
    }

    @concurrent
    static func exportMotion(
        localIdentifier: String,
        to directory: URL,
        form: MultipartBody.Form? = nil,
        onResourceProgress: (@Sendable (BackupResourceProgress) -> Void)? = nil
    ) async throws -> ExportedResource {
        guard let asset = fetchPHAsset(localIdentifier) else { throw PhotoLibraryError.assetMissing }
        guard let resource = motionResource(for: asset) else { throw PhotoLibraryError.resourceMissing }
        return try await export(resource, to: directory, form: form, progress: nil, onResourceProgress: onResourceProgress)
    }

    /// streams the resource into a temp file through the same cancellable
    /// requestData path used for hashing - writeData offers no cancellation.
    private static func export(
        _ resource: PHAssetResource,
        to directory: URL,
        form: MultipartBody.Form?,
        progress: (@Sendable (Double) -> Void)?,
        onResourceProgress: (@Sendable (BackupResourceProgress) -> Void)?
    ) async throws -> ExportedResource {
        // created first: capacity cannot be read for a missing directory.
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        let resourceBytes = resource.value(forKey: "fileSize") as? Int64 ?? 0
        let resourceProgress = PhotoResourceProgressEmitter(filename: resource.originalFilename,
            expectedBytes: resourceBytes, observer: onResourceProgress)
        resourceProgress.started()
        guard availableCapacity(at: directory) > resourceBytes + storageFloor else {
            throw PhotoLibraryError.insufficientStorage
        }
        let fileURL = directory.appending(path: "export-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { fraction in
            progress?(fraction)
            resourceProgress.downloading(fraction)
        }
        let box = DataRequestBox(fileHandle: handle)
        do {
            if let form {
                try handle.write(contentsOf: form.head(filename: resource.originalFilename))
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let requestID = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                        if let bytes = box.append(data) { resourceProgress.read(bytes) }
                    } completionHandler: { error in
                        if let error {
                            continuation.resume(throwing: mapCancellation(error))
                        } else if let writeError = box.writeError {
                            continuation.resume(throwing: writeError)
                        } else {
                            continuation.resume()
                        }
                    }
                    box.register(requestID)
                }
            } onCancel: {
                box.cancel()
            }
            if let form {
                try handle.write(contentsOf: form.tail)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: fileURL)
            throw isOutOfSpace(error) ? PhotoLibraryError.insufficientStorage : error
        }
        try ProtectedTemporaryFiles.protect(fileURL)
        return ExportedResource(fileURL: fileURL, filename: resource.originalFilename)
    }

    // MARK: - chunked export

    nonisolated struct ResourceSize: Sendable {
        let filename: String
        let bytes: Int64
    }

    /// nil when photokit does not say how large the resource is.
    @concurrent
    static func resourceSize(localIdentifier: String, motion: Bool) async -> ResourceSize? {
        guard let asset = fetchPHAsset(localIdentifier),
              let resource = motion ? motionResource(for: asset) : primaryResource(for: asset),
              let bytes = resource.value(forKey: "fileSize") as? Int64, bytes > 0
        else { return nil }
        return ResourceSize(filename: resource.originalFilename, bytes: bytes)
    }

    nonisolated struct ResourceChunk: Sendable {
        let fileURL: URL
        let offset: Int64
        let length: Int64
    }

    /// streams a resource into chunk files and awaits `consume` on each, in
    /// order. photokit cannot start a read at an offset, so the bytes before
    /// `start` are read and dropped. one chunk is consumed while the next
    /// fills, so disk use stays near two chunks whatever the file size.
    @concurrent
    static func streamChunks(
        localIdentifier: String,
        motion: Bool,
        from start: Int64,
        chunkBytes: Int64,
        expectedBytes: Int64,
        to directory: URL,
        onResourceProgress: (@Sendable (BackupResourceProgress) -> Void)? = nil,
        consume: @escaping @Sendable (ResourceChunk) async throws -> Void
    ) async throws {
        guard let asset = fetchPHAsset(localIdentifier) else { throw PhotoLibraryError.assetMissing }
        guard let resource = motion ? motionResource(for: asset) : primaryResource(for: asset) else {
            throw PhotoLibraryError.resourceMissing
        }
        let resourceProgress = PhotoResourceProgressEmitter(filename: resource.originalFilename,
            expectedBytes: expectedBytes, observer: onResourceProgress)
        resourceProgress.started()
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        guard availableCapacity(at: directory) > 2 * chunkBytes + storageFloor else {
            throw PhotoLibraryError.insufficientStorage
        }
        let (chunks, output) = AsyncThrowingStream<ResourceChunk, Error>.makeStream()
        let writer = ChunkWriter(
            start: start,
            chunkBytes: chunkBytes,
            expectedBytes: expectedBytes,
            directory: directory,
            output: output
        )
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { fraction in resourceProgress.downloading(fraction) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    for try await chunk in chunks {
                        // the uploader deletes a chunk it took. this covers one it never got.
                        defer { try? FileManager.default.removeItem(at: chunk.fileURL) }
                        try await consume(chunk)
                        writer.consumed()
                    }
                } catch {
                    writer.cancel()
                    throw error
                }
            }
            let produced: Result<Void, Error>
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        let requestID = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                            writer.append(data)
                            resourceProgress.read(writer.streamedByteCount)
                        } completionHandler: { error in
                            if let error {
                                let error = mapCancellation(error)
                                writer.fail(error)
                                continuation.resume(throwing: error)
                            } else {
                                writer.finish()
                                continuation.resume()
                            }
                        }
                        writer.register(requestID)
                    }
                } onCancel: {
                    writer.cancel()
                }
                produced = .success(())
            } catch {
                produced = .failure(error)
            }
            // a failed upload is why photokit stopped, so its error goes first.
            try await group.waitForAll()
            try produced.get()
        }
    }

    fileprivate static func isOutOfSpace(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC))
    }

    static func availableCapacity(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    // MARK: - deletion

    /// one performchanges call per invocation, so the system shows exactly one
    /// confirmation dialog per batch. user refusal surfaces as userCancelled.
    static func delete(localIdentifiers: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        guard assets.count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    /// Fetches and checks the exact approved set again inside Photos' commit
    /// closure. A zero/partial fetch is a changed report, never a success count.
    static func deleteVerified(_ expected: [DeviceAsset], permitted: @escaping @Sendable () -> Bool) async throws -> [String] {
        guard hasFullAccess else { throw CleanupVerificationError.permission }
        guard !expected.isEmpty, Set(expected.map(\.localIdentifier)).count == expected.count else { throw CleanupVerificationError.changed }
        let expectedByID = Dictionary(uniqueKeysWithValues: expected.map { ($0.localIdentifier, $0) })
        let deleted = OSAllocatedUnfairLock(initialState: [String]())
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await PHPhotoLibrary.shared().performChanges {
                guard !cancelled.withLock({ $0 }), permitted(), hasFullAccess else { return }
                let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(expectedByID.keys), options: nil)
                guard fetched.count == expected.count else { return }
                var ids: [String] = []
                for index in 0..<fetched.count {
                    let asset = fetched.object(at: index)
                    guard expectedByID[asset.localIdentifier] == snapshot(of: asset) else { return }
                    ids.append(asset.localIdentifier)
                }
                guard !cancelled.withLock({ $0 }), permitted() else { return }
                let confirmedIDs = ids
                PHAssetChangeRequest.deleteAssets(fetched)
                deleted.withLock { $0 = confirmedIDs }
            }
            let actual = deleted.withLock { $0 }
            guard actual.count == expected.count else { throw CleanupVerificationError.changed }
            return actual
        } onCancel: { cancelled.withLock { $0 = true } }
    }

    static func isUserCancelled(_ error: Error) -> Bool {
        (error as? PHPhotosError)?.code == .userCancelled || error is CancellationError
    }

    private static func mapCancellation(_ error: Error) -> Error {
        isUserCancelled(error) ? CancellationError() : error
    }
}

/// lock-guarded accumulator shared between photokit's data callback, the
/// completion handler and the task cancellation handler. no assumptions about
/// which queue photokit uses.
private nonisolated struct PhotoResourceProgressEmitter: Sendable {
    private let resourceID = UUID()
    let filename: String
    let expectedBytes: Int64?
    let observer: (@Sendable (BackupResourceProgress) -> Void)?

    init(filename: String, expectedBytes: Int64?, observer: (@Sendable (BackupResourceProgress) -> Void)?) {
        self.filename = filename; self.expectedBytes = expectedBytes; self.observer = observer
    }

    func started() { observer?(.init(resourceID: resourceID, filename: filename, stage: .preparing, fraction: nil)) }
    func downloading(_ fraction: Double) {
        observer?(.init(resourceID: resourceID, filename: filename, stage: .downloadingOriginal, fraction: fraction))
    }
    func read(_ bytes: Int64) {
        guard let expectedBytes, expectedBytes > 0, bytes > 0 else { return }
        observer?(.init(resourceID: resourceID, filename: filename, stage: .preparing,
            fraction: Double(bytes) / Double(expectedBytes)))
    }
}

private nonisolated final class DataRequestBox: @unchecked Sendable {
    private struct State {
        var hasher = Insecure.SHA1()
        var byteCount: Int64 = 0
        var requestID: PHAssetResourceDataRequestID?
        var cancelled = false
        var writeError: NSError?
        var reportedICloudDownload = false
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let fileHandle: FileHandle?

    init(fileHandle: FileHandle? = nil) {
        self.fileHandle = fileHandle
        self.lock = OSAllocatedUnfairLock(initialState: State())
    }

    @discardableResult
    func append(_ data: Data) -> Int64? {
        lock.withLock { state in
            if let fileHandle {
                guard state.writeError == nil else { return nil }
                do {
                    try fileHandle.write(contentsOf: data)
                } catch {
                    if state.writeError == nil {
                        state.writeError = error as NSError
                    }
                    return nil
                }
            } else {
                state.hasher.update(data: data)
            }
            state.byteCount += Int64(data.count)
            return state.byteCount
        }
    }

    /// PhotoKit calls the resource progress handler only when it has to fetch
    /// bytes from iCloud. report once per resource rather than waking the main
    /// actor for every download tick.
    func reportICloudDownload(_ handler: (@Sendable () -> Void)?) {
        guard let handler else { return }
        let shouldReport = lock.withLock { state in
            guard !state.reportedICloudDownload else { return false }
            state.reportedICloudDownload = true
            return true
        }
        if shouldReport { handler() }
    }

    func digest() -> ResourceDigest {
        lock.withLock { state in
            ResourceDigest(checksum: Data(state.hasher.finalize()).base64EncodedString(), byteCount: state.byteCount)
        }
    }

    var writeError: NSError? {
        lock.withLock { $0.writeError }
    }

    /// handles the race where cancellation lands before the request id exists.
    func register(_ requestID: PHAssetResourceDataRequestID) {
        let cancelNow = lock.withLock { state in
            state.requestID = requestID
            return state.cancelled
        }
        if cancelNow {
            PHAssetResourceManager.default().cancelDataRequest(requestID)
        }
    }

    func cancel() {
        let requestID = lock.withLock { state -> PHAssetResourceDataRequestID? in
            state.cancelled = true
            return state.requestID
        }
        if let requestID {
            PHAssetResourceManager.default().cancelDataRequest(requestID)
        }
    }
}

/// cuts photokit's stream into chunk files. photokit calls `append` and then
/// the completion in order, so the file state is only touched from there and
/// the lock covers what `cancel` shares with them. sealing a chunk blocks
/// photokit's queue until the previous one is consumed, which is the only
/// brake requestData offers.
private nonisolated final class ChunkWriter: @unchecked Sendable {
    private struct Shared {
        var requestID: PHAssetResourceDataRequestID?
        var stopped = false
    }

    private let start: Int64
    private let chunkBytes: Int64
    private let expectedBytes: Int64
    private let directory: URL
    private let output: AsyncThrowingStream<PhotoLibraryService.ResourceChunk, Error>.Continuation
    // libdispatch traps when a semaphore is freed below its initial value,
    // which a halted stream leaves it at. starting at zero cannot trap.
    private let slot = DispatchSemaphore(value: 0)
    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    private var position: Int64 = 0
    private var handle: FileHandle?
    private var fileURL: URL?
    private var chunkOffset: Int64 = 0
    private var chunkLength: Int64 = 0
    private var hasYielded = false
    /// Read only from requestData's serial data callback, after append.
    var streamedByteCount: Int64 { position }

    init(
        start: Int64,
        chunkBytes: Int64,
        expectedBytes: Int64,
        directory: URL,
        output: AsyncThrowingStream<PhotoLibraryService.ResourceChunk, Error>.Continuation
    ) {
        self.start = start
        self.chunkBytes = chunkBytes
        self.expectedBytes = expectedBytes
        self.directory = directory
        self.output = output
    }

    private var isStopped: Bool { shared.withLock { $0.stopped } }

    func register(_ requestID: PHAssetResourceDataRequestID) {
        let cancelNow = shared.withLock { state in
            state.requestID = requestID
            return state.stopped
        }
        if cancelNow { PHAssetResourceManager.default().cancelDataRequest(requestID) }
    }

    func append(_ data: Data) {
        guard !isStopped else { return discardOpenChunk() }
        var bytes = data[...]
        if position < start {
            let skipped = min(Int64(bytes.count), start - position)
            position += skipped
            bytes = bytes.dropFirst(Int(skipped))
        }
        guard !bytes.isEmpty else { return }
        guard position + Int64(bytes.count) <= expectedBytes else {
            return fail(PhotoLibraryError.unexpectedSize)
        }
        do {
            while !bytes.isEmpty, !isStopped {
                if handle == nil { try open() }
                let piece = bytes.prefix(Int(chunkBytes - chunkLength))
                try handle?.write(contentsOf: piece)
                chunkLength += Int64(piece.count)
                position += Int64(piece.count)
                bytes = bytes.dropFirst(piece.count)
                if chunkLength == chunkBytes { try seal() }
            }
            if isStopped { discardOpenChunk() }
        } catch {
            fail(PhotoLibraryService.isOutOfSpace(error) ? PhotoLibraryError.insufficientStorage : error)
        }
    }

    func finish() {
        guard !isStopped else { return discardOpenChunk() }
        guard position == expectedBytes else { return fail(PhotoLibraryError.unexpectedSize) }
        do {
            if handle != nil { try seal() }
            output.finish()
        } catch {
            fail(error)
        }
    }

    /// the consumer is done with a chunk, so the next one may be handed over.
    func consumed() {
        slot.signal()
    }

    /// from photokit's callbacks only.
    func fail(_ error: Error) {
        halt()
        discardOpenChunk()
        output.finish(throwing: error)
    }

    /// from any thread. photokit still calls the completion, which cleans up.
    func cancel() {
        halt()
        output.finish(throwing: CancellationError())
    }

    private func halt() {
        let requestID = shared.withLock { state -> PHAssetResourceDataRequestID? in
            state.stopped = true
            return state.requestID
        }
        if let requestID { PHAssetResourceManager.default().cancelDataRequest(requestID) }
        // wakes a seal waiting on a consumer that is gone.
        slot.signal()
    }

    private func discardOpenChunk() {
        try? handle?.close()
        handle = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
    }

    private func open() throws {
        let url = directory.appending(path: "chunk-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        fileURL = url
        chunkOffset = position
        chunkLength = 0
    }

    private func seal() throws {
        guard let handle, let fileURL else { return }
        try handle.close()
        self.handle = nil
        self.fileURL = nil
        let chunk = PhotoLibraryService.ResourceChunk(fileURL: fileURL, offset: chunkOffset, length: chunkLength)
        chunkLength = 0
        if hasYielded { slot.wait() }
        hasYielded = true
        guard !isStopped else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        output.yield(chunk)
    }
}
