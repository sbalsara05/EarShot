import Foundation

public struct DoseRef: Codable, Equatable, Sendable { public var amount: String; public var unit: String; public var route: String }

public struct Drug: Codable, Equatable, Sendable {
    public var generic: String
    public var `class`: String
    public var rxcui: String?
    public var brands: [String]
    public var slang: [String]
    public var aliases: [String]
    public var asr_variants: [String]
    public var phonetic: [String]
    public var typical_doses: [DoseRef]
    public var routes: [String]
    public var high_alert: Bool
}

public struct VocabEntry: Codable, Equatable, Sendable {
    public var spoken: [String]
    public var nemsis_code: String
    public var nemsis_label: String?
}

public struct FormularyFile: Codable, Sendable {
    public var version: String
    public var context_required_aliases: [String]?
    public var drugs: [Drug]
    public var home_meds: [String]?
    public var routes: [String: VocabEntry]
    public var units: [String: VocabEntry]
}

public struct EMSTerm: Codable, Equatable, Sendable { public var term: String; public var expansion: String; public var category: String }
public struct EMSTermsFile: Codable, Sendable {
    public var version: String
    public var terms: [EMSTerm]
    public var initial_prompt_core: [String]
    public var initial_prompt: String?
}

/// Loaded EMS dictionary with lookup indexes. Immutable after load.
public final class EMSDictionary: @unchecked Sendable {
    public let formulary: FormularyFile
    public let terms: EMSTermsFile
    public let version: String

    /// normalized alias (space separated tokens) -> drug index
    public private(set) var aliasIndex: [String: Int] = [:]
    /// asr variant -> drug index
    public private(set) var variantIndex: [String: Int] = [:]
    /// phonetic key (single word) -> drug indices
    public private(set) var phoneticIndex: [String: [Int]] = [:]
    public private(set) var contextRequired: Set<String> = []
    /// spoken unit form (tokens) -> canonical unit
    public private(set) var unitIndex: [String: String] = [:]
    /// spoken route form (tokens) -> canonical route
    public private(set) var routeIndex: [String: String] = [:]
    public private(set) var termIndex: [String: EMSTerm] = [:]
    public private(set) var maxAliasTokens = 1
    /// Patient home medications (not EMS-given), normalized.
    public private(set) var homeMeds: Set<String> = []

    public init(formulary: FormularyFile, terms: EMSTermsFile) {
        self.formulary = formulary
        self.terms = terms
        self.version = "formulary-\(formulary.version)+terms-\(terms.version)"
        for (i, d) in formulary.drugs.enumerated() {
            for a in d.aliases + [d.generic] + d.slang {
                let k = Text.normalizePhrase(a)
                if aliasIndex[k] == nil { aliasIndex[k] = i }
                maxAliasTokens = max(maxAliasTokens, k.split(separator: " ").count)
            }
            for v in d.asr_variants {
                let k = Text.normalizePhrase(v)
                if aliasIndex[k] == nil && variantIndex[k] == nil { variantIndex[k] = i }
                maxAliasTokens = max(maxAliasTokens, k.split(separator: " ").count)
            }
            for a in [d.generic] + d.slang + d.brands where !a.contains(" ") && a.count >= 5 {
                let key = Phonetic.key(a)
                if key.count >= 3 { phoneticIndex[key, default: []].append(i) }
            }
        }
        for k in phoneticIndex.keys { phoneticIndex[k] = Array(Set(phoneticIndex[k]!)).sorted() }
        homeMeds = Set((formulary.home_meds ?? []).map(Text.normalizePhrase))
        contextRequired = Set((formulary.context_required_aliases ?? []).map(Text.normalizePhrase))
        for (u, e) in formulary.units.sorted(by: { $0.key < $1.key }) { for s in e.spoken where unitIndex[Text.normalizePhrase(s)] == nil { unitIndex[Text.normalizePhrase(s)] = u } }
        for (r, e) in formulary.routes.sorted(by: { $0.key < $1.key }) { for s in e.spoken where routeIndex[Text.normalizePhrase(s)] == nil { routeIndex[Text.normalizePhrase(s)] = r } }
        for t in terms.terms { termIndex[Text.normalizePhrase(t.term)] = t }
    }

    public convenience init(directory: URL) throws {
        let f = try JSONDecoder().decode(FormularyFile.self, from: Data(contentsOf: directory.appendingPathComponent("formulary.json")))
        let t = try JSONDecoder().decode(EMSTermsFile.self, from: Data(contentsOf: directory.appendingPathComponent("ems_terms.json")))
        self.init(formulary: f, terms: t)
    }

    /// Locate /shared by walking up from `start` (CLI convenience).
    public static func findSharedDirectory(from start: URL) -> URL? {
        var u = start.standardizedFileURL
        for _ in 0..<8 {
            let c = u.appendingPathComponent("shared/formulary.json")
            if FileManager.default.fileExists(atPath: c.path) { return u.appendingPathComponent("shared") }
            u.deleteLastPathComponent()
        }
        return nil
    }

    public func drug(_ i: Int) -> Drug { formulary.drugs[i] }
    public func drug(named generic: String) -> Drug? { formulary.drugs.first { $0.generic == generic } }

    /// whisper.cpp initial prompt: the core list plus the most-spoken drug
    /// names. Kept under ~200 tokens (whisper uses at most n_text_ctx/2).
    public func initialPrompt(maxChars: Int = 600) -> String {
        if let p = terms.initial_prompt, !p.isEmpty { return p }   // sentence-style prompt (preferred)
        var words = terms.initial_prompt_core
        for d in formulary.drugs.prefix(40) {
            if let s = d.slang.first, s.count > 3 { words.append(s) }
        }
        var out = ""
        for w in words where !out.lowercased().contains(w.lowercased()) {
            if out.count + w.count + 2 > maxChars { break }
            out += out.isEmpty ? w : ", " + w
        }
        return out + "."
    }
}

// MARK: - Text helpers

public enum Text {
    /// Lowercase, strip punctuation except / . % & - inside tokens, collapse spaces.
    public static func normalizePhrase(_ s: String) -> String {
        tokenize(s).map(\.norm).joined(separator: " ")
    }

    public struct Token: Equatable, Sendable {
        public var raw: String
        public var norm: String
        public var range: Range<Int>   // character offsets in source
    }

    /// Whitespace tokenization; `norm` is lowercased with edge punctuation
    /// removed. Hyphens split words ("a-fib" -> "a", "fib") except inside
    /// numbers.
    public static func tokenize(_ s: String) -> [Token] {
        var out: [Token] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            while i < chars.count && (chars[i].isWhitespace || isSplitter(chars, i)) { i += 1 }
            let start = i
            while i < chars.count && !chars[i].isWhitespace && !isSplitter(chars, i) { i += 1 }
            if i > start {
                // a clause comma/semicolon right after the word belongs to it (so cleanup sees the boundary)
                if i < chars.count && (chars[i] == "," || chars[i] == ";") { i += 1 }
                let raw = String(chars[start..<i])
                var norm = raw.lowercased()
                // strip edge punctuation
                let edge: Set<Character> = [",", ".", "?", "!", ";", ":", "\"", "'", "(", ")", "[", "]", "…", "“", "”", "‘", "’"]
                while let f = norm.first, edge.contains(f) { norm.removeFirst() }
                while let l = norm.last, edge.contains(l) { norm.removeLast() }
                norm = norm.replacingOccurrences(of: "’", with: "'")
                // possessive 's is dropped ("zofran's"), contractions are kept ("she's on", "it's actually")
                if norm.hasSuffix("'s") && norm.count > 3 && !Text.contractions.contains(norm) { norm.removeLast(2) }
                if !norm.isEmpty { out.append(Token(raw: raw, norm: norm, range: start..<i)) }
            }
        }
        return out
    }

    static let contractions: Set<String> = ["she's", "he's", "it's", "that's", "what's", "there's", "who's", "let's", "where's", "here's"]

    private static func isSplitter(_ c: [Character], _ i: Int) -> Bool {
        let ch = c[i]
        if ch == "," && i > 0 && i + 1 < c.count && c[i - 1].isNumber && c[i + 1].isNumber { return false } // 1,000
        if ch == "," || ch == ";" { return true }
        if ch == "-" || ch == "–" || ch == "—" {
            let prevNum = i > 0 && c[i - 1].isNumber, nextNum = i + 1 < c.count && c[i + 1].isNumber
            return !(prevNum && nextNum)
        }
        return false
    }

    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    public static func similarity(_ a: String, _ b: String) -> Double {
        let m = max(a.count, b.count)
        return m == 0 ? 1 : 1 - Double(levenshtein(a, b)) / Double(m)
    }
}
