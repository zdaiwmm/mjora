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

/// Versioned intent shared by PhotoKit and servers explicitly advertising photoEditsV1.
/// Legacy ImageAdjust deliberately remains unchanged.
nonisolated struct PhotoAdjust: Codable, Equatable, Sendable {
    let version = 1
    var exposure: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var invert = false
    var highlights: Double = 0
    var shadows: Double = 0
    var brightness: Double = 0
    var blackPoint: Double = 0
    var warmth: Double = 0
    var tint: Double = 0
    var straighten: Double = 0
    var horizontalPerspective: Double = 0
    var verticalPerspective: Double = 0

    static let neutral = PhotoAdjust()
    var isNeutral: Bool { self == .neutral }
    var hasExtendedColor: Bool { highlights != 0 || shadows != 0 || brightness != 0 || blackPoint != 0 || warmth != 0 || tint != 0 }
    var hasWarp: Bool { straighten != 0 || horizontalPerspective != 0 || verticalPerspective != 0 }
    var legacy: ImageAdjust {
        var result = ImageAdjust.neutral
        result.exposure = exposure; result.contrast = contrast; result.saturation = saturation; result.invert = invert
        return result
    }

    init() {}
    init(legacy: ImageAdjust) {
        exposure = legacy.exposure; contrast = legacy.contrast; saturation = legacy.saturation; invert = legacy.invert
    }

    enum ValidationError: Error { case unsupportedVersion, invalidAmount }
    private enum CodingKeys: String, CodingKey {
        case version, exposure, contrast, saturation, invert, highlights, shadows, brightness, blackPoint, warmth, tint
        case straighten, horizontalPerspective, verticalPerspective
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1 else { throw ValidationError.unsupportedVersion }
        func amount(_ key: CodingKeys) throws -> Double { try c.contains(key) ? c.decode(Double.self, forKey: key) : 0 }
        exposure = try amount(.exposure)
        contrast = try amount(.contrast)
        saturation = try amount(.saturation)
        invert = try c.contains(.invert) ? c.decode(Bool.self, forKey: .invert) : false
        highlights = try amount(.highlights)
        shadows = try amount(.shadows)
        brightness = try amount(.brightness)
        blackPoint = try amount(.blackPoint)
        warmth = try amount(.warmth)
        tint = try amount(.tint)
        straighten = try amount(.straighten)
        horizontalPerspective = try amount(.horizontalPerspective)
        verticalPerspective = try amount(.verticalPerspective)
        try validate()
    }

    func validate() throws {
        let amounts = [exposure, contrast, saturation, highlights, shadows, brightness, blackPoint, warmth, tint]
        guard amounts.allSatisfy({ $0.isFinite && (-100...100).contains($0) }),
              straighten.isFinite, (-45...45).contains(straighten),
              horizontalPerspective.isFinite, (-1...1).contains(horizontalPerspective),
              verticalPerspective.isFinite, (-1...1).contains(verticalPerspective)
        else { throw ValidationError.invalidAmount }
    }
}

extension AssetEdit {
    nonisolated static func photo(_ adjust: PhotoAdjust) throws -> AssetEdit {
        try adjust.validate()
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(adjust))
        return .other(action: "photo", parameters: value)
    }

    nonisolated var isPhotoAdjustment: Bool { if case .other(action: "photo", parameters: _) = self { true } else { false } }

    nonisolated func photoAdjust() throws -> PhotoAdjust? {
        guard case .other(action: "photo", parameters: let value) = self else { return nil }
        guard let value else { throw PhotoAdjust.ValidationError.invalidAmount }
        return try JSONDecoder().decode(PhotoAdjust.self, from: JSONEncoder().encode(value))
    }
}

/// The reference math also supplies normalization to the GPU warp kernel.
nonisolated enum PhotoAdjustMath {
    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func color(red: Double, green: Double, blue: Double, adjust a: PhotoAdjust) -> (Double, Double, Double) {
        var rgb = [red, green, blue]
        func luma() -> Double { 0.213 * rgb[0] + 0.715 * rgb[1] + 0.072 * rgb[2] }
        func map(_ operation: (Double) -> Double) { rgb = rgb.map { clamp(operation($0)) } }
        let l = luma(), s = 1 + a.saturation / 100
        map { l + s * ($0 - l) }
        if a.invert { map { 1 - $0 } }
        map { $0 * (1 + a.exposure / 100) }
        let highlight = 0.5 * a.highlights / 100 * pow(luma(), 2)
        map { $0 + highlight }
        let shadow = 0.5 * a.shadows / 100 * pow(1 - luma(), 2)
        map { $0 + shadow }
        map { $0 + 0.5 * a.brightness / 100 }
        let black = 0.5 * a.blackPoint / 100
        map { ($0 - black) / (1 - black) }
        rgb[0] = clamp(rgb[0] + 0.15 * a.warmth / 100)
        rgb[2] = clamp(rgb[2] - 0.15 * a.warmth / 100)
        rgb[0] = clamp(rgb[0] + 0.075 * a.tint / 100)
        rgb[1] = clamp(rgb[1] - 0.15 * a.tint / 100)
        rgb[2] = clamp(rgb[2] + 0.075 * a.tint / 100)
        map { ($0 - 0.5) * (1 + a.contrast / 100) + 0.5 }
        return (rgb[0], rgb[1], rgb[2])
    }

    private static func unscaled(u: Double, v: Double, adjust a: PhotoAdjust) -> (x: Double, y: Double) {
        let radians = -a.straighten * .pi / 180
        let d = 1 + 0.25 * (a.horizontalPerspective * u + a.verticalPerspective * v)
        return ((cos(radians) * u - sin(radians) * v) / d, (sin(radians) * u + cos(radians) * v) / d)
    }
    static func cornerScale(_ a: PhotoAdjust) -> Double {
        var m = 1.0
        for u in [-1.0, 1] { for v in [-1.0, 1] {
            let p = unscaled(u: u, v: v, adjust: a)
            m = max(m, abs(p.x), abs(p.y))
        } }
        return m
    }
    static func inverseSample(u: Double, v: Double, adjust: PhotoAdjust) -> (x: Double, y: Double) {
        let p = unscaled(u: u, v: v, adjust: adjust), m = cornerScale(adjust)
        return (p.x / m, p.y / m)
    }
}

/// Persistence is separate from presentation so no failed/partial write destroys a draft.
/// Closures cross the external I/O boundary; readback always compares the whole intent.
nonisolated enum PhotoEditPersistence {
    enum SaveError: LocalizedError, Equatable {
        case unconfirmed, partialOrUnconfirmed
        var errorDescription: String? {
            switch self {
            case .unconfirmed: String(localized: "The server couldn't confirm this save. Your edits are still here. Try again.")
            case .partialOrUnconfirmed: String(localized: "Some edits may have been saved. Your full draft is still here. Try again to finish saving.")
            }
        }
    }

    static func saveAtomic(intent: [AssetEdit], write: ([AssetEdit]) async throws -> Void, read: () async throws -> [AssetEdit]) async throws {
        do { try await write(intent) }
        catch {
            guard let stored = try? await read(), stored == intent else { throw SaveError.unconfirmed }
        }
    }

    static func saveLegacy(
        adjust: ImageAdjust?, edits: [AssetEdit]?,
        writeAdjust: (ImageAdjust) async throws -> Void, writeEdits: ([AssetEdit]) async throws -> Void,
        readAdjust: () async throws -> ImageAdjust, readEdits: () async throws -> [AssetEdit]
    ) async throws {
        do {
            if let adjust { try await writeAdjust(adjust) }
            if let edits { try await writeEdits(edits) }
        } catch PhotoEditDraft.RecoveryError.writeConflict {
            throw PhotoEditDraft.RecoveryError.writeConflict
        } catch {
            let actualAdjust = adjust == nil ? nil : try? await readAdjust()
            let actualEdits = edits == nil ? nil : try? await readEdits()
            guard (adjust == nil || actualAdjust == adjust), (edits == nil || actualEdits == edits) else {
                throw SaveError.partialOrUnconfirmed
            }
        }
    }
}

/// Legacy writes can partially commit. Recovery intent is independent of undo
/// history so returning the draft to its opening value still permits repair.
nonisolated struct LegacyPhotoEditRecovery: Equatable, Sendable {
    private(set) var isUnconfirmed = false
    nonisolated struct Intent: Sendable { let adjust: ImageAdjust?; let edits: [AssetEdit]? }
    mutating func recordUnconfirmed() { isUnconfirmed = true }
    mutating func recordConfirmed() { isUnconfirmed = false }
    func needsSave(draftChanged: Bool) -> Bool { draftChanged || isUnconfirmed }
    func intent(adjust: ImageAdjust, initialAdjust: ImageAdjust, edits: [AssetEdit], geometryChanged: Bool,
                hadServerEdits: Bool, supportsAdjust: Bool = true) -> Intent {
        let adjustChanged = adjust != initialAdjust
        let geometry = isUnconfirmed || ((geometryChanged || !adjustChanged) && (!edits.isEmpty || hadServerEdits))
        return Intent(adjust: supportsAdjust && (adjustChanged || isUnconfirmed) ? adjust : nil, edits: geometry ? edits : nil)
    }
}
