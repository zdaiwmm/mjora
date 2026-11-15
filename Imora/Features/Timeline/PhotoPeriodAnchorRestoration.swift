import Foundation

/// A month-level scroll only materializes the lazy section. Keep its photo
/// request alive until the actual day reports layout, and reject callbacks
/// from an earlier navigation or from after the user has started scrolling.
nonisolated struct PhotoPeriodAnchorRestoration {
    struct Request: Equatable {
        let ticket = UUID()
        let assetID: String
        let periodID: String?
    }

    private(set) var request: Request?

    @discardableResult
    mutating func begin(assetID: String, periodID: String?) -> Request {
        let request = Request(assetID: assetID, periodID: periodID)
        self.request = request
        return request
    }

    mutating func consumeReachableDay(ticket: UUID, assetID: String, periodID: String) -> Bool {
        guard let request, request.ticket == ticket,
              request.assetID == assetID, request.periodID == periodID else { return false }
        self.request = nil
        return true
    }

    mutating func cancel() { request = nil }
}
