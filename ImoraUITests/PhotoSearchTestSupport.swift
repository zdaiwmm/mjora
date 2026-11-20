import XCTest

extension XCUIApplication {
    var photoSearchField: XCUIElement {
        let compact = descendants(matching: .any).matching(identifier: "photos-search-field").firstMatch
        return compact.exists ? compact : searchFields.firstMatch
    }
}
