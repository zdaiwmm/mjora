import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct PhotoEditOriginalFingerprint: Equatable, Sendable {
    enum Role: String, Sendable { case photoKitOriginal, serverOriginal, preview, editedResult, offlinePlayback }
    let role: Role
    let sha256: String
    let sha1: String
    let byteCount: Int64
    /// Upright dimensions and the interpretation of the original bytes.
    let width: Int
    let height: Int
    let orientation: Int32

    func matches(_ other: Self) -> Bool {
        isValid && other.isValid && sha256 == other.sha256 && byteCount == other.byteCount
            && width == other.width && height == other.height && orientation == other.orientation
    }

    private var isValid: Bool {
        byteCount > 0 && width > 0 && height > 0 && (1...8).contains(orientation)
            && Data(base64Encoded: sha256)?.count == 32 && Data(base64Encoded: sha1)?.count == 20
    }

    @concurrent
    static func read(fileURL: URL, role: Role, orientation override: Int32? = nil) async throws -> Self {
        guard role == .photoKitOriginal || role == .serverOriginal else { throw PhotoEditTargetIssue.nonOriginalInput }
        let file = try FileHandle(forReadingFrom: fileURL)
        defer { try? file.close() }
        var sha256 = SHA256(), sha1 = Insecure.SHA1(), count: Int64 = 0
        while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            sha256.update(data: chunk); sha1.update(data: chunk); count += Int64(chunk.count)
        }
        guard count > 0, let image = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              CGImageSourceGetCount(image) == 1, let identifier = CGImageSourceGetType(image),
              UTType(identifier as String)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int, rawWidth > 0, rawHeight > 0 else {
            throw PhotoEditTargetIssue.invalidOriginal
        }
        let orientation = override ?? (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        guard (1...8).contains(orientation) else { throw PhotoEditTargetIssue.invalidOriginal }
        let swaps = (5...8).contains(orientation)
        return .init(role: role, sha256: Data(sha256.finalize()).base64EncodedString(),
                     sha1: Data(sha1.finalize()).base64EncodedString(), byteCount: count,
                     width: swaps ? rawHeight : rawWidth, height: swaps ? rawWidth : rawHeight, orientation: orientation)
    }
}
