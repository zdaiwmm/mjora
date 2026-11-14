import Foundation

/// Actual URLSession transport counters for one HTTP upload task. The
/// monotonic clock supports speed measurement without wall-clock jumps.
nonisolated struct UploadByteProgress: Sendable {
    let transferID: UUID
    let bytesSent: Int64
    let totalBytesSent: Int64
    let totalBytesExpectedToSend: Int64
    let timestamp: TimeInterval
}
