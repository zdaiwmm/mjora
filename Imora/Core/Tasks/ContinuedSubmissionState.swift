import Foundation

/// Submission and launch may finish in either order. A generation prevents a
/// late submission result from replacing a running or newly requested task.
nonisolated struct ContinuedSubmissionState: Sendable {
    struct Request: Equatable, Sendable {
        let id: UUID
        let owner: UUID
    }

    enum Denial: Equatable, Sendable {
        case systemBusy
        case systemUnavailable
        case notPermitted
        case tooManyRequests
        case unknown
    }

    enum Status: Equatable, Sendable {
        case idle
        case accepting
        case accepted
        case running
        case paused
        case denied(Denial)

        var isActive: Bool {
            switch self {
            case .accepting, .accepted, .running: true
            default: false
            }
        }
    }

    private(set) var status: Status = .idle
    private var submission: Request?

    mutating func beginSubmission(owner: UUID) -> Request? {
        guard !status.isActive else { return nil }
        let request = Request(id: UUID(), owner: owner)
        submission = request
        status = .accepting
        return request
    }

    mutating func completeSubmission(_ request: Request, failure: Denial?) {
        guard submission == request, status == .accepting else { return }
        status = failure.map(Status.denied) ?? .accepted
    }

    mutating func didStart(_ request: Request, owner: UUID) -> Bool {
        guard submission == request, request.owner == owner,
              status == .accepting || status == .accepted else { return false }
        status = .running
        return true
    }

    mutating func didFinish(_ request: Request, paused: Bool) {
        guard submission == request else { return }
        submission = nil
        status = paused ? .paused : .idle
    }

    mutating func invalidateOwner() {
        submission = nil
        status = .idle
    }
}
