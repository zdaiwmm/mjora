import Foundation
import Network
import Synchronization

/// Only synthetic loopback traffic. Exercises iOS URLSession's real redirect
/// handling rather than a URLProtocol mock which bypasses that handling.
final class LocalHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }
    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data("{}".utf8)
    }
    private let listener: NWListener
    private let queue: DispatchQueue
    private let handler: @Sendable (Request) -> Response
    private let requests = Mutex<[Request]>([])
    private let connections = Mutex<[NWConnection]>([])

    var received: [Request] { requests.withLock { $0 } }
    var apiURL: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/api")! }

    init(concurrent: Bool = false, handler: @escaping @Sendable (Request) -> Response) throws {
        self.handler = handler
        queue = DispatchQueue(label: "imora.tests.loopback", attributes: concurrent ? .concurrent : [])
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.withLock({ if $0 { return false }; $0 = true; return true }) { continuation.resume() }
                case .failed(let error):
                    if resumed.withLock({ if $0 { return false }; $0 = true; return true }) { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.withLock { $0.append(connection) }
                connection.start(queue: self.queue)
                self.read(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        connections.withLock { values in values.forEach { $0.cancel() }; values.removeAll() }
    }

    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            guard let range = bytes.range(of: Data("\r\n\r\n".utf8)),
                  let header = String(data: bytes[..<range.lowerBound], encoding: .utf8)
            else {
                if !complete { self.read(connection, accumulated: bytes) } else { connection.cancel() }
                return
            }
            let lines = header.components(separatedBy: "\r\n")
            let first = lines[0].components(separatedBy: " ")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") {
                    headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            if bytes.count - range.upperBound < length, !complete { self.read(connection, accumulated: bytes); return }
            let request = Request(method: first[0], path: first.count > 1 ? first[1] : "/", headers: headers, body: Data(bytes[range.upperBound...]))
            self.requests.withLock { $0.append(request) }
            let response = self.handler(request)
            var text = "HTTP/1.1 \(response.status) Test\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
            for (key, value) in response.headers { text += "\(key): \(value)\r\n" }
            text += "\r\n"
            var outgoing = Data(text.utf8)
            outgoing.append(response.body)
            connection.send(content: outgoing, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
