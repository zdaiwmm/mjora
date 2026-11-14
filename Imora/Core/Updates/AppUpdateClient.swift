import Foundation

nonisolated protocol AppUpdateServicing: Sendable {
    func status() async throws -> AppUpdateStatus
    func install(releaseID: String, requestID: UUID) async throws -> AppUpdateInstallation
}

/// Only the update host's two fixed endpoints exist in this transport. The
/// ephemeral session has its own token and exact private CA/root boundary.
nonisolated final class AppUpdateClient: AppUpdateServicing, Sendable {
    static let maximumResponseBytes = 65_536
    private let configuration: AppUpdateConfiguration
    private let session: URLSession

    init(configuration: AppUpdateConfiguration) {
        self.configuration = configuration
        let options = URLSessionConfiguration.ephemeral
        options.urlCredentialStorage = nil
        options.httpShouldSetCookies = false
        options.requestCachePolicy = .reloadIgnoringLocalCacheData
        options.timeoutIntervalForResource = 20
        options.waitsForConnectivity = false
        // No redirect policy is supplied: even a same-host redirect is refused.
        session = ControlledSession.make(identity: configuration.identity, configuration: options)
    }

    deinit { session.invalidateAndCancel() }

    func status() async throws -> AppUpdateStatus {
        let data = try await response(endpoint: "status", method: "GET", expectedStatus: 200)
        return try AppUpdateStatus.decode(data, expectedHostID: configuration.hostId)
    }

    func install(releaseID: String, requestID: UUID) async throws -> AppUpdateInstallation {
        guard AppUpdateRelease.validIdentifier(releaseID) else { throw AppUpdateError.invalidRelease }
        let body = try JSONEncoder().encode(AppUpdateInstallRequest(releaseId: releaseID, requestId: requestID))
        let data = try await response(endpoint: "install", method: "POST", body: body, expectedStatus: 202)
        let receipt = try JSONDecoder().decode(AppUpdateInstallation.self, from: data)
        guard receipt.isValid, receipt.state == .queued, receipt.releaseId == releaseID else { throw AppUpdateError.invalidResponse }
        return receipt
    }

    private func response(endpoint: String, method: String, body: Data? = nil, expectedStatus: Int) async throws -> Data {
        let url = configuration.apiURL.appending(path: endpoint)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = method
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request = try ServerTrustPolicy(apiURL: configuration.apiURL).authorize(request, token: configuration.accessToken)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, let responseURL = http.url,
              ServerTrustPolicy(apiURL: configuration.apiURL).contains(responseURL),
              responseURL.path == url.path, responseURL.query == nil,
              http.value(forHTTPHeaderField: "Content-Range") == nil,
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true,
              http.statusCode == expectedStatus else { throw AppUpdateError.unexpectedStatus }
        guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw AppUpdateError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maximumResponseBytes else { throw AppUpdateError.invalidResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }
}

private nonisolated struct AppUpdateInstallRequest: Encodable, Sendable {
    let releaseId: String
    let requestId: UUID
}
