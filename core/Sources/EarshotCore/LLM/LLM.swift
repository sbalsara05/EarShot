import Foundation

/// Language-model slot, like `Transcriber`: llama.cpp + Phi-3.5-mini (EarshotLLM) in
/// production, a scripted stub in tests. The model only ever proposes. Code decides what
/// is kept (`RecoveryVerifier`, `NarrativeChecker`); nothing it writes reaches a field or
/// the XML without passing those checks.
public protocol LLMEngine: AnyObject {
    /// Short name used in provenance, e.g. "phi-3.5-mini-q4".
    var modelName: String { get }
    /// One chat turn in the model's own chat template. Decoding is deterministic
    /// (temperature 0, fixed seed, fixed threads) and constrained by `grammar` (GBNF),
    /// so the reply always parses as the JSON the grammar describes.
    func complete(system: String, user: String, grammar: String, maxTokens: Int) throws -> String
    /// Running totals since the engine was made (zero for engines that do not count).
    var usage: LLMUsage { get }
}

/// Tokens in and out, and seconds spent, so llm.json can say where the time went.
public struct LLMUsage: Codable, Equatable, Sendable {
    public var calls = 0
    public var promptTokens = 0
    public var generatedTokens = 0
    public var promptSeconds = 0.0
    public var generateSeconds = 0.0
    /// Generated tokens where the model's top choice broke the grammar and the full vocabulary was masked.
    public var grammarFallbacks = 0
    public init() {}
    public static func - (a: LLMUsage, b: LLMUsage) -> LLMUsage {
        var d = LLMUsage()
        d.calls = a.calls - b.calls; d.promptTokens = a.promptTokens - b.promptTokens; d.generatedTokens = a.generatedTokens - b.generatedTokens
        d.promptSeconds = a.promptSeconds - b.promptSeconds; d.generateSeconds = a.generateSeconds - b.generateSeconds
        d.grammarFallbacks = a.grammarFallbacks - b.grammarFallbacks
        return d
    }
    enum CodingKeys: String, CodingKey { case calls, promptTokens = "prompt_tokens", generatedTokens = "generated_tokens", promptSeconds = "prompt_s", generateSeconds = "generate_s", grammarFallbacks = "grammar_fallbacks" }
}

extension LLMEngine {
    public var usage: LLMUsage { LLMUsage() }
}

/// `"llm": {"model": "...", "passes": ["recover", "narrative"], "threads": 4}`.
/// Off by default: with no model, the pipeline is rules-only, exactly as before.
public struct LLMConfig: Codable, Sendable, Equatable {
    public var model: String? = nil
    public var passes: [String] = LLMPass.allCases.map(\.rawValue)
    public var threads: Int = 4
    /// Context window in tokens.
    public var context: Int = 4096
    /// Raw segments per recovery window.
    public var window: Int = 8
    public init() {}
    enum CodingKeys: String, CodingKey { case model, passes, threads, context, window }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        passes = try c.decodeIfPresent([String].self, forKey: .passes) ?? LLMPass.allCases.map(\.rawValue)
        threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? 4
        context = try c.decodeIfPresent(Int.self, forKey: .context) ?? 4096
        window = try c.decodeIfPresent(Int.self, forKey: .window) ?? 8
    }
    /// Model paths of "none" (or empty) mean off.
    public var enabled: Bool { !(model ?? "").isEmpty && model != "none" }
    public func runs(_ p: LLMPass) -> Bool { passes.contains(p.rawValue) }
}

public enum LLMPass: String, CaseIterable, Sendable { case recover, narrative }

/// What the LLM passes did on one run, written as `llm.json`.
public struct LLMReport: Codable, Sendable {
    public var model: String
    public var passes: [String]
    public var recovery: RecoveryReport?
    public var narrative: NarrativeReport?
    /// Seconds per LLM stage (also merged into timing.json).
    public var timing: [String: Double] = [:]
    /// Tokens and seconds per pass ("recover", "narrative").
    public var usage: [String: LLMUsage] = [:]
    public var notes: [String] = []
    public init(model: String, passes: [String]) { self.model = model; self.passes = passes }
}

/// Provenance string on every event the model helped find, e.g. "phi-3.5-mini-q4 (verified)".
public enum LLMProvenance {
    public static func verified(_ model: String) -> String { "\(model) (verified)" }
    public static let flag = "llm"
}

// MARK: JSON and grammar helpers

enum LLMJSON {
    /// The first top-level JSON object in `s` (models sometimes add text around it; the
    /// grammar normally prevents that).
    static func object(_ s: String) -> Data? {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
        return String(s[a...b]).data(using: .utf8)
    }

    static func encode<T: Encodable>(_ v: T) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

/// GBNF building blocks shared by both passes. Strings are plain JSON strings without
/// control characters; whitespace is bounded so the model cannot pad forever.
enum GBNF {
    static let common = #"""
    str ::= "\"" char{0,240} "\""
    char ::= [^"\\\x7F\x00-\x1F] | "\\" ["\\/bfnrt]
    ws ::= [ \n]{0,2}
    """#

    /// `"a" | "b" | ...` for a fixed set of JSON string values.
    static func oneOf(_ values: [String]) -> String {
        values.map { "\"\\\"\($0)\\\"\"" }.joined(separator: " | ")
    }
}
