import Foundation

/// Asset.localDate is already a photographer-local wall clock represented
/// in UTC calendar space. Applying the device offset again changes its meaning.
nonisolated enum PhotoDatePresentation {
    static func dateTime(wallClock: Date, locale: Locale = .current) -> String {
        wallClock.formatted(Date.FormatStyle(date: .long, time: .shortened,
            locale: locale, calendar: Calendar(identifier: .gregorian), timeZone: .gmt))
    }

    static func searchDates(wallClock: Date) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let c = calendar.dateComponents([.year, .month, .day], from: wallClock)
        guard let y = c.year, let m = c.month, let d = c.day else { return [] }
        return [String(y), String(format: "%04d-%02d-%02d", y, m, d),
                "\(y)-\(m)-\(d)", String(format: "%04d/%02d/%02d", y, m, d),
                "\(y)/\(m)/\(d)", "\(y)年\(m)月\(d)日", "\(m)月\(d)日",
                wallClock.formatted(.dateTime.year().month(.wide).day().utc())]
    }
}
