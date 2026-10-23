import Foundation
import SQLite3

// MARK: - Outils texte (mêmes règles que inference_daemon.py)

public enum FrenchText {
    /// Minuscules, sans diacritiques, apostrophes unifiées.
    public static func fold(_ text: String) -> String {
        text.replacingOccurrences(of: "’", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "fr_FR"))
            .lowercased()
    }

    /// Forme pliée sans espaces ni ponctuation : « Facil a beau » -> « facilabeau ».
    public static func compact(_ text: String) -> String {
        String(fold(text).unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }.map(Character.init))
    }

    private static let phoneticRules: [(NSRegularExpression, String)] = [
        ("eau", "o"), ("au", "o"), ("ph", "f"), ("qu", "k"), ("[cs]h", "S"), ("gn", "N"),
        ("ou", "U"), ("oi", "wa"), ("[ae]i", "e"), ("(er|ez|et)$", "e"),
        ("(ain|ein|in|im|un|um)(?![aeiouy])", "I"), ("(an|am|en|em)(?![aeiouy])", "A"),
        ("(on|om)(?![aeiouy])", "O"), ("gu(?=[eiy])", "g"), ("c(?=[eiy])", "s"), ("ck", "k"),
        ("[cq]", "k"), ("g(?=[eiy])", "j"), ("y", "i"), ("z", "s"), ("x", "ks"), ("h", ""),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    private static func phoneticWord(_ word: String) -> String {
        var s = compact(word)
        for (regex, template) in phoneticRules {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        if s.count > 1 { s = replace("[stdpx]+$", in: s, with: "") }
        if s.count > 1 { s = replace("e$", in: s, with: "") }
        return s
    }

    /// Clé phonétique française approximative, calculée mot par mot.
    public static func phonetic(_ text: String) -> String {
        let joined = Tokenizer.tokenize(text).filter(\.isWord).map { phoneticWord($0.text) }.joined()
        return replace("(.)\\1+", in: joined, with: "$1")
    }

    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// 1 = identiques, 0 = sans rapport.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(levenshtein(a, b)) / Double(longest)
    }

    /// Mots-outils et mots très courants : une correction qui n'aboutit qu'à eux est
    /// de la grammaire (« est » -> « et », « a » -> « à »), pas du vocabulaire à apprendre.
    public static let commonWords: Set<String> = [
        "a", "à", "ai", "as", "au", "aux", "avec", "avoir", "bien", "bon", "c", "ça", "ce", "ces", "cet", "cette",
        "ceux", "chez", "ci", "comme", "comment", "d", "dans", "de", "des", "deux", "dire", "dit", "doit", "donc",
        "dont", "du", "elle", "elles", "en", "encore", "entre", "es", "est", "et", "été", "être", "eu", "fait",
        "faire", "faut", "il", "ils", "j", "je", "jour", "juste", "l", "la", "là", "le", "les", "leur", "leurs",
        "lui", "m", "ma", "mais", "me", "même", "mes", "moi", "moins", "mon", "n", "ne", "ni", "non", "nos",
        "notre", "nous", "on", "ont", "ou", "où", "oui", "par", "pas", "peu", "peut", "plus", "pour", "pourquoi",
        "qu", "quand", "que", "quel", "quelle", "qui", "quoi", "s", "sa", "sans", "se", "ses", "si", "son", "sont",
        "sous", "sur", "ta", "te", "tes", "toi", "ton", "tous", "tout", "toute", "tu", "un", "une", "va", "vais",
        "vas", "vers", "voir", "vos", "votre", "vous", "y", "allo", "allô", "alors", "après", "avant", "très",
        "trop", "aussi", "déjà", "ici", "rien", "the", "and", "of", "to", "is", "it", "in", "on", "for",
    ].reduce(into: Set<String>()) { $0.insert(fold($1)) }
}

// MARK: - Découpage en mots

public struct TextToken: Equatable {
    public let text: String
    public let isWord: Bool
    public let range: Range<String.Index>
}

public enum Tokenizer {
    /// Mots (lettres/chiffres avec apostrophes et traits d'union internes),
    /// ponctuation isolée et retours à la ligne ; les espaces sont ignorés.
    public static func tokenize(_ text: String) -> [TextToken] {
        var tokens: [TextToken] = []
        var index = text.startIndex
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        while index < text.endIndex {
            let c = text[index]
            if isWordChar(c) {
                var end = text.index(after: index)
                while end < text.endIndex {
                    let next = text[end]
                    if isWordChar(next) {
                        end = text.index(after: end)
                    } else if "'’-".contains(next),
                              text.index(after: end) < text.endIndex,
                              isWordChar(text[text.index(after: end)]) {
                        end = text.index(after: end)
                    } else {
                        break
                    }
                }
                tokens.append(TextToken(text: String(text[index..<end]), isWord: true, range: index..<end))
                index = end
            } else if c.isNewline {
                let end = text.index(after: index)
                tokens.append(TextToken(text: "\n", isWord: false, range: index..<end))
                index = end
            } else if c.isWhitespace {
                index = text.index(after: index)
            } else {
                let end = text.index(after: index)
                tokens.append(TextToken(text: String(c), isWord: false, range: index..<end))
                index = end
            }
        }
        return tokens
    }
}

// MARK: - Extraction des corrections

public struct LearnedCorrection: Equatable {
    public let wrongVariant: String
    public let canonicalTerm: String
    public let contextHint: String
    public let appBundleID: String
}

/// Compare `Texte_Initial` et `Texte_Final_Corrigé` (alignement de séquences au niveau
/// des mots), isole les substitutions courtes et plausibles phonétiquement, et ignore
/// les phrases réécrites à plus de 60 %.
public struct DiffLearner {
    public var maxRewriteRatio = 0.6
    public var maxPhraseWords = 4
    public var minSimilarity = 0.6
    public var contextWords = 3
    public var maxAlignedTokens = 800

    public init() {}

    private enum Op { case equal(Int, Int), delete(Int), insert(Int) }

    private struct Hunk {
        var aRange: Range<Int>
        var bRange: Range<Int>
        /// Position d'insertion dans `a` quand `aRange` est vide.
        var anchor: Int
    }

    private static let sentenceEnders: Set<String> = [".", "!", "?", "…", "\n"]

    public func extract(initial: String, final: String, bundleID: String) -> [LearnedCorrection] {
        let a = Tokenizer.tokenize(initial)
        let b = Tokenizer.tokenize(final)
        guard !a.isEmpty, !b.isEmpty, initial != final else { return [] }

        let hunks = align(a, b)
        guard !hunks.isEmpty else { return [] }

        // Phrase de chaque mot initial et taux de changement par phrase.
        var sentenceOf = [Int](repeating: 0, count: a.count)
        var sentence = 0
        for (i, token) in a.enumerated() {
            sentenceOf[i] = sentence
            if Self.sentenceEnders.contains(token.text) { sentence += 1 }
        }
        var wordsPerSentence = [Int](repeating: 0, count: sentence + 1)
        for (i, token) in a.enumerated() where token.isWord { wordsPerSentence[sentenceOf[i]] += 1 }
        var changedPerSentence = [Int](repeating: 0, count: sentence + 1)
        for hunk in hunks {
            let target = hunkSentence(hunk, sentenceOf: sentenceOf)
            let deleted = a[hunk.aRange].filter(\.isWord).count
            let inserted = b[hunk.bRange].filter(\.isWord).count
            changedPerSentence[target] += max(deleted, inserted)
        }
        let totalWords = max(1, wordsPerSentence.reduce(0, +))
        if Double(changedPerSentence.reduce(0, +)) / Double(totalWords) > maxRewriteRatio { return [] }

        var results: [LearnedCorrection] = []
        for hunk in hunks where !hunk.aRange.isEmpty && !hunk.bRange.isEmpty {
            let target = hunkSentence(hunk, sentenceOf: sentenceOf)
            let ratio = Double(changedPerSentence[target]) / Double(max(1, wordsPerSentence[target]))
            if ratio > maxRewriteRatio { continue }

            let wrongTokens = a[hunk.aRange].filter(\.isWord)
            let canonTokens = b[hunk.bRange].filter(\.isWord)
            guard (1...maxPhraseWords).contains(wrongTokens.count),
                  (1...maxPhraseWords).contains(canonTokens.count),
                  let wrongFirst = wrongTokens.first, let wrongLast = wrongTokens.last,
                  let canonFirst = canonTokens.first, let canonLast = canonTokens.last
            else { continue }

            let (wrong, canonical) = Self.stripSharedElision(
                String(initial[wrongFirst.range.lowerBound..<wrongLast.range.upperBound]),
                String(final[canonFirst.range.lowerBound..<canonLast.range.upperBound])
            )
            guard !wrong.isEmpty, !canonical.isEmpty else { continue }
            let atSentenceStart = hunk.aRange.lowerBound == 0
                || Self.sentenceEnders.contains(a[hunk.aRange.lowerBound - 1].text)
            guard isPlausibleMisrecognition(wrong: wrong, canonical: canonical, atSentenceStart: atSentenceStart)
            else { continue }

            let correction = LearnedCorrection(
                wrongVariant: wrong,
                canonicalTerm: canonical,
                contextHint: contextHint(around: hunk.bRange, in: b),
                appBundleID: bundleID
            )
            if !results.contains(where: { $0.wrongVariant == wrong && $0.canonicalTerm == canonical }) {
                results.append(correction)
            }
        }
        return results
    }

    /// Vrai si `canonical` ressemble à une mauvaise reconnaissance de `wrong` :
    /// même suite de lettres (espaces, casse, accents) ou proximité orthographique /
    /// phonétique, et au moins un mot qui n'est pas un mot-outil.
    public func isPlausibleMisrecognition(wrong: String, canonical: String, atSentenceStart: Bool) -> Bool {
        guard wrong != canonical else { return false }
        let cw = FrenchText.compact(wrong)
        let cc = FrenchText.compact(canonical)
        guard !cw.isEmpty, !cc.isEmpty else { return false }

        if cw == cc {
            // Simple majuscule en début de phrase : de la typographie, pas du vocabulaire.
            if atSentenceStart, !wrong.contains(" "),
               canonical == wrong.prefix(1).uppercased() + wrong.dropFirst() {
                return false
            }
        } else {
            if Double(cc.count) > Double(cw.count) * 3 + 3 || Double(cw.count) > Double(cc.count) * 3 + 3 {
                return false
            }
            let orthographic = FrenchText.similarity(cw, cc)
            let phonetic = FrenchText.similarity(FrenchText.phonetic(wrong), FrenchText.phonetic(canonical))
            guard max(orthographic, phonetic) >= minSimilarity else { return false }
        }

        let canonicalWords = Tokenizer.tokenize(canonical).filter(\.isWord).map { FrenchText.fold($0.text) }
        return canonicalWords.contains { !FrenchText.commonWords.contains($0) }
    }

    /// « d'Allo » -> « d’Allauch » s'apprend comme « Allo » -> « Allauch ».
    static func stripSharedElision(_ wrong: String, _ canonical: String) -> (String, String) {
        let pattern = "^([A-Za-zÀ-ÿ]{1,3})['’]"
        guard let w = wrong.range(of: pattern, options: .regularExpression),
              let c = canonical.range(of: pattern, options: .regularExpression),
              FrenchText.fold(String(wrong[w])) == FrenchText.fold(String(canonical[c]))
        else { return (wrong, canonical) }
        return (String(wrong[w.upperBound...]), String(canonical[c.upperBound...]))
    }

    /// Les apostrophes droites et typographiques (substitution automatique) sont équivalentes.
    private static func key(_ token: TextToken) -> String {
        token.text.replacingOccurrences(of: "’", with: "'")
    }

    private func hunkSentence(_ hunk: Hunk, sentenceOf: [Int]) -> Int {
        if !hunk.aRange.isEmpty { return sentenceOf[hunk.aRange.lowerBound] }
        guard !sentenceOf.isEmpty else { return 0 }
        return sentenceOf[min(max(hunk.anchor - 1, 0), sentenceOf.count - 1)]
    }

    private func contextHint(around range: Range<Int>, in tokens: [TextToken]) -> String {
        let before = tokens[..<range.lowerBound].filter(\.isWord).suffix(contextWords).map(\.text)
        let after = tokens[range.upperBound...].filter(\.isWord).prefix(contextWords).map(\.text)
        return (before + ["…"] + after).joined(separator: " ")
    }

    /// LCS mot à mot après retrait du préfixe et du suffixe communs.
    private func align(_ a: [TextToken], _ b: [TextToken]) -> [Hunk] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, Self.key(a[prefix]) == Self.key(b[prefix]) { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              Self.key(a[a.count - 1 - suffix]) == Self.key(b[b.count - 1 - suffix]) { suffix += 1 }

        let aMid = Array(a[prefix..<(a.count - suffix)])
        let bMid = Array(b[prefix..<(b.count - suffix)])
        if aMid.isEmpty && bMid.isEmpty { return [] }
        if aMid.count > maxAlignedTokens || bMid.count > maxAlignedTokens {
            return [Hunk(aRange: prefix..<(a.count - suffix), bRange: prefix..<(b.count - suffix), anchor: prefix)]
        }

        let n = aMid.count, m = bMid.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    dp[i][j] = Self.key(aMid[i - 1]) == Self.key(bMid[j - 1])
                        ? dp[i - 1][j - 1] + 1
                        : max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        // Remontée depuis la fin : les mots identiques s'alignent le plus tard possible,
        // ce qui garde « facil a beau » groupé face à « FacilAbo ».
        var ops: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, Self.key(aMid[i - 1]) == Self.key(bMid[j - 1]) {
                ops.append(.equal(i - 1, j - 1)); i -= 1; j -= 1
            } else if i > 0, j == 0 || dp[i - 1][j] >= dp[i][j - 1] {
                ops.append(.delete(i - 1)); i -= 1
            } else {
                ops.append(.insert(j - 1)); j -= 1
            }
        }
        ops.reverse()

        var hunks: [Hunk] = []
        var current: Hunk?
        var aCursor = 0, bCursor = 0
        func flush() {
            if let hunk = current { hunks.append(hunk) }
            current = nil
        }
        for op in ops {
            switch op {
            case let .equal(ai, bj):
                flush()
                aCursor = ai + 1; bCursor = bj + 1
            case let .delete(ai):
                if current == nil { current = Hunk(aRange: ai..<ai, bRange: bCursor..<bCursor, anchor: ai) }
                current!.aRange = current!.aRange.lowerBound..<(ai + 1)
                aCursor = ai + 1
            case let .insert(bj):
                if current == nil { current = Hunk(aRange: aCursor..<aCursor, bRange: bj..<bj, anchor: aCursor) }
                current!.bRange = current!.bRange.lowerBound..<(bj + 1)
                bCursor = bj + 1
            }
        }
        flush()
        return hunks.map {
            Hunk(aRange: ($0.aRange.lowerBound + prefix)..<($0.aRange.upperBound + prefix),
                 bRange: ($0.bRange.lowerBound + prefix)..<($0.bRange.upperBound + prefix),
                 anchor: $0.anchor + prefix)
        }
    }
}

// MARK: - Persistance SQLite (~/.voxflow/lexicon.db)

public enum LexiconStoreError: Error, LocalizedError {
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case let .sqlite(message): return "SQLite : \(message)"
        }
    }
}

public struct LexiconRow: Equatable {
    public let id: Int64
    public let wrongVariant: String
    public let canonicalTerm: String
    public let frequency: Int
}

/// Base partagée avec le démon Python (qui la lit avant chaque nettoyage).
public final class LexiconStore {
    public static var defaultURL: URL {
        VoxFlowPaths.dataDirectory.appendingPathComponent("lexicon.db")
    }

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL = LexiconStore.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw LexiconStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_busy_timeout(db, 2000)
        try exec("PRAGMA journal_mode=WAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS lexicon (id INTEGER PRIMARY KEY, wrong_variant TEXT, canonical_term TEXT, \
            context_hint TEXT, app_bundle_id TEXT, frequency INTEGER DEFAULT 1, updated_at DATETIME);
            CREATE UNIQUE INDEX IF NOT EXISTS idx_lexicon_pair ON lexicon(wrong_variant COLLATE NOCASE, canonical_term);
            """)
    }

    deinit { sqlite3_close(db) }

    /// Ajoute la règle ou incrémente sa fréquence. Renvoie la fréquence obtenue.
    @discardableResult
    public func record(_ correction: LearnedCorrection) throws -> Int {
        try exec("BEGIN IMMEDIATE;")
        do {
            let update = try prepare("""
                UPDATE lexicon SET frequency = frequency + 1, context_hint = ?, app_bundle_id = ?, \
                updated_at = datetime('now') WHERE wrong_variant = ? COLLATE NOCASE AND canonical_term = ?;
                """)
            defer { sqlite3_finalize(update) }
            bind(update, [correction.contextHint, correction.appBundleID, correction.wrongVariant, correction.canonicalTerm])
            guard sqlite3_step(update) == SQLITE_DONE else { throw lastError() }

            if sqlite3_changes(db) == 0 {
                let insert = try prepare("""
                    INSERT INTO lexicon (wrong_variant, canonical_term, context_hint, app_bundle_id, frequency, updated_at) \
                    VALUES (?, ?, ?, ?, 1, datetime('now'));
                    """)
                defer { sqlite3_finalize(insert) }
                bind(insert, [correction.wrongVariant, correction.canonicalTerm, correction.contextHint, correction.appBundleID])
                guard sqlite3_step(insert) == SQLITE_DONE else { throw lastError() }
            }
            let frequency = try frequencyOf(correction)
            try exec("COMMIT;")
            return frequency
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    public func count() -> Int {
        guard let statement = try? prepare("SELECT COUNT(*) FROM lexicon;") else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    public func recent(limit: Int = 10) -> [LexiconRow] {
        guard let statement = try? prepare("""
            SELECT id, wrong_variant, canonical_term, frequency FROM lexicon ORDER BY updated_at DESC, id DESC LIMIT ?;
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var rows: [LexiconRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(LexiconRow(
                id: sqlite3_column_int64(statement, 0),
                wrongVariant: String(cString: sqlite3_column_text(statement, 1)),
                canonicalTerm: String(cString: sqlite3_column_text(statement, 2)),
                frequency: Int(sqlite3_column_int64(statement, 3))
            ))
        }
        return rows
    }

    public func delete(id: Int64) throws {
        let statement = try prepare("DELETE FROM lexicon WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func frequencyOf(_ correction: LearnedCorrection) throws -> Int {
        let statement = try prepare("""
            SELECT frequency FROM lexicon WHERE wrong_variant = ? COLLATE NOCASE AND canonical_term = ?;
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, [correction.wrongVariant, correction.canonicalTerm])
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    private func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "erreur inconnue"
            sqlite3_free(message)
            throw LexiconStoreError.sqlite(text)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        return statement
    }

    private func bind(_ statement: OpaquePointer?, _ values: [String]) {
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.transient)
        }
    }

    private func lastError() -> LexiconStoreError {
        .sqlite(String(cString: sqlite3_errmsg(db)))
    }
}
