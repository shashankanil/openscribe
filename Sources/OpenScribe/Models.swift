import AppKit
import Foundation

enum CapturePhase: String, Codable, CaseIterable {
    case idle
    case recording
    case transcribing
    case cleaning
    case ready
    case failed

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .cleaning: return "Polishing"
        case .ready: return "Ready"
        case .failed: return "Needs attention"
        }
    }
}

enum SpeechProvider: String, Codable, CaseIterable, Identifiable {
    case openRouter
    case openAI
    case groq
    case deepgram
    case assemblyAI
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .openAI: return "OpenAI"
        case .groq: return "Groq"
        case .deepgram: return "Deepgram"
        case .assemblyAI: return "AssemblyAI"
        case .custom: return "Custom OpenAI-compatible"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .deepgram: return "https://api.deepgram.com/v1"
        case .assemblyAI: return "https://api.assemblyai.com/v2"
        case .custom: return "https://example.com/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .openRouter: return "mistralai/voxtral-mini-transcribe"
        case .openAI: return "gpt-4o-mini-transcribe"
        case .groq: return "whisper-large-v3-turbo"
        case .deepgram: return "nova-3"
        case .assemblyAI: return "best"
        case .custom: return "whisper-1"
        }
    }
}

enum LanguageModelProvider: String, Codable, CaseIterable, Identifiable {
    case openRouter
    case openAI
    case anthropic
    case google
    case groq
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google Gemini"
        case .groq: return "Groq"
        case .custom: return "Custom"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .google: return "https://generativelanguage.googleapis.com"
        case .groq: return "https://api.groq.com/openai/v1"
        case .custom: return "https://example.com/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .openRouter: return "openai/gpt-5.6-luna"
        case .openAI: return "gpt-4o-mini"
        case .anthropic: return "claude-3-5-haiku-latest"
        case .google: return "gemini-2.0-flash"
        case .groq: return "llama-3.3-70b-versatile"
        case .custom: return "gpt-4o-mini"
        }
    }
}

enum WritingTone: String, Codable, CaseIterable, Identifiable {
    case natural
    case casual
    case formal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .natural: return "Natural"
        case .casual: return "Casual"
        case .formal: return "Formal"
        }
    }

    var instruction: String {
        switch self {
        case .natural: return "Keep the speaker's natural voice and directness."
        case .casual: return "Use a relaxed, conversational tone with contractions where they fit."
        case .formal: return "Use a polished, professional tone without sounding stiff."
        }
    }
}

enum DictationMode: String, Codable, CaseIterable, Identifiable {
    case toggle
    case holdToTalk
    var id: String { rawValue }
    var title: String {
        switch self {
        case .toggle: return "Toggle"
        case .holdToTalk: return "Hold to talk"
        }
    }
    var detail: String {
        switch self {
        case .toggle: return "Press once to start, press again to stop."
        case .holdToTalk: return "Hold to record, release to transcribe."
        }
    }
}
enum ShortcutFormatter {
    static let supportedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command, .function]

    static func display(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String? = nil) -> String {
        if keyCode == 63 {
            return "Globe"
        }
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        let key = characters.flatMap { $0.isEmpty ? nil : $0.uppercased() } ?? keyName(for: keyCode)
        return symbols.isEmpty ? key : "\(symbols) \(key)"
    }

    private static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 53: return "Escape"
        case 51: return "Delete"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 17: return "T"
        case 16: return "Y"
        case 32: return "U"
        case 34: return "I"
        case 31: return "O"
        case 35: return "P"
        case 63: return "Globe"
        default: return "Key \(keyCode)"
        }
    }
}


enum FlowThemeVariant: String, Codable, CaseIterable, Identifiable {
    case light
    case dark
    case whisperFlow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .whisperFlow: return "Whisperlight"
        }
    }

    var detail: String {
        switch self {
        case .light: return "A clean, bright workspace."
        case .dark: return "A low-glare graphite workspace."
        case .whisperFlow: return "Warm paper, lavender, and mint."
        }
    }

    var appearanceName: NSAppearance.Name {
        self == .dark ? .darkAqua : .aqua
    }
}

 
struct AppSettings: Codable, Equatable {
    var speechProvider: SpeechProvider = .openRouter
    var speechBaseURL: String = SpeechProvider.openRouter.defaultBaseURL
    var speechModel: String = SpeechProvider.openRouter.defaultModel

    var languageModelProvider: LanguageModelProvider = .openRouter
    var languageModelBaseURL: String = LanguageModelProvider.openRouter.defaultBaseURL
    var languageModel: String = LanguageModelProvider.openRouter.defaultModel

    var writingTone: WritingTone = .natural
    var customVocabulary: [String] = []

    var cleanupEnabled = true
    var pasteIntoFocusedApp = true
    var saveRawAudio = false
    var showOverlayWhenIdle = false
    var shortcutDisplay = "⌥ Space"
    var shortcutKeyCode: UInt16 = 49
    var shortcutModifiers: UInt = NSEvent.ModifierFlags.option.rawValue
    var overlayPosition = "bottom-center"
    var dictationMode: DictationMode = .toggle
    var theme: FlowThemeVariant = .whisperFlow

    private enum CodingKeys: String, CodingKey {
        case speechProvider, speechBaseURL, speechModel
        case languageModelProvider, languageModelBaseURL, languageModel
        case writingTone, customVocabulary
        case cleanupEnabled, pasteIntoFocusedApp, saveRawAudio
        case showOverlayWhenIdle, shortcutDisplay, shortcutKeyCode, shortcutModifiers, overlayPosition
        case dictationMode, theme
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSpeechProvider = try container.decodeIfPresent(SpeechProvider.self, forKey: .speechProvider) ?? .openRouter
        let decodedSpeechBaseURL = try container.decodeIfPresent(String.self, forKey: .speechBaseURL) ?? decodedSpeechProvider.defaultBaseURL
        let decodedSpeechModel = try container.decodeIfPresent(String.self, forKey: .speechModel) ?? decodedSpeechProvider.defaultModel
        if decodedSpeechProvider == .custom,
           decodedSpeechBaseURL == SpeechProvider.custom.defaultBaseURL,
           decodedSpeechModel == SpeechProvider.custom.defaultModel {
            speechProvider = .openRouter
            speechBaseURL = SpeechProvider.openRouter.defaultBaseURL
            speechModel = SpeechProvider.openRouter.defaultModel
        } else {
            speechProvider = decodedSpeechProvider
            speechBaseURL = decodedSpeechBaseURL
            speechModel = decodedSpeechModel
        }
        languageModelProvider = try container.decodeIfPresent(LanguageModelProvider.self, forKey: .languageModelProvider) ?? .openRouter
        languageModelBaseURL = try container.decodeIfPresent(String.self, forKey: .languageModelBaseURL) ?? languageModelProvider.defaultBaseURL
        writingTone = try container.decodeIfPresent(WritingTone.self, forKey: .writingTone) ?? .natural
        customVocabulary = try container.decodeIfPresent([String].self, forKey: .customVocabulary) ?? []
        languageModel = try container.decodeIfPresent(String.self, forKey: .languageModel) ?? languageModelProvider.defaultModel
        cleanupEnabled = try container.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? true
        pasteIntoFocusedApp = try container.decodeIfPresent(Bool.self, forKey: .pasteIntoFocusedApp) ?? true
        saveRawAudio = try container.decodeIfPresent(Bool.self, forKey: .saveRawAudio) ?? false
        showOverlayWhenIdle = try container.decodeIfPresent(Bool.self, forKey: .showOverlayWhenIdle) ?? false
        shortcutDisplay = try container.decodeIfPresent(String.self, forKey: .shortcutDisplay) ?? "⌥ Space"
        shortcutKeyCode = try container.decodeIfPresent(UInt16.self, forKey: .shortcutKeyCode) ?? 49
        shortcutModifiers = try container.decodeIfPresent(UInt.self, forKey: .shortcutModifiers) ?? NSEvent.ModifierFlags.option.rawValue
        overlayPosition = try container.decodeIfPresent(String.self, forKey: .overlayPosition) ?? "bottom-center"
        dictationMode = try container.decodeIfPresent(DictationMode.self, forKey: .dictationMode) ?? .toggle
        theme = try container.decodeIfPresent(FlowThemeVariant.self, forKey: .theme) ?? .whisperFlow
    }
}

struct VoiceNote: Identifiable, Codable, Hashable {
    var id = UUID()
    var createdAt = Date()
    var title: String
    var rawText: String
    var cleanedText: String
    var duration: TimeInterval
    var isPinned = false
    var tags: [String] = []
    var source = "Dictation"
    var sourceApplication: String?
    var sourceBundleIdentifier: String?

    var displayText: String {
        cleanedText.isEmpty ? rawText : cleanedText
    }

    var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }

    var timestampLabel: String {
        createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    var sourceLabel: String {
        if let sourceApplication, !sourceApplication.isEmpty {
            return sourceApplication
        }
        return source == "Dictation" ? "Active app unavailable" : source
    }
}

struct ProviderCredentialKeys {
    static let speech = "speech-api-key"
    static let languageModel = "language-model-api-key"
}
