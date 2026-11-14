import Foundation

/// One raw ASR segment. The raw transcript is the source of truth and is
/// never edited after creation.
public struct RawSegment: Codable, Equatable, Sendable {
    public var id: String          // "s41"
    public var startMs: Int64      // ms since call start
    public var endMs: Int64
    public var text: String
    public var avgLogprob: Double?
    /// ASR token times: [character offset in `text`, call ms]. Nil when the engine gave none.
    public var wordTimes: [[Int64]]?
    public init(id: String, startMs: Int64, endMs: Int64, text: String, avgLogprob: Double? = nil, wordTimes: [[Int64]]? = nil) {
        self.id = id; self.startMs = startMs; self.endMs = endMs; self.text = text; self.avgLogprob = avgLogprob; self.wordTimes = wordTimes
    }
    enum CodingKeys: String, CodingKey { case id, startMs = "start_ms", endMs = "end_ms", text, avgLogprob = "avg_logprob", wordTimes = "word_times" }
}

public struct RawTranscript: Codable, Sendable {
    public var callId: String
    public var asrModel: String
    public var initialPrompt: String?
    public var segments: [RawSegment]
    public init(callId: String, asrModel: String, initialPrompt: String? = nil, segments: [RawSegment]) {
        self.callId = callId; self.asrModel = asrModel; self.initialPrompt = initialPrompt; self.segments = segments
    }
    enum CodingKeys: String, CodingKey { case callId = "call_id", asrModel = "asr_model", initialPrompt = "initial_prompt", segments }
}

/// A single cleanup edit, linked back to the raw span (and exact character
/// range inside the raw segment text) it changed.
public struct Correction: Codable, Equatable, Sendable {
    public var id: String
    public var rawSpan: String
    public var rawRange: [Int]     // [start, end) character offsets in raw text
    public var original: String
    public var replacement: String
    public var rule: String
    enum CodingKeys: String, CodingKey { case id, rawSpan = "raw_span", rawRange = "raw_range", original, replacement, rule }
}

/// Normalized token, mapped to a character range of the raw segment text.
public struct CleanToken: Equatable, Sendable {
    public var text: String
    public var rawStart: Int
    public var rawEnd: Int
    public var rule: String?       // set when produced by a correction
    public var punct: String? = nil // trailing sentence/clause punctuation of the raw text (". , ? ! ; :")
}

public struct CleanSegment: Equatable, Sendable {
    public var rawSpan: String
    public var startMs: Int64
    public var endMs: Int64
    public var rawText: String
    public var tokens: [CleanToken]
    public var wordTimes: [[Int64]]? = nil
    public var text: String { tokens.map(\.text).joined(separator: " ") }

    /// Exact raw quote for clean tokens [a, b].
    public func quote(_ a: Int, _ b: Int) -> String {
        let chars = Array(rawText)
        let s = tokens[a].rawStart, e = tokens[b].rawEnd
        return String(chars[max(0, s)..<min(chars.count, e)])
    }
    /// Time of clean token i: from ASR token times when present (last ASR token
    /// starting at or before the word), else proportional to character position.
    public func timeOf(token i: Int) -> Int64 {
        let c = tokens[min(i, tokens.count - 1)].rawStart
        if let wt = wordTimes, !wt.isEmpty {
            if let hit = wt.last(where: { $0[0] <= Int64(c) }) { return max(startMs, hit[1]) }
            return max(startMs, wt[0][1])
        }
        let n = max(1, rawText.count)
        let frac = Double(tokens[min(i, tokens.count - 1)].rawStart) / Double(n)
        return startMs + Int64(frac * Double(endMs - startMs))
    }
}

public struct CleanTranscript: Codable, Sendable {
    public struct Seg: Codable, Sendable {
        public var rawSpan: String
        public var text: String
        enum CodingKeys: String, CodingKey { case rawSpan = "raw_span", text }
    }
    public var segments: [Seg]
    public var corrections: [Correction]
}
