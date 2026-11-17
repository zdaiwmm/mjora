import Foundation

nonisolated struct BackupPreparationFailure: Error {
    let underlying: any Error

    static func annotate(_ error: any Error) -> any Error {
        switch error {
        case is CancellationError, is PhotoLibraryError, is UploadSizeLimit,
             is ImoraError, is BackupVerificationError, is BackupUploadAuthorityPause,
             is RemoteSyncError, is ChunkedAssetUpload.Unavailable, is BackupPreparationFailure:
            return error
        default:
            return BackupPreparationFailure(underlying: error)
        }
    }
}

/// Transport failures retain their original types even when a resource producer awaits them.
nonisolated enum BackupPreparationBoundary {
    private struct ConsumerFailure: Error { let underlying: any Error }

    static func perform<Value>(_ operation: () throws -> Value) throws -> Value {
        do { return try operation() }
        catch { throw BackupPreparationFailure.annotate(error) }
    }

    static func performAsync<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        do { return try await operation() }
        catch { throw BackupPreparationFailure.annotate(error) }
    }

    static func stream<Element: Sendable>(
        produce: @Sendable (@escaping @Sendable (Element) async throws -> Void) async throws -> Void,
        consume: @escaping @Sendable (Element) async throws -> Void
    ) async throws {
        do {
            try await produce { element in
                do { try await consume(element) }
                catch { throw ConsumerFailure(underlying: error) }
            }
        } catch let failure as ConsumerFailure {
            throw failure.underlying
        } catch {
            throw BackupPreparationFailure.annotate(error)
        }
    }
}
