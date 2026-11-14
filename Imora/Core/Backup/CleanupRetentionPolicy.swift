import Foundation

nonisolated enum CleanupRetentionReason: String, Codable, CaseIterable, Sendable {
    case recent, favorite, album, unknownDate, unverified, cloudDeleted
}

/// The policy is configuration; the snapshot fixes its calendar boundary at preview time.
nonisolated struct CleanupRetentionPolicy: Codable, Equatable, Sendable {
    var retentionDays: Int? = 30
    var customStartDate: Date? = nil
    var preserveFavorites = true
    var protectedAlbumIDs: Set<String> = []

    func snapshot(at now: Date = Date(), timeZone: TimeZone = .current) -> CleanupRetentionSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let cutoff: Date?
        if let customStartDate { cutoff = customStartDate }
        else if let retentionDays {
            // Include today, across daylight-saving changes, using calendar days.
            cutoff = calendar.date(byAdding: .day, value: -(max(1, retentionDays) - 1), to: calendar.startOfDay(for: now))
        } else { cutoff = nil }
        return CleanupRetentionSnapshot(policy: self, cutoff: cutoff, timeZoneIdentifier: timeZone.identifier)
    }
}

nonisolated struct CleanupRetentionSnapshot: Codable, Equatable, Sendable {
    let policy: CleanupRetentionPolicy
    let cutoff: Date?
    let timeZoneIdentifier: String

    func reasons(creationDate: Date?, isFavorite: Bool, protectedAlbumMember: Bool) -> Set<CleanupRetentionReason> {
        var result: Set<CleanupRetentionReason> = []
        if let creationDate {
            if let cutoff, creationDate >= cutoff { result.insert(.recent) }
        } else { result.insert(.unknownDate) }
        if policy.preserveFavorites && isFavorite { result.insert(.favorite) }
        if protectedAlbumMember { result.insert(.album) }
        return result
    }
}
