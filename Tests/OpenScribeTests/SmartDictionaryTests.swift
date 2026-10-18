import Foundation
import XCTest
@testable import OpenScribe

final class SmartDictionaryTests: XCTestCase {
    // MARK: - Speech hints

    func testHintsCombineVocabularyAndCorrectionTargets() {
        var settings = AppSettings()
        settings.customVocabulary = ["Shashank", "Kenpath Labs", "shashank", ""]
        settings.correctionRules = [CorrectionRule(heard: "open scribe", replacement: "OpenScribe"),
                                    CorrectionRule(heard: "sig", replacement: "Best regards, and a very long signature that is a snippet")]
        XCTAssertEqual(SpeechHints.terms(settings), ["Shashank", "Kenpath Labs", "OpenScribe"])
        XCTAssertEqual(SpeechHints.contextBias(SpeechHints.terms(settings)), "Shashank,Kenpath,Labs,OpenScribe")
        XCTAssertEqual(SpeechHints.prompt(["Qdrant"]), "Glossary: Qdrant.")
        settings.speechHints = false
        XCTAssertTrue(SpeechHints.terms(settings).isEmpty)
    }

    func testStreamingCarriesHints() {
        var settings = AppSettings()
        settings.speechProvider = .deepgram
        settings.speechBaseURL = "https://api.deepgram.com/v1"
        settings.speechModel = "nova-3"
        settings.customVocabulary = ["Qdrant"]
        let request = StreamingCapability.resolve(settings)?.request(apiKey: "k")
        XCTAssertTrue(request?.url?.query?.contains("keyterm=Qdrant") == true)
    }

    func testSettingsDecodeWithoutDictionaryFlags() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.speechHints && decoded.spokenCorrections && decoded.learnSpelledWords)
        XCTAssertEqual(decoded.correctionModel, "")
    }

    // MARK: - Local pass

    func testLocalPassJoinsSplitTermsAndFixesCoinedCasingOnly() {
        let common: (String) -> Bool = { ["railway"].contains($0.lowercased()) }
        let text = "Ship open scribe and Open-Scribe on supabase, then take the railway home."
        let fixed = DictionaryPass.apply(to: text, vocabulary: ["OpenScribe", "Supabase", "Railway"], isCommonWord: common)
        XCTAssertEqual(fixed, "Ship OpenScribe and OpenScribe on Supabase, then take the railway home.")
        // Parts of longer words are never touched.
        XCTAssertEqual(DictionaryPass.apply(to: "supabases", vocabulary: ["Supabase"], isCommonWord: common), "supabases")
    }

    // MARK: - Spoken corrections

    func testCuesAreNarrow() {
        XCTAssertTrue(SpokenCorrection.mightContainCorrection("Email Shashank, that's S H A S H A N K, about it."))
        XCTAssertTrue(SpokenCorrection.mightContainCorrection("It's Qdrant, spelled with a Q."))
        XCTAssertTrue(SpokenCorrection.mightContainCorrection("Let's meet Friday, no wait, Thursday."))
        XCTAssertTrue(SpokenCorrection.mightContainCorrection("Send it to Sam, sorry, Sara."))
        XCTAssertFalse(SpokenCorrection.mightContainCorrection("Actually, I think we should ship it today."))
        XCTAssertFalse(SpokenCorrection.mightContainCorrection("Sorry for the delay, I mean to reply sooner."))
    }

    func testOnlyConfidentVerifiableEditsApply() {
        let text = "Email Shashunk, that's S H A S H A N K, about the launch."
        let edits = [
            SpokenCorrection.Edit(kind: .spelling, find: "Shashunk, that's S H A S H A N K,", replace: "Shashank", term: "Shashank", confidence: 0.95),
        ]
        let outcome = SpokenCorrection.apply(edits, to: text)
        XCTAssertEqual(outcome.text, "Email Shashank about the launch.")
        XCTAssertEqual(outcome.learned, ["Shashank"])

        // Letters that don't spell the term, low confidence, content, or text that isn't there: all ignored.
        let rejected = [
            SpokenCorrection.Edit(kind: .spelling, find: "Shashunk, that's S H A S H A N K,", replace: "Shasha", term: "Shasha", confidence: 0.99),
            SpokenCorrection.Edit(kind: .selfCorrection, find: "about", replace: "regarding", term: nil, confidence: 0.5),
            SpokenCorrection.Edit(kind: .content, find: "launch", replace: "release", term: nil, confidence: 0.99),
            SpokenCorrection.Edit(kind: .selfCorrection, find: "not in the text", replace: "x", term: nil, confidence: 0.99),
        ]
        XCTAssertEqual(SpokenCorrection.apply(rejected, to: text), .init(text: text, learned: []))
    }

    func testSelfCorrectionKeepsTheCorrectedVersion() {
        let text = "Let's meet Friday, no wait, Thursday at noon."
        let edit = SpokenCorrection.Edit(kind: .selfCorrection, find: "Friday, no wait, Thursday", replace: "Thursday", term: nil, confidence: 0.9)
        XCTAssertEqual(SpokenCorrection.apply([edit], to: text).text, "Let's meet Thursday at noon.")
    }

    func testParsesFencedClassifierOutput() {
        let response = """
        ```json
        {"edits":[{"type":"spelling","find":"Jon, no h","replace":"Jon","term":"Jon","confidence":0.9}]}
        ```
        """
        XCTAssertEqual(SpokenCorrection.parse(response).first?.kind, .spelling)
        XCTAssertTrue(SpokenCorrection.parse("no json here").isEmpty)
    }
}

/// Manual: runs the classifier against the configured writing model. OPENSCRIBE_CLASSIFIER_PROBE=1 to enable.
final class SpokenCorrectionProbe: XCTestCase {
    func testClassifierOnRealModel() async throws {
        guard ProcessInfo.processInfo.environment["OPENSCRIBE_CLASSIFIER_PROBE"] != nil else { throw XCTSkip("manual probe") }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WhisperFlow")
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: root.appendingPathComponent("settings.json")))
        if let model = ProcessInfo.processInfo.environment["OPENSCRIBE_CLASSIFIER_MODEL"] { settings.correctionModel = model }
        let key = try XCTUnwrap(CredentialStore.read(for: .languageModel, settings: settings))
        let cases = [
            "Email Shashunk, that's S H A S H A N K, about the launch.",
            "We're moving to Kdrant, spelled Q D R A N T, next sprint.",
            "Let's meet Friday, no wait, Thursday at noon.",
            "Send it to Sam, sorry, Sara, before five.",
            "For the kids worksheet, spell cat as C A T and dog as D O G.",
            "The Wi-Fi password is B X 7 Q, all caps.",
            "Sorry for the delay, I mean to reply sooner.",
            "My name is Jon, J O N, no H.",
        ]
        for text in cases {
            let started = Date()
            let edits = try await SpokenCorrection.classify(text, vocabulary: [], settings: settings, apiKey: key)
            let outcome = SpokenCorrection.apply(edits, to: text)
            print(String(format: "CLASSIFY %.2fs", Date().timeIntervalSince(started)), "|", text, "→", outcome.text, "| learned:", outcome.learned,
                  "| raw:", edits.map { "\($0.kind.rawValue)@\($0.confidence)" })
        }
    }
}
