import XCTest
@testable import OpenScribe

/// Each provider's model list format, and the filters that keep transcription and writing models apart.
final class ProviderModelsTests: XCTestCase {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    func testOpenAIStyleListsAreSplitByPurpose() throws {
        let body = json(#"{"data":[{"id":"gpt-4o-mini"},{"id":"whisper-1"},{"id":"gpt-4o-mini-transcribe"},{"id":"text-embedding-3-small"},{"id":"tts-1"},{"id":"dall-e-3"},{"id":"gpt-5"}]}"#)
        XCTAssertEqual(try ProviderModelCatalog.parseOpenAIStyle(body, purpose: .speech, providerID: "openAI", title: "OpenAI").map(\.id),
                       ["gpt-4o-mini-transcribe", "whisper-1"])
        XCTAssertEqual(try ProviderModelCatalog.parseOpenAIStyle(body, purpose: .languageModel, providerID: "openAI", title: "OpenAI").map(\.id),
                       ["gpt-4o-mini", "gpt-5"])
    }

    func testCustomServersShowEverythingWhenNothingMatches() throws {
        let body = json(#"{"data":[{"id":"my-local-asr"},{"id":"another"}]}"#)
        XCTAssertEqual(try ProviderModelCatalog.parseOpenAIStyle(body, purpose: .speech, providerID: "custom", title: "Custom").map(\.id),
                       ["another", "my-local-asr"])
        XCTAssertEqual(try ProviderModelCatalog.parseOpenAIStyle(body, purpose: .speech, providerID: "groq", title: "Groq"), [])
    }

    func testOpenRouterFiltersByModality() throws {
        let body = json(#"""
        {"data":[
          {"id":"mistralai/voxtral-mini-transcribe","name":"Voxtral Mini","architecture":{"input_modalities":["audio"],"output_modalities":["text"]}},
          {"id":"openai/gpt-5","name":"GPT-5","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}},
          {"id":"some/image-gen","architecture":{"input_modalities":["text"],"output_modalities":["image"]}}
        ]}
        """#)
        // Transcription lists arrive pre-filtered by `output_modalities=transcription`, so all are kept.
        let transcription = json(#"{"data":[{"id":"mistralai/voxtral-mini-transcribe","name":"Voxtral Mini","architecture":{"input_modalities":["audio"],"output_modalities":["transcription"]}}]}"#)
        XCTAssertEqual(try ProviderModelCatalog.parseOpenRouter(transcription, purpose: .speech, title: "OpenRouter"),
                       [ProviderModel(id: "mistralai/voxtral-mini-transcribe", name: "Voxtral Mini")])
        XCTAssertEqual(try ProviderModelCatalog.parseOpenRouter(body, purpose: .languageModel, title: "OpenRouter").map(\.id), ["openai/gpt-5"])
    }

    func testDeepgramOffersFamiliesAndVariants() throws {
        let body = json(#"{"stt":[{"name":"general","canonical_name":"nova-3-general","architecture":"nova-3"},{"name":"medical","canonical_name":"nova-3-medical","architecture":"nova-3"},{"canonical_name":"nova-2-general","architecture":"nova-2"}],"tts":[]}"#)
        XCTAssertEqual(try ProviderModelCatalog.parseDeepgram(body, title: "Deepgram").map(\.id),
                       ["nova-2", "nova-2-general", "nova-3", "nova-3-general", "nova-3-medical"])
    }

    func testAnthropicPagesKeepDisplayNames() throws {
        let body = json(#"{"data":[{"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5","created_at":"2026-10-01T00:00:00Z"}],"has_more":true,"first_id":"claude-opus-5-5","last_id":"claude-opus-5-5"}"#)
        let page = try ProviderModelCatalog.parseAnthropicPage(body, title: "Anthropic")
        XCTAssertEqual(page.models, [ProviderModel(id: "claude-opus-5-5", name: "Claude Opus 5.5")])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.lastID, "claude-opus-5-5")
    }

    func testGoogleKeepsGeminiChatModels() throws {
        let body = json(#"""
        {"models":[
          {"name":"models/gemini-2.5-flash","displayName":"Gemini 2.5 Flash","supportedGenerationMethods":["generateContent","countTokens"]},
          {"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]},
          {"name":"models/gemini-embedding-001","supportedGenerationMethods":["embedContent"]}
        ],"nextPageToken":""}
        """#)
        let page = try ProviderModelCatalog.parseGooglePage(body, title: "Google")
        XCTAssertEqual(page.models, [ProviderModel(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash")])
        XCTAssertNil(page.nextPageToken, "An empty token means the last page")
    }

    func testUnreadableListsSayWhichProvider() {
        XCTAssertThrowsError(try ProviderModelCatalog.parseOpenAIStyle(json("<html>"), purpose: .speech, providerID: "groq", title: "Groq")) {
            XCTAssertEqual($0 as? ProviderModelCatalog.CatalogError, .unreadable("Groq"))
        }
    }
}
