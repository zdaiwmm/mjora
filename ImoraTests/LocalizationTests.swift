import Foundation
import XCTest
@testable import Imora

final class LocalizationTests: XCTestCase {
    private func languageBundle(_ language: String) throws -> Bundle {
        let app = Bundle.main
        let url = try XCTUnwrap(app.url(forResource: language, withExtension: "lproj"), "Missing shipped language \(language)")
        return try XCTUnwrap(Bundle(url: url))
    }

    func testChineseResourcesRenderCountsAndKeepInterpolatedValues() throws {
        let bundle = try languageBundle("zh-Hans")
        for count in [0, 1, 2, 100] {
            let text = String(localized: "\(count) photos", bundle: bundle, locale: Locale(identifier: "zh_Hans"))
            XCTAssertTrue(text.contains("照片"))
            XCTAssertTrue(text.contains(String(count)))
        }
        let count = 2
        let text = String(localized: "\(count) videos", bundle: bundle, locale: Locale(identifier: "zh_Hans"))
        XCTAssertTrue(text.contains("视频"))
        XCTAssertTrue(text.contains("2"))
        let code = 413
        let error = String(localized: "The server rejected the upload (HTTP \(code)).", bundle: bundle)
        XCTAssertTrue(error.contains("413"))
        XCTAssertTrue(error.contains("服务器"))
    }

    @MainActor
    func testChineseSentencePunctuationIsPreserved() {
        for value in ["校验失败。", "请重试！", "继续吗？"] {
            XCTAssertEqual(ErrorToastCenter.sentence(value), value)
        }
    }

    func testEnglishResourcesHaveSingularAndPluralPhrases() throws {
        let bundle = try languageBundle("en")
        let one = 1, two = 2
        XCTAssertEqual(String(localized: "\(one) photos", bundle: bundle, locale: Locale(identifier: "en")), "1 photo")
        XCTAssertEqual(String(localized: "\(two) photos", bundle: bundle, locale: Locale(identifier: "en")), "2 photos")
        XCTAssertEqual(String(localized: "\(one) videos", bundle: bundle, locale: Locale(identifier: "en")), "1 video")
    }
}
