import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Turns shared media into uploads. When the system grants continued
/// processing, the extension that submitted the request also owns the session
/// and reports its bytes. If the request is declined, the original daemon-owned
/// background-session path remains the fallback.
nonisolated enum ShareUploader {
    struct Prepared: Sendable {
        enum Transfer: Sendable {
            case multipart(boundary: String)
            /// imora's resumable upload, the shared file itself as one chunk.
            case raw(uploadId: String)
        }

        let bodyURL: URL
        let filename: String
        let checksum: String
        let transfer: Transfer
        var verifiedProduct: String? = nil
        var mediaType = "IMAGE"
    }

    enum Preparation: Sendable {
        case upload(Prepared)
        /// the server already has the file.
        case done
        case failed
    }

    private static func sendControl(_ request: URLRequest, credentials: ShareTransfer.Credentials) async throws -> (Data, HTTPURLResponse) {
        let uploader = ControlledFileUploader(apiURL: credentials.apiURL, token: credentials.token)
        defer { uploader.invalidate() }
        return try await uploader.data(request, startAuthorized: { resume in try ShareTransfer.withCurrent(credentials) { try resume() } })
    }

    // MARK: - staging

    /// imora takes the raw file, so the shared copy is uploaded as it is.
    /// immich and gallery only take multipart, which needs a body built
    /// around it.
    struct Capabilities: Sendable {
        var rawUploads = false
        var verifiedProduct: String? = nil
    }

    static func uploadCapabilities(_ credentials: ShareTransfer.Credentials) async -> Capabilities {
        struct Report: Decodable {
            let product: String?
            let features: [String]?
        }
        var request = URLRequest(url: credentials.apiURL.appending(path: "server/version"))
        request.timeoutInterval = 10
        guard ShareTransfer.credentials()?.identity == credentials.identity,
              let (data, response) = try? await sendControl(request, credentials: credentials),
              response.statusCode == 200,
              let report = try? JSONDecoder().decode(Report.self, from: data)
        else { return Capabilities() }
        return Capabilities(rawUploads: report.product == "imora" && report.features?.contains("chunkedUploads") == true, verifiedProduct: report.product)
    }

    /// stages one provider in the app group. the url the load callback hands
    /// over is only valid inside it, so the file is moved or the body built
    /// right there.
    static func prepare(
        _ provider: NSItemProvider,
        credentials: ShareTransfer.Credentials,
        capabilities: Capabilities
    ) async -> Preparation {
        guard !Task.isCancelled, ShareTransfer.credentials()?.identity == credentials.identity else { return .failed }
        let isVideo = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
        let type: UTType = isVideo ? .movie : .image
        if !capabilities.rawUploads {
            let prepared: Prepared? = await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                    guard let url, let directory = ShareTransfer.bodyDirectory else {
                        return continuation.resume(returning: nil)
                    }
                    continuation.resume(returning: buildBody(
                        from: url, filename: url.lastPathComponent, deviceId: credentials.deviceId, in: directory
                    ))
                }
            }
            return prepared.map { value in
                var item = value
                item.verifiedProduct = capabilities.verifiedProduct
                item.mediaType = isVideo ? "VIDEO" : "IMAGE"
                guard !Task.isCancelled, ShareTransfer.credentials()?.identity == credentials.identity else {
                    try? FileManager.default.removeItem(at: item.bodyURL); return .failed
                }
                return .upload(item)
            } ?? .failed
        }
        let staged: Staged? = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                guard let url, let directory = ShareTransfer.bodyDirectory else {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: stage(url, in: directory))
            }
        }
        guard let staged else { return .failed }
        let preparation = await openSession(for: staged, credentials: credentials, mediaType: isVideo ? "VIDEO" : "IMAGE")
        if case .upload(var item) = preparation {
            item.mediaType = isVideo ? "VIDEO" : "IMAGE"
            guard !Task.isCancelled, ShareTransfer.credentials()?.identity == credentials.identity else {
                try? FileManager.default.removeItem(at: item.bodyURL); return .failed
            }
            return .upload(item)
        }
        try? FileManager.default.removeItem(at: staged.url)
        return preparation
    }

    private struct Staged: Sendable {
        let url: URL
        let filename: String
        let created: Date
    }

    /// a move, or an apfs clone when the system's file cannot be moved,
    /// so the staged file takes no space of its own.
    private static func stage(_ url: URL, in directory: URL) -> Staged? {
        let staged = directory.appending(path: "body-\(UUID().uuidString)")
        let created = creationDate(of: url)
        do {
            try ProtectedTemporaryFiles.prepareDirectory(directory)
            do {
                try FileManager.default.moveItem(at: url, to: staged)
            } catch {
                try FileManager.default.copyItem(at: url, to: staged)
            }
        } catch {
            return nil
        }
        guard (try? ProtectedTemporaryFiles.protect(staged)) != nil else { try? FileManager.default.removeItem(at: staged); return nil }
        return Staged(url: staged, filename: url.lastPathComponent, created: created)
    }

    private static func openSession(for staged: Staged, credentials: ShareTransfer.Credentials, mediaType: String) async -> Preparation {
        guard let checksum = try? sha1Base64(ofFile: staged.url),
              let size = (try? FileManager.default.attributesOfItem(atPath: staged.url.path))?[.size] as? NSNumber
        else { return .failed }
        var body = Dictionary(uniqueKeysWithValues: fields(
            id: UUID().uuidString, created: staged.created, deviceId: credentials.deviceId
        ).map { ($0.name, $0.value as Any) })
        body["filename"] = staged.filename
        body["size"] = size.int64Value
        body["checksum"] = checksum

        // a session left by an earlier share of this file resumes past the
        // start. the file goes up whole, so that session is dropped first.
        for _ in 0..<2 {
            switch await startSession(body, credentials: credentials) {
            case nil:
                return .failed
            case .duplicate(let id):
                do {
                    try await ShareQueueRunner.verifyExisting(assetID: id, checksum: checksum, mediaType: mediaType,
                        credentials: credentials, startAuthorized: { resume in try ShareTransfer.withCurrent(credentials) { try resume() } })
                    return .done
                } catch { return .failed }
            case .open(let id, 0):
                return .upload(Prepared(
                    bodyURL: staged.url, filename: staged.filename, checksum: checksum, transfer: .raw(uploadId: id)
                ))
            case .open(let id, _):
                await cancelSession(id, credentials: credentials)
            }
        }
        return .failed
    }

    private enum SessionStart {
        case open(id: String, offset: Int64)
        case duplicate(String)
    }

    private static func startSession(_ body: [String: Any], credentials: ShareTransfer.Credentials) async -> SessionStart? {
        var request = URLRequest(url: credentials.apiURL.appending(path: "assets/uploads"))
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard ShareTransfer.credentials()?.identity == credentials.identity,
              let (data, response) = try? await sendControl(request, credentials: credentials),
              (200..<300).contains(response.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let id = object["uploadId"] as? String, let offset = object["offset"] as? NSNumber {
            return .open(id: id, offset: offset.int64Value)
        }
        return (object["id"] as? String).map { .duplicate($0) }
    }

    private static func cancelSession(_ id: String, credentials: ShareTransfer.Credentials) async {
        var request = URLRequest(url: credentials.apiURL.appending(path: "assets/uploads/\(id)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        guard ShareTransfer.credentials()?.identity == credentials.identity else { return }
        _ = try? await sendControl(request, credentials: credentials)
    }

    private static func creationDate(of url: URL) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.creationDate] as? Date
            ?? attributes?[.modificationDate] as? Date
            ?? Date()
    }

    private static func fields(id: String, created: Date, deviceId: String) -> [(name: String, value: String)] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            ("deviceAssetId", "share-\(id)"),
            ("deviceId", deviceId),
            ("fileCreatedAt", iso.string(from: created)),
            ("fileModifiedAt", iso.string(from: created)),
            ("isFavorite", "false"),
            ("duration", "0"),
        ]
    }

    private static func buildBody(from url: URL, filename: String, deviceId: String, in directory: URL) -> Prepared? {
        guard let checksum = try? sha1Base64(ofFile: url) else { return nil }
        let id = UUID().uuidString
        let boundary = "imora-\(id)"
        guard let bodyURL = try? MultipartBody.makeBodyFile(
            fields: fields(id: id, created: creationDate(of: url), deviceId: deviceId),
            fileField: "assetData",
            filename: filename,
            contentsOf: url,
            boundary: boundary,
            in: directory
        ) else { return nil }
        return Prepared(
            bodyURL: bodyURL,
            filename: filename,
            checksum: checksum,
            transfer: .multipart(boundary: boundary)
        )
    }

    /// streaming sha1 of the staged file, the checksum the server dedups on.
    private static func sha1Base64(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        // each bridged chunk comes back autoreleased - drained per iteration,
        // or hashing accumulates the whole file and a large video kills the
        // extension at its memory cap before anything is enqueued.
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return Data(hasher.finalize()).base64EncodedString()
    }

    // MARK: - guarded transfer

    @concurrent
    static func handOff(_ items: [Prepared], credentials: ShareTransfer.Credentials) async -> ShareQueueResult {
        guard let store = ShareTransfer.queueStore, !Task.isCancelled,
              ShareTransfer.credentials()?.identity == credentials.identity else { return ShareQueueResult(failed: items.count) }
        var records: [ShareQueueRecord] = []
        var failures = 0
        for item in items {
            let transfer: ShareQueueRecord.Transfer
            switch item.transfer {
            case .multipart(let boundary): transfer = .multipart(boundary: boundary)
            case .raw(let uploadID): transfer = .raw(uploadId: uploadID)
            }
            let record = ShareQueueRecord(identity: credentials.identity, bodyPath: item.bodyURL.path, filename: item.filename,
                checksum: item.checksum, verifiedProduct: item.verifiedProduct, transfer: transfer, mediaType: item.mediaType)
            do { records.append(try store.enqueue(record)) }
            catch { failures += 1 }
        }
        var result = await ShareUploadActivity.shared.run(records, credentials: credentials)
        result.failed += failures
        return result
    }
}
