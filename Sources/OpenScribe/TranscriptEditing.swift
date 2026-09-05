import Foundation

enum CleanupStrength: String, Codable, CaseIterable, Identifiable {
    case light, clear, concise
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var instruction: String {
        switch self {
        case .light: return "Fix punctuation and capitalization only. Keep the speaker's wording, repetitions and fillers. Do not apply a different tone."
        case .clear: return "Remove filler words, false starts and accidental repetition. Resolve explicit spoken corrections. Preserve all substantive details."
        case .concise: return "Remove fillers and tighten redundant phrasing. Preserve every fact, qualification, uncertainty, number and negation. Never summarize away details."
        }
    }
}

struct CorrectionRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var heard: String
    var replacement: String

    /// One pass over the original text: longest matches win and replacements never cascade.
    static func apply(to text: String, rules: [CorrectionRule]) -> String {
        var seen = Set<String>()
        let rules = rules.filter {
            !$0.heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            seen.insert($0.heard.lowercased()).inserted
        }.sorted { $0.heard.count > $1.heard.count }
        guard !rules.isEmpty else { return text }
        let patterns = rules.map { NSRegularExpression.escapedPattern(for: $0.heard) }
        // Unicode boundaries avoid replacing parts of names, words, or identifiers.
        let pattern = "(?<![\\p{L}\\p{N}_])(?:" + patterns.joined(separator: "|") + ")(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let original = text as NSString
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            let phrase = original.substring(with: match.range)
            if let rule = rules.first(where: { $0.heard.caseInsensitiveCompare(phrase) == .orderedSame }) {
                result.replaceCharacters(in: match.range, with: rule.replacement)
            }
        }
        return result as String
    }
}

enum TranscriptEditing {
    /// Short dictations retain all context. Long ones split near sentence/word boundaries.
    static func batches(_ text: String, limit: Int = 12_000) -> [String] {
        guard limit > 0 else { return [text] }
        var remaining = text[...]
        var result: [String] = []
        while remaining.count > limit {
            let end = remaining.index(remaining.startIndex, offsetBy: limit)
            let tailStart = remaining.index(remaining.startIndex, offsetBy: limit / 2)
            let tail = remaining[tailStart..<end]
            let sentence = tail.lastIndex(where: { ".!?\n".contains($0) })
            let boundary = sentence ?? tail.lastIndex(where: { $0.isWhitespace })
            let split = boundary.map { remaining.index(after: $0) } ?? end
            result.append(String(remaining[..<split]))
            remaining = remaining[split...]
        }
        if !remaining.isEmpty { result.append(String(remaining)) }
        return result
    }
}
