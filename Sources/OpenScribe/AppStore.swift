import Combine
import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { persistSettings() }
    }
    @Published private(set) var notes: [VoiceNote] {
        didSet { persistNotes() }
    }

    private let rootURL: URL
    private let settingsURL: URL
    private let notesURL: URL

    init(rootURL overrideRootURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let appRoot = overrideRootURL ?? support.appendingPathComponent("WhisperFlow", isDirectory: true)
        rootURL = appRoot
        settingsURL = appRoot.appendingPathComponent("settings.json")
        notesURL = appRoot.appendingPathComponent("notes.json")
        let loadedSettings = AppStore.read(AppSettings.self, from: settingsURL)
        settings = loadedSettings ?? AppSettings()
        notes = AppStore.read([VoiceNote].self, from: notesURL) ?? []
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if let loadedSettings, loadedSettings != settings {
            Self.write(settings, to: settingsURL)
        } else if !FileManager.default.fileExists(atPath: settingsURL.path) {
            Self.write(settings, to: settingsURL)
        }
        if !FileManager.default.fileExists(atPath: notesURL.path) {
            Self.write(notes, to: notesURL)
        }
    }

    func updateSpeechProvider(_ provider: SpeechProvider) {
        settings.speechProvider = provider
        settings.speechBaseURL = provider.defaultBaseURL
        settings.speechModel = provider.defaultModel
    }

    func updateLanguageModelProvider(_ provider: LanguageModelProvider) {
        settings.languageModelProvider = provider
        settings.languageModelBaseURL = provider.defaultBaseURL
        settings.languageModel = provider.defaultModel
    }

    @discardableResult
    func addNote(
        rawText: String,
        cleanedText: String,
        duration: TimeInterval,
        source: String = "Dictation",
        sourceApplication: String? = nil,
        sourceBundleIdentifier: String? = nil
    ) -> VoiceNote {
        let text = cleanedText.isEmpty ? rawText : cleanedText
        let title = Self.makeTitle(from: text)
        let note = VoiceNote(
            title: title,
            rawText: rawText,
            cleanedText: cleanedText,
            duration: duration,
            source: source,
            sourceApplication: sourceApplication,
            sourceBundleIdentifier: sourceBundleIdentifier
        )
        notes.insert(note, at: 0)
        return note
    }

    func addManualNote() -> VoiceNote {
        let note = VoiceNote(title: "Untitled note", rawText: "", cleanedText: "", duration: 0, source: "Note")
        notes.insert(note, at: 0)
        return note
    }

    func updateNote(_ note: VoiceNote) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index] = note
    }

    func deleteNote(_ note: VoiceNote) {
        notes.removeAll { $0.id == note.id }
    }

    func togglePin(_ note: VoiceNote) {
        var updated = note
        updated.isPinned.toggle()
        updateNote(updated)
    }

    func note(withID id: UUID?) -> VoiceNote? {
        guard let id else { return nil }
        return notes.first(where: { $0.id == id })
    }

    func clearNotes() {
        notes.removeAll()
    }

    func flush() {
        persistSettings()
        persistNotes()
    }

    private func persistSettings() {
        Self.write(settings, to: settingsURL)
    }

    private func persistNotes() {
        Self.write(notes, to: notesURL)
    }

    private static func makeTitle(from text: String) -> String {
        let firstLine = text
            .split(whereSeparator: { $0 == "\n" || $0 == "." })
            .first
            .map(String.init) ?? "Voice note"
        let collapsed = firstLine.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if collapsed.isEmpty { return "Voice note" }
        return String(collapsed.prefix(56)) + (collapsed.count > 56 ? "…" : "")
    }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.whisperFlow.decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent())
            let data = try JSONEncoder.whisperFlow.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("OpenScribe persistence error: %@", error.localizedDescription)
        }
    }
}

private extension FileManager {
    func createDirectory(at url: URL) throws {
        try createDirectory(at: url, withIntermediateDirectories: true)
    }
}

private extension JSONEncoder {
    static var whisperFlow: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var whisperFlow: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
