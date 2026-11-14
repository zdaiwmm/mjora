import Foundation

/// Semantic release ordering, with the bundle build as the tie breaker.
/// The existing two-component 1.0 bundle version is equivalent to 1.0.0.
nonisolated struct AppUpdateVersion: Comparable, Sendable {
    private let components: [Int]
    private let prerelease: [String]?
    private let build: Int

    init?(version: String, build: String) {
        guard version.utf8.count <= 128, !build.isEmpty,
              build.utf8.allSatisfy({ (48...57).contains($0) }), let buildNumber = Int(build) else { return nil }
        let metadata = version.split(separator: "+", omittingEmptySubsequences: false)
        guard metadata.count <= 2 else { return nil }
        if metadata.count == 2, !Self.validIdentifiers(String(metadata[1]), numericLeadingZerosAllowed: true) { return nil }
        let release = metadata[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = release[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(numbers.count) else { return nil }
        var parsed: [Int] = []
        for number in numbers {
            guard !number.isEmpty, number.utf8.allSatisfy({ (48...57).contains($0) }),
                  number.count == 1 || number.first != "0", let value = Int(number) else { return nil }
            parsed.append(value)
        }
        if parsed.count == 2 { parsed.append(0) }
        if release.count == 2 {
            guard Self.validIdentifiers(String(release[1]), numericLeadingZerosAllowed: false) else { return nil }
            prerelease = release[1].split(separator: ".").map(String.init)
        } else {
            prerelease = nil
        }
        components = parsed
        self.build = buildNumber
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.components != rhs.components { return lhs.components.lexicographicallyPrecedes(rhs.components) }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): break
        case (.some, nil): return true
        case (nil, .some): return false
        case let (.some(a), .some(b)):
            for (left, right) in zip(a, b) where left != right {
                let leftNumeric = left.utf8.allSatisfy { (48...57).contains($0) }
                let rightNumeric = right.utf8.allSatisfy { (48...57).contains($0) }
                if leftNumeric && rightNumeric {
                    return left.count == right.count ? left < right : left.count < right.count
                }
                if leftNumeric != rightNumeric { return leftNumeric }
                return left < right
            }
            if a.count != b.count { return a.count < b.count }
        }
        return lhs.build < rhs.build
    }

    private static func validIdentifiers(_ value: String, numericLeadingZerosAllowed: Bool) -> Bool {
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            guard !part.isEmpty, part.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            }) else { return false }
            let numeric = part.utf8.allSatisfy { (48...57).contains($0) }
            return numericLeadingZerosAllowed || !numeric || part.count == 1 || part.first != "0"
        }
    }
}
