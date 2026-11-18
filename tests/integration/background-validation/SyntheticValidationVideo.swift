import AVFoundation
import CoreVideo
import Foundation

nonisolated enum SyntheticValidationVideo {
    static func make(_ url: URL, size: Int64, marker: String) async throws {
        guard size >= 4096, size <= 512 * 1024 * 1024 else { throw CocoaError(.fileWriteInvalidFileName) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<2 {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, let buffer else {
                throw CocoaError(.fileWriteUnknown)
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, frame == 0 ? 48 : 192, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            for _ in 0..<500 where !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 1)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let original = try handle.seekToEnd()
        let padding = size - Int64(original)
        guard padding >= 8 + marker.utf8.count else { throw CocoaError(.fileWriteOutOfSpace) }
        var length = UInt32(padding).bigEndian
        try handle.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        try handle.write(contentsOf: Data("free".utf8))
        try handle.write(contentsOf: Data(marker.utf8))
        try handle.truncate(atOffset: UInt64(size))
        try handle.synchronize()
    }

    static func verifyDecodes(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(), CMSampleBufferGetImageBuffer(sample) != nil else {
            throw reader.error ?? CocoaError(.fileReadCorruptFile)
        }
        reader.cancelReading()
    }
}
