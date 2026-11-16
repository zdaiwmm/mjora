import Foundation

/// Presentation only: server city strings remain unchanged in search queries,
/// grouping and persisted EXIF. The offline gazetteer avoids a geocoder request
/// (and a delayed title replacement) whenever a photo appears.
nonisolated enum PhotoPlaceName {
    private static let chinese = Locale(identifier: "zh_Hans_CN")
    private static let names: [String: String] = {
        guard let url = Bundle.main.url(forResource: "ChinesePlaceNames", withExtension: "json"),
              let bytes = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String: String].self, from: bytes) else { return [:] }
        return names
    }()
    private static let countries: [String: String] = {
        var result: [String: String] = [:]
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard let translated = chinese.localizedString(forRegionCode: code) else { continue }
            result[key(code)] = translated
            for locale in [Locale(identifier: "en_US"), chinese] {
                if let name = locale.localizedString(forRegionCode: code) { result[key(name)] = translated }
            }
        }
        for alias in ["CN", "China", "Mainland China", "China mainland", "中国大陆", "People's Republic of China", "PR China"] {
            result[key(alias)] = "中国"
        }
        for alias in ["HK", "Hong Kong"] { result[key(alias)] = "中国香港特别行政区" }
        for alias in ["MO", "Macau", "Macao"] { result[key(alias)] = "中国澳门特别行政区" }
        for alias in ["TW", "Taiwan"] { result[key(alias)] = "台湾" }
        return result
    }()

    static func prepare() {
        guard Locale.current.language.languageCode?.identifier == "zh" else { return }
        _ = names
        _ = countries
    }

    static func localized(_ value: String, country: String? = nil, locale: Locale = .current) -> String {
        guard locale.language.languageCode?.identifier == "zh" else { return value }
        let normalized = key(value)
        if let translated = countries[normalized] { return translated }
        if let country, let region = countries[key(country)], !["中国", "中国香港特别行政区", "中国澳门特别行政区", "台湾"].contains(region) {
            return value
        }
        if let translated = names[normalized] { return translated }
        return value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
    }

    static func title(city: String?, country: String?, locale: Locale = .current) -> String? {
        [city, country].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }).map { localized($0, country: country, locale: locale) }
    }

    private static func key(_ value: String) -> String {
        String(value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
