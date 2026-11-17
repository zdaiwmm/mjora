import Foundation
import Photos

/// Closed categories and numeric codes only. Error messages and userInfo never persist.
nonisolated struct BackupFailureDiagnostic: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable {
        case preparing, uploading, verifying

        var title: String {
            switch self {
            case .preparing: String(localized: "Preparing original")
            case .uploading: String(localized: "Uploading file")
            case .verifying: String(localized: "Verifying backup")
            }
        }
    }

    enum Category: String, Codable, Sendable {
        case http, urlSession, photoKit, cocoa, posix, verification, storage, uploadLimit, other
    }

    enum VerificationState: String, Codable, Sendable {
        case invalidResponse, stale, mismatch
        case pending, verifying, verified, missing, trashed, offline, pairPending, pairConflict, pairPermissionDenied, failed

        var message: String {
            switch self {
            case .invalidResponse: BackupVerificationError.invalidResponse.localizedDescription
            case .stale: BackupVerificationError.stale.localizedDescription
            case .mismatch: BackupVerificationError.mismatch.localizedDescription
            default:
                BackupVerificationError.component("", BackupVerificationState(rawValue: rawValue) ?? .failed).localizedDescription
            }
        }
    }

    let stage: Stage
    let category: Category
    let code: Int?
    let verificationState: VerificationState?

    private init(stage: Stage, category: Category, code: Int? = nil, verificationState: VerificationState? = nil) {
        self.stage = stage
        self.category = category
        self.code = code
        self.verificationState = verificationState
    }

    init(stage: Stage) {
        self.init(stage: stage, category: .other)
    }

    init(error: any Error, stage: Stage) {
        if let preparation = error as? BackupPreparationFailure {
            self.init(error: preparation.underlying, stage: .preparing)
            return
        }
        if let pause = error as? BackupUploadAuthorityPause {
            self.init(error: pause.underlying, stage: stage)
            return
        }
        let systemError = error as NSError
        switch error {
        case ImoraError.http(let status, _):
            self.init(stage: stage, category: .http, code: status)
        case let failure as BackupVerificationError:
            let state: VerificationState?
            switch failure {
            case .invalidResponse: state = .invalidResponse
            case .stale: state = .stale
            case .mismatch: state = .mismatch
            case .component(_, let component): state = VerificationState(rawValue: component.rawValue)
            }
            self.init(stage: .verifying, category: .verification, verificationState: state)
        case PhotoLibraryError.insufficientStorage:
            self.init(stage: .preparing, category: .storage)
        case is PhotoLibraryError:
            self.init(stage: .preparing, category: .photoKit)
        case is UploadSizeLimit:
            self.init(stage: .preparing, category: .uploadLimit)
        default:
            switch systemError.domain {
            case NSURLErrorDomain:
                self.init(stage: stage, category: .urlSession, code: systemError.code)
            case PHPhotosErrorDomain:
                self.init(stage: .preparing, category: .photoKit, code: systemError.code)
            case NSCocoaErrorDomain:
                self.init(stage: stage, category: .cocoa, code: systemError.code)
            case NSPOSIXErrorDomain:
                self.init(stage: stage, category: .posix, code: systemError.code)
            default:
                self.init(stage: stage, category: .other)
            }
        }
    }

    var detail: String {
        if let verificationState { return verificationState.message }
        if let code {
            switch category {
            case .http: return "HTTP \(code)"
            case .urlSession: return "URLSession \(code)"
            case .photoKit: return "PhotoKit \(code)"
            case .cocoa: return "Cocoa \(code)"
            case .posix: return "POSIX \(code)"
            default: break
            }
        }
        return switch category {
        case .storage: RepeatedBackupFailureKind.deviceStorage.explanation
        case .uploadLimit: RepeatedBackupFailureKind.uploadLimit.explanation
        case .photoKit: RepeatedBackupFailureKind.originalUnavailable.explanation
        default: String(localized: "Exact error details were not saved for this attempt.")
        }
    }
}
