import Foundation

/// /assets/{id}/adjust on gallery and imora. each amount runs from -100 to
/// 100 with 0 as unchanged.
nonisolated struct ImageAdjust: Codable, Equatable, Sendable {
    var exposure: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var invert = false

    static let neutral = ImageAdjust()

    var isNeutral: Bool { self == .neutral }

    private enum CodingKeys: String, CodingKey { case exposure, contrast, saturation, invert }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        invert = try container.decodeIfPresent(Bool.self, forKey: .invert) ?? false
    }
}

/// /assets/{id}/trim on gallery and imora, in seconds of the original video.
nonisolated struct VideoTrim: Codable, Equatable, Sendable {
    var startTime: Double
    var endTime: Double
    /// the untrimmed length, only in responses.
    var originalDuration: Double? = nil
}
