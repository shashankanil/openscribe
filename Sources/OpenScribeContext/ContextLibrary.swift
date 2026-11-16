import Foundation

/// Read-only view of an OpenScribe profile as normalized `ContextDocument`s.
public struct ContextLibrary: Sendable {
    /// Extra per-meeting facts that are not part of the normalized document.
    public struct MeetingInfo: Equatable, Sendable {
        public var status: String
    }

    public let root: URL
    /// All documents, newest first (by `createdAt`).
    public let documents: [ContextDocument]
    public let meetingInfo: [String: MeetingInfo]
    /// Text that is searchable but not part of the document body (e.g. text recognized in screenshots).
    public let searchExtras: [String: String]
    /// Problems encountered while loading (unreadable files). Never fatal.
    public let warnings: [String]

    public init(root: URL, documents: [ContextDocument], meetingInfo: [String: MeetingInfo] = [:],
                searchExtras: [String: String] = [:], warnings: [String] = []) {
        self.root = root
        self.documents = documents.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
        self.meetingInfo = meetingInfo
        self.searchExtras = searchExtras
        self.warnings = warnings
    }

    /// The profile root: `$OPENSCRIBE_DATA_DIR` if set, else `~/Library/Application Support/WhisperFlow`.
    public static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["OPENSCRIBE_DATA_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("WhisperFlow", isDirectory: true)
    }

    /// Loads every note and meeting under `root`. Missing files yield an empty library; unreadable
    /// files are skipped and reported in `warnings`.
    public static func load(root: URL) -> ContextLibrary {
        ContextLibraryCache(root: root).library()
    }

    public func document(id: String) -> ContextDocument? {
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return documents.first { $0.id == wanted } ?? documents.first { $0.id.caseInsensitiveCompare(wanted) == .orderedSame }
    }
}

/// Reloads the profile from disk on demand, re-parsing only files whose modification date or size changed.
/// Not thread-safe; use from one thread (the stdio server is single-threaded).
public final class ContextLibraryCache {
    public let root: URL

    private struct Stamp: Equatable {
        var modified: Date
        var size: Int
    }

    private struct NotesEntry {
        var stamp: Stamp
        var documents: [ContextDocument]
        var extras: [String: String]
        var warning: String?
    }

    private struct MeetingEntry {
        var stamp: Stamp
        var document: ContextDocument?
        var status: String
        var warning: String?
    }

    private var notes: NotesEntry?
    private var meetings: [String: MeetingEntry] = [:]
    private var lastLibrary: ContextLibrary?
    private var lastSignature: [String: Stamp] = [:]
    private var lastIndex: SearchIndex?

    public init(root: URL) {
        self.root = root
    }

    public func library() -> ContextLibrary {
        let fm = FileManager.default
        var signature: [String: Stamp] = [:]
        var warnings: [String] = []

        // Notes
        let notesURL = root.appendingPathComponent("notes.json")
        var noteDocuments: [ContextDocument] = []
        var extras: [String: String] = [:]
        if let stamp = Self.stamp(notesURL) {
            signature[notesURL.path] = stamp
            if notes?.stamp != stamp {
                notes = Self.loadNotes(notesURL, stamp: stamp)
            }
            noteDocuments = notes?.documents ?? []
            extras = notes?.extras ?? [:]
            if let warning = notes?.warning { warnings.append(warning) }
        } else {
            notes = nil
        }

        // Meetings
        let meetingsRoot = root.appendingPathComponent("Meetings", isDirectory: true)
        var seen = Set<String>()
        var meetingDocuments: [ContextDocument] = []
        var info: [String: ContextLibrary.MeetingInfo] = [:]
        let directories = (try? fm.contentsOfDirectory(at: meetingsRoot, includingPropertiesForKeys: nil)) ?? []
        for directory in directories {
            guard let uuid = UUID(uuidString: directory.lastPathComponent) else { continue }
            let url = directory.appendingPathComponent("meeting.json")
            guard let stamp = Self.stamp(url) else { continue }
            let key = uuid.uuidString
            seen.insert(key)
            signature[url.path] = stamp
            if meetings[key]?.stamp != stamp {
                meetings[key] = Self.loadMeeting(url, directoryID: key, stamp: stamp)
            }
            guard let entry = meetings[key] else { continue }
            if let warning = entry.warning { warnings.append(warning) }
            if let document = entry.document {
                meetingDocuments.append(document)
                info[document.id] = .init(status: entry.status)
            }
        }
        meetings = meetings.filter { seen.contains($0.key) }

        if let lastLibrary, signature == lastSignature { return lastLibrary }
        let library = ContextLibrary(root: root, documents: noteDocuments + meetingDocuments, meetingInfo: info,
                                     searchExtras: extras, warnings: warnings)
        lastLibrary = library
        lastSignature = signature
        lastIndex = nil
        return library
    }

    /// The library plus a search index, rebuilt only when files changed.
    public func snapshot() -> (library: ContextLibrary, index: SearchIndex) {
        let library = library()
        if let lastIndex { return (library, lastIndex) }
        let index = SearchIndex(library: library)
        lastIndex = index
        return (library, index)
    }

    private static func stamp(_ url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) != .typeDirectory else { return nil }
        return Stamp(modified: attributes[.modificationDate] as? Date ?? .distantPast,
                     size: (attributes[.size] as? NSNumber)?.intValue ?? 0)
    }

    private static func loadNotes(_ url: URL, stamp: Stamp) -> NotesEntry {
        do {
            let data = try Data(contentsOf: url)
            let notes = try JSONDecoder().decode(LossyArray<StoredNote>.self, from: data).elements
            var documents: [ContextDocument] = []
            var extras: [String: String] = [:]
            for note in notes {
                guard let normalized = ContextNormalizer.document(for: note, fallbackDate: stamp.modified) else { continue }
                documents.append(normalized.document)
                if !normalized.searchExtra.isEmpty { extras[normalized.document.id] = normalized.searchExtra }
            }
            return NotesEntry(stamp: stamp, documents: documents, extras: extras, warning: nil)
        } catch {
            return NotesEntry(stamp: stamp, documents: [], extras: [:],
                              warning: "Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func loadMeeting(_ url: URL, directoryID: String, stamp: Stamp) -> MeetingEntry {
        do {
            let meeting = try JSONDecoder().decode(StoredMeeting.self, from: Data(contentsOf: url))
            // The app ignores a meeting whose id does not match its folder; do the same.
            if let id = meeting.id, id.caseInsensitiveCompare(directoryID) != .orderedSame {
                return MeetingEntry(stamp: stamp, document: nil, status: meeting.status,
                                    warning: "Skipped Meetings/\(directoryID): id does not match folder")
            }
            let document = ContextNormalizer.document(for: meeting, id: directoryID, modified: stamp.modified)
            return MeetingEntry(stamp: stamp, document: document, status: meeting.status, warning: nil)
        } catch {
            return MeetingEntry(stamp: stamp, document: nil, status: "",
                                warning: "Could not read Meetings/\(directoryID)/meeting.json: \(error.localizedDescription)")
        }
    }
}
