import Foundation

/// The official Immich wire contract is the fallback. Only a positive product
/// detection opts into Imora's custom header; unknown servers remain compatible.
nonisolated enum UploadChecksumHeader {
    static func apply(_ checksum: String, verifiedProduct: String?, to original: URLRequest) -> URLRequest {
        var request = original
        request.setValue(nil, forHTTPHeaderField: "x-immich-checksum")
        request.setValue(nil, forHTTPHeaderField: "x-imora-checksum")
        request.setValue(checksum, forHTTPHeaderField: verifiedProduct == "imora" ? "x-imora-checksum" : "x-immich-checksum")
        return request
    }
}
