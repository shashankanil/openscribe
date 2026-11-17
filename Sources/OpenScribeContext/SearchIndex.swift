import Foundation

/// Local relevance ranking: BM25-style term scoring per field with field weights,
/// prefix matching, coverage and phrase bonuses, and a small recency boost.
/// Matching is case-, diacritic- and width-insensitive.
public struct SearchIndex: Sendable {
    public struct Hit: Equatable, Sendable {
        public var id: String
        public var kind: ContextDocument.Kind
        public var title: String
        public var createdAt: Date
        public var snippet: String
        public var score: Double
    }

    struct Token: Sendable {
        var term: String
        var range: Range<String.Index>
    }

    enum Field: Int, CaseIterable, Sendable {
        case title, tags, actionItems, summary, body, transcript, extra

        var weight: Double {
            switch self {
            case .title: return 4
            case .tags: return 2.5
            case .actionItems: return 2
            case .summary: return 1.8
            case .body: return 1.3
            case .transcript: return 1
            case .extra: return 0.6
            }
        }
    }

    struct IndexedField: Sendable {
        var text: String
        var tokens: [Token]
        var positions: [String: [Int]]
    }

    struct Entry: Sendable {
        var document: ContextDocument
        var fields: [IndexedField] // indexed by Field.rawValue
        var vocabulary: Set<String>
    }

    let entries: [Entry]
    let averageLength: [Double]

    public init(library: ContextLibrary) {
        let built: [Entry] = library.documents.filter { !$0.deleted }.map { document in
            let texts: [String] = [
                document.title,
                document.tags.joined(separator: "\n"),
                document.actionItems.joined(separator: "\n"),
                document.summary ?? "",
                document.body,
                document.transcript ?? "",
                library.searchExtras[document.id] ?? "",
            ]
            let fields = texts.map { text -> IndexedField in
                let tokens = Self.tokenize(text)
                var positions: [String: [Int]] = [:]
                for (offset, token) in tokens.enumerated() { positions[token.term, default: []].append(offset) }
                return IndexedField(text: text, tokens: tokens, positions: positions)
            }
            var vocabulary = Set<String>()
            for field in fields { vocabulary.formUnion(field.positions.keys) }
            return Entry(document: document, fields: fields, vocabulary: vocabulary)
        }
        entries = built
        averageLength = Field.allCases.map { field in
            let lengths = built.map { Double($0.fields[field.rawValue].tokens.count) }
            return max(1, lengths.reduce(0, +) / Double(max(1, lengths.count)))
        }
    }

    // MARK: Tokenizing

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let isWordCharacter = character.isLetter || character.isNumber
            if isWordCharacter {
                if start == nil { start = index }
            } else if let begin = start {
                tokens.append(Token(term: fold(String(text[begin..<index])), range: begin..<index))
                start = nil
            }
            index = text.index(after: index)
        }
        if let begin = start {
            tokens.append(Token(term: fold(String(text[begin..<text.endIndex])), range: begin..<text.endIndex))
        }
        return tokens
    }

    static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is", "it", "of", "on", "or",
        "that", "the", "to", "was", "were", "with", "what", "when", "where", "who", "did", "do", "my", "i", "we", "about",
    ]

    static func queryTerms(_ query: String) -> [String] {
        var seen = Set<String>()
        let all = tokenize(query).map(\.term).filter { seen.insert($0).inserted }
        let meaningful = all.filter { !stopwords.contains($0) }
        return meaningful.isEmpty ? all : meaningful
    }

    // MARK: Searching

    public func search(_ query: String, kind: ContextDocument.Kind? = nil, limit: Int = 10, now: Date = Date()) -> [Hit] {
        let terms = Self.queryTerms(query)
        let phrase = Self.tokenize(query).map(\.term)
        guard !terms.isEmpty else { return [] }
        let candidates = entries.filter { kind == nil || $0.document.kind == kind }

        // Expanded vocabulary per query term: exact match weight 1, prefix match (term ≥ 3 chars) weight 0.5.
        func expansions(_ term: String, in entry: Entry) -> [(String, Double)] {
            var result: [(String, Double)] = entry.vocabulary.contains(term) ? [(term, 1)] : []
            if term.count >= 3 {
                for word in entry.vocabulary where word.count > term.count && word.hasPrefix(term) { result.append((word, 0.5)) }
            }
            return result
        }

        let total = Double(max(1, candidates.count))
        var expansionsByEntry: [[[(String, Double)]]] = []
        var documentFrequency = [Double](repeating: 0, count: terms.count)
        for entry in candidates {
            let perTerm = terms.map { expansions($0, in: entry) }
            for (offset, list) in perTerm.enumerated() where !list.isEmpty { documentFrequency[offset] += 1 }
            expansionsByEntry.append(perTerm)
        }
        let idf = documentFrequency.map { log(1 + (total - $0 + 0.5) / ($0 + 0.5)) }

        var scored: [(entry: Int, score: Double, fieldScores: [Double])] = []
        for (entryOffset, entry) in candidates.enumerated() {
            let perTerm = expansionsByEntry[entryOffset]
            var score = 0.0
            var matched = 0
            var fieldScores = [Double](repeating: 0, count: Field.allCases.count)
            for (termOffset, list) in perTerm.enumerated() where !list.isEmpty {
                matched += 1
                for field in Field.allCases {
                    let indexed = entry.fields[field.rawValue]
                    var frequency = 0.0
                    for (word, weight) in list { frequency += Double(indexed.positions[word]?.count ?? 0) * weight }
                    guard frequency > 0 else { continue }
                    let length = Double(indexed.tokens.count)
                    let k = 1.2, b = 0.75
                    let saturated = frequency * (k + 1) / (frequency + k * (1 - b + b * length / averageLength[field.rawValue]))
                    let contribution = field.weight * saturated * idf[termOffset]
                    score += contribution
                    fieldScores[field.rawValue] += contribution
                }
            }
            guard matched > 0 else { continue }
            let coverage = Double(matched) / Double(terms.count)
            score *= 0.25 + 0.75 * coverage * coverage

            // Phrase bonus: the whole query appears as consecutive tokens.
            if phrase.count >= 2 {
                let meanIDF = idf.reduce(0, +) / Double(max(1, idf.count))
                for field in Field.allCases where Self.containsPhrase(phrase, in: entry.fields[field.rawValue]) {
                    let bonus = 1.5 * field.weight * meanIDF
                    score += bonus
                    fieldScores[field.rawValue] += bonus
                }
            }
            // Exact title match.
            let titleTerms = entry.fields[Field.title.rawValue].tokens.map(\.term)
            if !titleTerms.isEmpty && titleTerms == phrase { score *= 1.5 }

            // Recency: up to +15% for brand-new documents, decaying over ~30 days.
            let ageDays = max(0, now.timeIntervalSince(entry.document.updatedAt) / 86_400)
            score *= 1 + 0.15 * exp(-ageDays / 30)

            scored.append((entryOffset, score, fieldScores))
        }

        scored.sort { lhs, rhs in
            if abs(lhs.score - rhs.score) > 1e-9 { return lhs.score > rhs.score }
            let left = candidates[lhs.entry].document, right = candidates[rhs.entry].document
            return left.updatedAt == right.updatedAt ? left.id < right.id : left.updatedAt > right.updatedAt
        }
        return scored.prefix(max(1, limit)).map { item in
            let entry = candidates[item.entry]
            let words = Set(expansionsByEntry[item.entry].flatMap { $0.map(\.0) })
            return Hit(id: entry.document.id, kind: entry.document.kind, title: entry.document.title,
                       createdAt: entry.document.createdAt,
                       snippet: Self.snippet(for: entry, words: words, fieldScores: item.fieldScores),
                       score: item.score)
        }
    }

    static func containsPhrase(_ phrase: [String], in field: IndexedField) -> Bool {
        guard let first = phrase.first, let starts = field.positions[first], field.tokens.count >= phrase.count else { return false }
        return starts.contains { start in
            start + phrase.count <= field.tokens.count
                && phrase.indices.allSatisfy { field.tokens[start + $0].term == phrase[$0] }
        }
    }

    // MARK: Snippets

    static let snippetLength = 240

    /// A ~240-character excerpt around the densest cluster of matched words, from the best-scoring
    /// non-title field. Falls back to the start of the summary, body or transcript.
    static func snippet(for entry: Entry, words: Set<String>, fieldScores: [Double]) -> String {
        let order: [Field] = [.summary, .body, .transcript, .actionItems, .extra, .tags]
        let ranked = order.filter { fieldScores[$0.rawValue] > 0 }.sorted { fieldScores[$0.rawValue] > fieldScores[$1.rawValue] }
        for field in ranked {
            let indexed = entry.fields[field.rawValue]
            let matches = indexed.tokens.indices.filter { words.contains(indexed.tokens[$0].term) }
            guard !matches.isEmpty else { continue }
            // Sliding window (≤ 30 tokens) maximizing distinct matched words.
            var best = (start: matches[0], end: matches[0], distinct: 0)
            var lower = 0
            for upper in matches.indices {
                while indexed.tokens.distance(from: matches[lower], to: matches[upper]) > 30 { lower += 1 }
                let distinct = Set(matches[lower...upper].map { indexed.tokens[$0].term }).count
                if distinct > best.distinct { best = (matches[lower], matches[upper], distinct) }
            }
            let text = indexed.text
            let matchStart = indexed.tokens[best.start].range.lowerBound
            let matchEnd = indexed.tokens[best.end].range.upperBound
            let lead = 70
            var start = text.index(matchStart, offsetBy: -lead, limitedBy: text.startIndex) ?? text.startIndex
            if start > text.startIndex, let space = text[start..<matchStart].firstIndex(where: \.isWhitespace) {
                start = text.index(after: space)
            }
            let budget = max(snippetLength, text.distance(from: start, to: matchEnd) + 20)
            var end = text.index(start, offsetBy: budget, limitedBy: text.endIndex) ?? text.endIndex
            if end < text.endIndex, let space = text[matchEnd..<end].lastIndex(where: \.isWhitespace) { end = space }
            return clean(String(text[start..<end]), leading: start > text.startIndex, trailing: end < text.endIndex)
        }
        let document = entry.document
        let fallback = [document.summary ?? "", document.body, document.transcript ?? ""].first { !$0.isEmpty } ?? ""
        return excerpt(fallback, length: snippetLength)
    }

    /// The first `length` characters, cut at a word boundary, with whitespace collapsed.
    public static func excerpt(_ text: String, length: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).filter { !$0.allSatisfy { $0 == "#" } }.joined(separator: " ")
        guard collapsed.count > length else { return collapsed }
        var cut = collapsed.index(collapsed.startIndex, offsetBy: length)
        if let space = collapsed[..<cut].lastIndex(of: " ") { cut = space }
        return String(collapsed[..<cut]) + "…"
    }

    private static func clean(_ text: String, leading: Bool, trailing: Bool) -> String {
        // Collapse whitespace and drop markdown heading markers ("###") that the day-note timeline uses.
        let collapsed = text.split(whereSeparator: \.isWhitespace).filter { !$0.allSatisfy { $0 == "#" } }.joined(separator: " ")
        return (leading ? "…" : "") + collapsed + (trailing ? "…" : "")
    }
}
