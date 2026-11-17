import AVFoundation
import ObjectiveC
import UniformTypeIdentifiers

/// AVFoundation sees an opaque resource. Byte ranges still go through the
/// client's authenticated, pinned transport, without waiting for the full file.
@MainActor
final class ControlledMediaStream: NSObject, @preconcurrency AVAssetResourceLoaderDelegate {
    private nonisolated(unsafe) static var associationKey: UInt8 = 0
    private let client: ImoraClient
    private let url: URL
    private let access: MediaFileAccess
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private static let chunkSize: Int64 = 512 * 1024

    init(client: ImoraClient, url: URL, requiresElevation: Bool) throws {
        self.client = client
        self.url = url
        access = MediaFileAccess(context: client.context,
            privateLease: requiresElevation ? client.lockedMediaLease : nil, requiresElevation: requiresElevation)
        super.init()
        guard access.isCurrent else { throw ServerTrustError.sessionExpired }
        _ = try client.authorizedRequest(url: url)
    }

    isolated deinit { tasks.values.forEach { $0.cancel() } }

    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: URL(string: "imora-stream://media/\(UUID().uuidString).mp4")!)
        asset.resourceLoader.setDelegate(self, queue: .main)
        objc_setAssociatedObject(asset, &Self.associationKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }

    static func isAuthorized(_ asset: AVAsset) -> Bool {
        guard let stream = objc_getAssociatedObject(asset, &Self.associationKey) as? ControlledMediaStream else { return true }
        return stream.access.isCurrent
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let id = ObjectIdentifier(loadingRequest)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { tasks[id] = nil }
            do {
                try await serve(loadingRequest)
                guard !Task.isCancelled else { return }
                loadingRequest.finishLoading()
            } catch {
                guard !Task.isCancelled else { return }
                loadingRequest.finishLoading(with: error)
            }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    private func serve(_ loading: AVAssetResourceLoadingRequest) async throws {
        let dataRequest = loading.dataRequest
        var offset = dataRequest.map { max($0.requestedOffset, $0.currentOffset) } ?? 0
        let requestedEnd = dataRequest.map { $0.requestedOffset + Int64($0.requestedLength) } ?? 2
        var totalLength: Int64?
        repeat {
            try Task.checkCancellation()
            guard access.isCurrent else { throw ServerTrustError.sessionExpired }
            let end = min(offset + Self.chunkSize, dataRequest?.requestsAllDataToEndOfResource == true
                          ? (totalLength ?? offset + Self.chunkSize) : requestedEnd)
            guard end > offset else { break }
            let chunk = try await read(offset: offset, end: end)
            totalLength = chunk.totalLength
            if let info = loading.contentInformationRequest {
                info.contentType = chunk.contentType
                info.contentLength = chunk.totalLength
                info.isByteRangeAccessSupported = chunk.supportsRanges
            }
            guard let dataRequest else { return }
            let available = min(Int64(chunk.data.count), chunk.totalLength - offset)
            guard available > 0 else { throw ImoraError.decoding("Empty video byte range.") }
            dataRequest.respond(with: chunk.data.prefix(Int(available)))
            offset += available
        } while offset < (dataRequest?.requestsAllDataToEndOfResource == true ? totalLength ?? requestedEnd : min(requestedEnd, totalLength ?? requestedEnd))
    }

    struct Chunk {
        let data: Data
        let totalLength: Int64
        let contentType: String
        let supportsRanges: Bool
    }

    /// Kept separately so range/authentication behavior can be exercised with
    /// a real HTTP fixture independently of AVFoundation's read-ahead policy.
    func read(offset: Int64, end: Int64) async throws -> Chunk {
        try Task.checkCancellation()
        guard access.isCurrent else { throw ServerTrustError.sessionExpired }
        var request = try client.authorizedRequest(url: url)
        request.setValue("bytes=\(offset)-\(end - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await client.transportSession(for: request).data(for: request)
        try Task.checkCancellation()
        guard access.isCurrent else { throw ServerTrustError.sessionExpired }
        guard let http = response as? HTTPURLResponse else { throw ImoraError.unreachable }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            if let lease = access.privateLease, http.statusCode == 401 || http.statusCode == 403 {
                client.rejectLockedMediaLease(lease)
            }
            throw ImoraError.http(http.statusCode, "")
        }
        let mime = http.mimeType?.lowercased() ?? ""
        guard (mime.hasPrefix("video/") || mime == "application/octet-stream"),
              !mime.contains("mpegurl"), !data.starts(with: Data("#EXTM3U".utf8)) else {
            throw ImoraError.decoding("The server did not return a self-contained video file.")
        }
        let type = UTType(mimeType: mime)?.identifier ?? UTType.mpeg4Movie.identifier
        if http.statusCode == 200 {
            guard offset <= Int64(data.count) else { throw ImoraError.decoding("Invalid video byte range.") }
            return Chunk(data: Data(data[Int(offset)..<min(data.count, Int(end))]),
                         totalLength: Int64(data.count), contentType: type, supportsRanges: false)
        }
        let range = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: " ").last?.split(separator: "/")
        guard let range, range.count == 2, let total = Int64(range[1]), total > offset,
              let start = range[0].split(separator: "-").first.flatMap({ Int64($0) }), start == offset,
              !data.isEmpty, Int64(data.count) <= end - offset else {
            throw ImoraError.decoding("Invalid video byte range.")
        }
        return Chunk(data: data, totalLength: total, contentType: type, supportsRanges: true)
    }
}
