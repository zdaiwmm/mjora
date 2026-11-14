import Foundation
import SwiftUI

/// date-only birth date strings from the people api, utc "yyyy-MM-dd".
nonisolated enum PersonBirthDate {
    private static let wire: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        wire.date(from: String(raw.prefix(10)))
    }

    static func string(from date: Date) -> String {
        wire.string(from: date)
    }

    /// localized "Jan 5, 1990", anchored to utc so the day never drifts.
    static func displayLabel(_ raw: String) -> String? {
        guard let date = parse(raw) else { return nil }
        var style = Date.FormatStyle(date: .abbreviated)
        style.timeZone = TimeZone(identifier: "UTC")!
        return date.formatted(style)
    }

    /// age today, phrased like the reference clients: months under one year,
    /// year and months under two, plain years after.
    static func ageLabel(_ raw: String, at reference: Date = .now) -> String? {
        guard let birth = parse(raw) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let months = calendar.dateComponents([.month], from: birth, to: reference).month ?? 0
        guard months >= 0 else { return nil }
        if months <= 11 { return months == 1 ? String(localized: "1 month old") : String(localized: "\(months) months old") }
        if months == 12 { return String(localized: "1 year old") }
        if months == 13 { return String(localized: "1 year, 1 month old") }
        if months < 24 { return String(localized: "1 year, \(months - 12) months old") }
        return String(localized: "Age \(months / 12)")
    }
}

/// circular person thumbnail that fills its container square. favorites wear
/// a small glass heart riding the circle's edge.
struct PersonAvatar: View {
    @Environment(SessionStore.self) private var session
    let person: Person
    var targetPixelSize: CGFloat = 240
    var showsFavorite = true

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let url = session.personThumbnailURL(person) {
                    RemoteImage(url: url, targetPixelSize: targetPixelSize)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .clipShape(.circle)
            .overlay(alignment: .bottomTrailing) {
                if showsFavorite, person.isFavorite == true {
                    Image(systemName: "heart.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.pink)
                        .padding(4)
                        .glassEffect(.regular, in: .circle)
                        .accessibilityHidden(true)
                }
            }
    }
}

extension SessionStore {
    /// the user id a name or birthday edit carries, so it only changes the
    /// user's own copy of a shared person. nil edits every copy they may edit.
    var personEditUserID: String? {
        guard capabilities.supportsPeopleSharing, preferences?.peopleUpdateStrategy == .onlyMe else { return nil }
        return user?.id
    }

    /// the other members of the user's cluster group, the only users people
    /// can be shared with. the group is read fresh since joining one moves it.
    func clusterGroupMembers() async throws -> [User] {
        guard let client else { return [] }
        let me = try await client.currentUser()
        guard let groupID = me.clusterGroupId else { return [] }
        return try await client.clusterGroupUsers(id: groupID).filter { $0.id != me.id }
    }
}

/// a server user with a tick, for the people sharing pickers.
struct SelectableUserRow: View {
    let user: User
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                UserAvatar(user: user, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(user.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(user.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.22), value: isSelected)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// avatar, name and a second line, for the people sharing lists.
struct SharingUserLabel: View {
    let user: User
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            UserAvatar(user: user, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(user.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(detail ?? user.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
