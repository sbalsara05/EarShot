import Foundation

/// A field the on-device language model thinks the rules missed. It must quote the transcript.
public struct AISuggestion: Codable, Equatable, Sendable {
    /// One of `Grounding.suggestableFields`.
    public var field: String
    public var value: String
    /// The medic's words that support it, copied from the transcript.
    public var quote: String
    public init(field: String, value: String, quote: String) { self.field = field; self.value = value; self.quote = quote }
}

public struct GroundingResult: Equatable, Sendable {
    public var accepted: Bool
    public var reason: String?
    /// The raw segment the quote was found in.
    public var segmentId: String?
}

/// Keeps the language model honest. The model may write prose and suggest missed fields, but:
///   - a suggestion survives only if its quote is really in the raw transcript, and every number in
///     its value is in that quote (after the same cleanup the rules use, so "twenty two" = 22);
///   - a narrative sentence survives only if every number and drug in it is already in the record
///     (an event's value, quote, or clock time).
/// Nothing the model writes reaches the chart without passing here, and accepted suggestions are
/// always "please confirm".
public struct Grounding {
    /// Fields the model may suggest. Vital signs (numbers it can be checked on) and allergies.
    /// Medications are deliberately not suggestable: the rules and the cross-check own them.
    public static let suggestableFields: Set<String> = Set(CrossCheck.vitalKeys + ["allergy"])

    let dict: EMSDictionary
    let cleaner: Cleanup
    let rules: RulesExtractor
    public init(dict: EMSDictionary) { self.dict = dict; cleaner = Cleanup(dict: dict); rules = RulesExtractor(dict: dict) }

    // MARK: suggestions

    public func check(_ s: AISuggestion, transcript: [RawSegment], events: [EarshotEvent]) -> GroundingResult {
        guard Self.suggestableFields.contains(s.field) else { return .init(accepted: false, reason: "field \(s.field) is not suggestable") }
        let value = s.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .init(accepted: false, reason: "empty value") }
        let q = Self.norm(s.quote)
        guard q.count >= 3 else { return .init(accepted: false, reason: "quote too short") }
        guard let seg = transcript.first(where: { Self.norm($0.text).contains(q) }) else {
            return .init(accepted: false, reason: "quote is not in the transcript")
        }
        let cleanQuote = clean(s.quote)
        for n in Self.numbers(in: clean(value)) where !Self.numbers(in: cleanQuote).contains(n) {
            return .init(accepted: false, reason: "\(n) is not in the quote", segmentId: seg.id)
        }
        if s.field == "allergy" {
            let words = Self.norm(value).split(separator: " ").filter { $0.count > 2 }
            guard !words.isEmpty, words.allSatisfy({ q.contains($0) }) else {
                return .init(accepted: false, reason: "allergy words are not in the quote", segmentId: seg.id)
            }
        } else if Self.numbers(in: clean(value)).isEmpty {
            return .init(accepted: false, reason: "a vital sign needs a number", segmentId: seg.id)
        }
        let already = events.contains { e in
            s.field == "allergy" ? (e.fields["kind"] == "allergy" && Self.norm(e.fields["allergy"] ?? "") == Self.norm(value))
                                 : e.type == .vitals && e.fields[s.field].map { CrossCheck.numEq($0, value) } == true
        }
        if already { return .init(accepted: false, reason: "already in the record", segmentId: seg.id) }
        return .init(accepted: true, reason: nil, segmentId: seg.id)
    }

    // MARK: narrative

    /// Splits the narrative into sentences and keeps those whose numbers and drugs are all in the record.
    public func checkNarrative(_ text: String, events: [EarshotEvent], clock: CallClock) -> (kept: String, dropped: [String]) {
        var allowedNums = Set<String>()
        var allowedDrugs = Set<String>()
        for e in events {
            for v in e.fields.values { allowedNums.formUnion(Self.numbers(in: clean(v))) }
            if let q = e.quote { allowedNums.formUnion(Self.numbers(in: clean(q))) }
            for r in (e.receipts ?? [:]).values { allowedNums.formUnion(Self.numbers(in: clean(r.quote))) }
            if let d = e.fields["drug"] { allowedDrugs.insert(d.lowercased()) }
            let hhmm = String(clock.clock(e.tMs).prefix(5))
            allowedNums.insert(hhmm)
            if hhmm.hasPrefix("0") { allowedNums.insert(String(hhmm.dropFirst())) }
        }
        var kept: [String] = [], dropped: [String] = []
        for sentence in Self.sentences(text) {
            let c = clean(sentence)
            let nums = Self.numbers(in: c)
            let drugs = Set(rules.extract(cleaner.clean(RawSegment(id: "n", startMs: 0, endMs: 1, text: sentence)).0)
                .filter { $0.type == .medication }.compactMap { $0.fields["drug"]?.lowercased() })
            if nums.isSubset(of: allowedNums) && drugs.isSubset(of: allowedDrugs) { kept.append(sentence) } else { dropped.append(sentence) }
        }
        return (kept.joined(separator: " "), dropped)
    }

    // MARK: helpers

    func clean(_ s: String) -> String { cleaner.clean(RawSegment(id: "g", startMs: 0, endMs: 1, text: s)).0.text }

    /// Numbers ("142", "88", "0.4") and clock times ("14:05") in text. "142/88" gives 142 and 88.
    static func numbers(in s: String) -> Set<String> {
        var out = Set<String>()
        let rx = try! NSRegularExpression(pattern: #"\d{1,2}:\d{2}|\d+(?:\.\d+)?"#)
        let ns = s as NSString
        for m in rx.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            var t = ns.substring(with: m.range)
            if t.contains("."), let d = Double(t) { t = d == d.rounded() ? String(Int(d)) : String(d) }
            out.insert(t)
        }
        return out
    }

    static func norm(_ s: String) -> String {
        s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }.reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            cur.append(ch)
            // a full stop ends a sentence only before a space or the end ("98.6" stays whole)
            let endsHere = "!?\n".contains(ch) || (ch == "." && (i + 1 == chars.count || chars[i + 1].isWhitespace))
            if endsHere {
                let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && t.rangeOfCharacter(from: .alphanumerics) != nil { out.append(t) }
                cur = ""
            }
        }
        let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { out.append(t) }
        return out
    }
}
