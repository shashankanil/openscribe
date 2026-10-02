import Combine
import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { if !settingsAlreadyPersisted { persistSettings() } }
    }
    @Published private(set) var notes: [VoiceNote] {
        didSet { persistNotes() }
    }
    @Published private(set) var storageError: String?

    private let rootURL: URL
    private let settingsURL: URL
    private let notesURL: URL
    private var blockedFiles = Set<URL>()
    private var loadNotices: [String] = []
    private var writeFailures: [URL: String] = [:]
    private var lastNotesWriteSucceeded = true
    private var settingsAlreadyPersisted = false

    init(rootURL overrideRootURL: URL? = nil) {
        let appRoot = overrideRootURL ?? AppPaths.root
        rootURL = appRoot
        settingsURL = appRoot.appendingPathComponent("settings.json")
        notesURL = appRoot.appendingPathComponent("notes.json")
        let loadedSettings = Self.load(AppSettings.self, from: settingsURL)
        let loadedNotes = Self.load([VoiceNote].self, from: notesURL)
        settings = loadedSettings.value ?? AppSettings()
        notes = loadedNotes.value ?? []
        for (url, result) in [(settingsURL, (loadedSettings.notice, loadedSettings.blocked)),
                              (notesURL, (loadedNotes.notice, loadedNotes.blocked))] {
            if let notice = result.0 { loadNotices.append(notice) }
            if result.1 { blockedFiles.insert(url) }
        }
        storageError = loadNotices.isEmpty ? nil : loadNotices.joined(separator: "\n\n")
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: settingsURL.path) { persistSettings() }
        if !FileManager.default.fileExists(atPath: notesURL.path) {
            persistNotes()
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

    /// A connection becomes active only after its configuration reaches disk.
    func saveSettings(_ updated: AppSettings) -> Bool {
        guard persist(updated, to: settingsURL) else { return false }
        settingsAlreadyPersisted = true
        settings = updated
        settingsAlreadyPersisted = false
        return true
    }

    @discardableResult
    func addNote(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        rawText: String,
        cleanedText: String,
        duration: TimeInterval,
        source: String = "Dictation",
        sourceApplication: String? = nil,
        sourceBundleIdentifier: String? = nil
    ) -> VoiceNote {
        let text = cleanedText.isEmpty ? rawText : cleanedText
        let title = Self.makeTitle(from: text)
        let existing = notes.first { $0.id == id }
        var note = VoiceNote(
            id: id,
            createdAt: existing?.createdAt ?? createdAt,
            title: title,
            rawText: rawText,
            cleanedText: cleanedText,
            duration: duration,
            source: source,
            sourceApplication: sourceApplication,
            sourceBundleIdentifier: sourceBundleIdentifier
        )
        note.isPinned = existing?.isPinned ?? false
        note.tags = existing?.tags ?? []
        if let index = notes.firstIndex(where: { $0.id == id }) { notes[index] = note }
        else { notes.insert(note, at: 0) }
        return note
    }

    func addManualNote() -> VoiceNote {
        // Creating an editor is not a history entry. Save once the draft contains something.
        VoiceNote(title: "", rawText: "", cleanedText: "", duration: 0, source: "Note")
    }

    @discardableResult
    func updateNote(_ note: VoiceNote) -> Bool {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            guard note.source == "Note", note.hasContent else { return false }
            notes.insert(note, at: 0)
        }
        return lastNotesWriteSucceeded
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

    func hasPersistedNote(_ id: UUID) -> Bool {
        Self.read([VoiceNote].self, from: notesURL)?.contains { $0.id == id } ?? false
    }

    func flush() {
        persistSettings()
        persistNotes()
    }

    private func persistSettings() {
        persist(settings, to: settingsURL)
    }

    private func persistNotes() {
        lastNotesWriteSucceeded = persist(notes, to: notesURL)
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

    /// Preserve unreadable data before allowing a fresh history to be saved over it.
    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> (value: T?, notice: String?, blocked: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil, false) }
        do {
            let data = try Data(contentsOf: url)
            do { return (try JSONDecoder.whisperFlow.decode(type, from: data), nil, false) }
            catch {
                let backup = url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-unreadable-\(UUID().uuidString).json")
                try data.write(to: backup, options: .atomic)
                return (nil, "Could not load \(url.lastPathComponent). The original file was preserved as \(backup.lastPathComponent). New changes will use a fresh file.", false)
            }
        } catch {
            return (nil, "Could not read or back up \(url.lastPathComponent). Saving to that file is blocked to protect your data.\n\n\(error.localizedDescription)", true)
        }
    }

    @discardableResult
    private func persist<T: Encodable>(_ value: T, to url: URL) -> Bool {
        guard !blockedFiles.contains(url) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent())
            let data = try JSONEncoder.whisperFlow.encode(value)
            try data.write(to: url, options: .atomic)
            writeFailures.removeValue(forKey: url)
            refreshStorageError()
            return true
        } catch {
            NSLog("OpenScribe persistence error: %@", error.localizedDescription)
            writeFailures[url] = "Could not save \(url.lastPathComponent). Your changes are only in memory.\n\n\(error.localizedDescription)"
            refreshStorageError()
            return false
        }
    }

    private func refreshStorageError() {
        let messages = loadNotices + writeFailures.keys.sorted(by: { $0.path < $1.path }).compactMap { writeFailures[$0] }
        let next = messages.isEmpty ? nil : messages.joined(separator: "\n\n")
        if storageError != next { storageError = next }
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
