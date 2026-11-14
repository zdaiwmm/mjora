import Foundation

nonisolated struct ResourceDigest: Codable, Equatable, Sendable {
    let checksum: String
    let byteCount: Int64
}

nonisolated struct LocalResourceHashes: Sendable {
    let primaryDigest: ResourceDigest
    let motionDigest: ResourceDigest?
    var primary: String { primaryDigest.checksum }
    var motion: String? { motionDigest?.checksum }
    var primaryBytes: Int64 { primaryDigest.byteCount }
    var motionBytes: Int64? { motionDigest?.byteCount }
}
