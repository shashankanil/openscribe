import XCTest
@testable import OpenScribe

final class TranscriptEditingTests: XCTestCase {
    func testRulesUseWholeUnicodeWordsAndLiteralReplacement() {
        let rules = [CorrectionRule(heard: "flow", replacement: "$1\\OpenScribe"),
                     CorrectionRule(heard: "शशांक", replacement: "Shashank")]
        XCTAssertEqual(CorrectionRule.apply(to: "FLOW, workflow flow_id शशांक शशांकजी", rules: rules),
                       "$1\\OpenScribe, workflow flow_id Shashank शशांकजी")
    }

    func testLongestMatchWinsWithoutCascading() {
        let rules = [CorrectionRule(heard: "open", replacement: "closed"),
                     CorrectionRule(heard: "open scribe", replacement: "OpenScribe"),
                     CorrectionRule(heard: "closed", replacement: "shut")]
        XCTAssertEqual(CorrectionRule.apply(to: "open scribe is open, closed", rules: rules), "OpenScribe is closed, shut")
    }

    func testBatchesPreserveAllTextAndBoundRequestSize() {
        let original = String(repeating: "Do not change 42. Meet at two, actually three. ", count: 1000)
        let batches = TranscriptEditing.batches(original)
        XCTAssertEqual(batches.joined(), original)
        XCTAssertTrue(batches.allSatisfy { $0.count <= 12_000 })
        XCTAssertEqual(TranscriptEditing.batches("one complete thought"), ["one complete thought"])
        XCTAssertEqual(TranscriptEditing.batches(String(repeating: "x", count: 25), limit: 10).map(\.count), [10, 10, 5])
    }

    func testLegacyVocabularyIsPreservedAndNewSettingsRoundTrip() throws {
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"customVocabulary":["Shashank"]}"#.utf8))
        XCTAssertEqual(settings.customVocabulary, ["Shashank"])
        XCTAssertEqual(settings.cleanupStrength, .clear)
        XCTAssertTrue(settings.correctionRules.isEmpty)
        settings.cleanupStrength = .light
        settings.correctionRules = [.init(heard: "open scribe", replacement: "OpenScribe")]
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
}
