import Foundation

/// limits the multipart request body sent to the server or an upload proxy.
/// one megabyte means 1,000,000 bytes, matching the setting's MB label.
nonisolated enum UploadSizeLimit: LocalizedError {
    case exceeded(actualBytes: Int64, maximumBytes: Int64)

    static func bytes(forMegabytes megabytes: Int?) -> Int64? {
        guard let megabytes, megabytes > 0, megabytes <= 100_000 else { return nil }
        return Int64(megabytes) * 1_000_000
    }

    static func check(_ file: URL, maximumBytes: Int64?) throws {
        guard let maximumBytes else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let actual = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        let actualBytes = actual.int64Value
        if actualBytes > maximumBytes {
            throw exceeded(actualBytes: actualBytes, maximumBytes: maximumBytes)
        }
    }

    var errorDescription: String? {
        switch self {
        case .exceeded(let actualBytes, let maximumBytes):
            let actualMB = (actualBytes + 999_999) / 1_000_000
            let maximumMB = maximumBytes / 1_000_000
            return String(localized: "Upload request is about \(actualMB) MB, above the \(maximumMB) MB limit in Backup Settings. Increase the limit or use a server route that accepts larger uploads.")
        }
    }
}
