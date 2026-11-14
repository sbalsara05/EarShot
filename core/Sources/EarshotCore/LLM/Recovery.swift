import Foundation

/// One value the model says was spoken but the rules missed.
public struct RecoveryItem: Codable, Equatable, Sendable {
    public var type: String    // vitals | medication | procedure | finding
    public var field: String
    public var value: String
    public var span: String    // raw segment id, "s14"
    public var quote: String   // verbatim words from that segment
    public init(type: String, field: String, value: String, span: String, quote: String) {
        self.type = type; self.field = field; self.value = value; self.span = span; self.quote = quote
    }
}

public struct RecoveryReply: Codable, Sendable { public var items: [RecoveryItem] }

/// What happened to one proposal, for llm.json.
public struct RecoveryDecision: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case accepted          // joins the findings
        case confirm           // rejected; its quote is real, so it is shown as "heard, please confirm"
        case dropped           // rejected; nothing provable to show (no real quote, or diagnosis text)
        case duplicate         // the rules already have this value from this span
    }
    public var item: RecoveryItem
    public var window: Int
    public var outcome: Outcome
    public var reason: String?
}

public struct RecoveryReport: Codable, Sendable {
    public var windows: Int = 0
    public var decisions: [RecoveryDecision] = []
    public var errors: [String] = []
    public var accepted: Int { decisions.filter { $0.outcome == .accepted }.count }
    public var rejected: Int { decisions.filter { $0.outcome == .confirm || $0.outcome == .dropped }.count }
    enum CodingKeys: String, CodingKey { case windows, decisions, errors, accepted, rejected }
    public init() {}
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(windows, forKey: .windows); try c.encode(decisions, forKey: .decisions); try c.encode(errors, forKey: .errors)
        try c.encode(accepted, forKey: .accepted); try c.encode(rejected, forKey: .rejected)
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        windows = try c.decode(Int.self, forKey: .windows); decisions = try c.decode([RecoveryDecision].self, forKey: .decisions)
        errors = try c.decodeIfPresent([String].self, forKey: .errors) ?? []
    }
}

/// Fields a recovered item may fill, by type. Anything else is rejected.
public enum RecoveryFields {
    public static let vitals = ["bp_systolic", "bp_diastolic", "heart_rate", "resp_rate", "spo2", "etco2", "glucose", "gcs", "temp", "pain"]
    public static let medication = ["drug", "dose", "unit", "route"]
    public static let procedure = ["procedure"]
    public static let finding = ["term"]
    public static func allowed(_ type: String) -> [String] {
        switch type {
        case "vitals": return vitals
        case "medication": return medication
        case "procedure": return procedure
        case "finding": return finding
        default: return []
        }
    }
    /// Plausible numeric ranges: the rules extractor's (`RulesExtractor` vital rules, widest per field).
    /// Doses: any positive amount up to 5000 (mL of fluid is the largest the formulary lists).
    public static let ranges: [String: ClosedRange<Double>] = [
        "bp_systolic": 40...300, "bp_diastolic": 20...200, "heart_rate": 20...260, "resp_rate": 2...70,
        "spo2": 40...100, "glucose": 10...700, "gcs": 3...15, "etco2": 0...150, "temp": 25...110, "pain": 0...10,
        "dose": 0.001...5000,
    ]
}

/// Checks each proposal against the transcript (rule 1 of the brief). Pure code, no model.
public struct RecoveryVerifier {
    let dict: EMSDictionary
    let cleanup: Cleanup
    public let extractor: String

    public init(dict: EMSDictionary, model: String) {
        self.dict = dict
        self.cleanup = Cleanup(dict: dict)
        self.extractor = LLMProvenance.verified(model)
    }

    /// Why `item` cannot be accepted, or nil if it can. `segments` are the call's raw segments by id.
    public func rejection(_ item: RecoveryItem, segments: [String: RawSegment]) -> String? {
        guard let seg = segments[item.span] else { return "unknown span \(item.span)" }
        let quote = item.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty, seg.text.contains(quote) else { return "quote is not in \(item.span)" }
        if Diagnosis.contains(quote) || Diagnosis.contains(item.value) || Diagnosis.contains(item.field) { return "diagnosis text" }
        let allowed = RecoveryFields.allowed(item.type)
        guard allowed.contains(item.field) else { return "field \(item.type).\(item.field) is not recoverable" }
        let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "empty value" }
        let heard = normalizedTokens(quote)

        switch (item.type, item.field) {
        case ("medication", "drug"):
            guard let di = drugIndex(value) else { return "drug not in formulary" }
            guard drugsHeard(heard).contains(di) else { return "drug is not in the quote" }
        case ("medication", "unit"):
            guard let u = dict.unitIndex[EMSText.normalizePhrase(value)] ?? (dict.formulary.units[value] != nil ? value : nil) else { return "unknown unit" }
            guard phrases(heard).contains(where: { dict.unitIndex[$0] == u }) else { return "unit is not in the quote" }
        case ("medication", "route"):
            guard let r = dict.routeIndex[EMSText.normalizePhrase(value)] ?? (dict.formulary.routes[value] != nil ? value : nil) else { return "unknown route" }
            guard phrases(heard).contains(where: { dict.routeIndex[$0] == r }) else { return "route is not in the quote" }
        case ("procedure", _), ("finding", _):
            let words = EMSText.normalizePhrase(value).split(separator: " ").map(String.init)
            guard !words.isEmpty, words.allSatisfy({ heard.contains($0) }) else { return "value is not in the quote" }
        default:   // numbers: vitals and dose
            guard let v = Double(value) else { return "value is not a number" }
            if let r = RecoveryFields.ranges[item.field], !r.contains(v) { return "value out of range for \(item.field)" }
            guard numbers(heard).contains(v) else { return "value is not in the quote" }
        }
        return nil
    }

    /// Verifies a batch of proposals from one window and turns them into findings.
    /// Accepted items (grouped per span) become findings with receipts; rejected items whose
    /// quote is real become "heard, please confirm" status findings that carry only the quote,
    /// never the proposed value.
    public func verify(_ items: [RecoveryItem], window: Int, segments: [String: RawSegment], existing: [Finding])
        -> (findings: [Finding], decisions: [RecoveryDecision]) {
        var decisions: [RecoveryDecision] = []
        var ok: [RecoveryItem] = []
        var seen = Set<String>()
        for it in items {
            let key = "\(it.span)|\(it.type)|\(it.field)|\(it.value)"
            if !seen.insert(key).inserted { continue }
            if let why = rejection(it, segments: segments) {
                decisions.append(RecoveryDecision(item: it, window: window, outcome: showable(it, segments) ? .confirm : .dropped, reason: why))
            } else if alreadyFound(it, existing) {
                decisions.append(RecoveryDecision(item: it, window: window, outcome: .duplicate, reason: "already found by the rules"))
            } else {
                ok.append(it)
            }
        }
        // A dose, unit or route only counts next to a verified drug from the same span.
        let drugSpans = Set(ok.filter { $0.type == "medication" && $0.field == "drug" }.map(\.span))
        var accepted: [RecoveryItem] = []
        for it in ok {
            if it.type == "medication" && it.field != "drug" && !drugSpans.contains(it.span) {
                decisions.append(RecoveryDecision(item: it, window: window, outcome: .confirm, reason: "\(it.field) without a verified drug in \(it.span)"))
            } else {
                accepted.append(it)
                decisions.append(RecoveryDecision(item: it, window: window, outcome: .accepted, reason: nil))
            }
        }

        var out: [Finding] = []
        // group accepted items into one finding per (span, type); findings and procedures stay one per item
        var groups: [(key: String, items: [RecoveryItem])] = []
        for it in accepted {
            let k = ["finding", "procedure"].contains(it.type) ? "\(it.span)|\(it.type)|\(it.value)" : "\(it.span)|\(it.type)"
            if let i = groups.firstIndex(where: { $0.key == k }) { groups[i].items.append(it) } else { groups.append((k, [it])) }
        }
        for g in groups {
            guard let first = g.items.first, let seg = segments[first.span] else { continue }
            var fields: [String: String] = [:]
            var receipts: [String: FieldReceipt] = [:]
            for it in g.items {
                let name = it.type == "finding" ? "term" : it.field
                fields[name] = canonical(it)
                receipts[name] = receipt(it, seg)
            }
            let type: EventType
            switch first.type {
            case "vitals": type = .vitals
            case "medication": type = .medication
            case "procedure": type = .procedure
            default: type = .status; fields["kind"] = "finding"
            }
            let quotes = g.items.map(\.quote)
            let quote = quotes.max { $0.count < $1.count } ?? first.quote
            out.append(Finding(type: type, fields: fields, receipts: receipts, tMs: time(of: first.quote, in: seg), rawSpan: seg.id,
                               quote: quote, confidence: 0.6, flags: [LLMProvenance.flag], extractor: extractor))
        }
        for d in decisions where d.outcome == .confirm {
            guard let seg = segments[d.item.span] else { continue }
            out.append(Finding(type: .status, fields: ["kind": "llm_unverified", "heard_as": d.item.quote, "note": "heard, please confirm — \(publicReason(d.reason))"],
                               receipts: ["heard_as": receipt(d.item, seg)], tMs: time(of: d.item.quote, in: seg), rawSpan: seg.id,
                               quote: d.item.quote, confidence: 0.3, flags: ["confirm", LLMProvenance.flag], extractor: extractor.replacingOccurrences(of: "(verified)", with: "(unverified)")))
        }
        return (out, decisions)
    }

    // MARK: helpers

    /// A rejected item is shown for confirmation only when its quote is really in its span
    /// and carries no diagnosis words. Otherwise it is only logged.
    /// It must also hold something to check: a number for a numeric field, or the words of a drug,
    /// procedure or finding; a proposal like "temp: not provided" is only logged.
    func showable(_ it: RecoveryItem, _ segments: [String: RawSegment]) -> Bool {
        guard let seg = segments[it.span] else { return false }
        let q = it.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, seg.text.contains(q), !Diagnosis.contains(q) else { return false }
        guard RecoveryFields.allowed(it.type).contains(it.field) else { return false }
        if RecoveryVerifier.placeholder.firstMatch(in: it.value, range: NSRange(location: 0, length: (it.value as NSString).length)) != nil { return false }
        switch (it.type, it.field) {
        case ("medication", "drug"), ("procedure", _), ("finding", _): return true
        case ("medication", "unit"), ("medication", "route"): return true
        default: return !numbers(normalizedTokens(q)).isEmpty
        }
    }

    /// Values that say nothing was said ("not specified", "unknown", "n/a"): only logged.
    static let placeholder = try! NSRegularExpression(pattern: #"^\s*(?:not\s+\w+|unknown|none|n/?a|null|-+|\?+)\s*$"#, options: [.caseInsensitive])

    /// The reason shown in the event names the check, never the model's value.
    func publicReason(_ r: String?) -> String {
        guard let r else { return "not verified" }
        if r.hasPrefix("value out of range") { return "value out of range" }
        if r.hasPrefix("field ") { return "not a recoverable field" }
        return r
    }

    func alreadyFound(_ it: RecoveryItem, _ existing: [Finding]) -> Bool {
        let name = it.type == "finding" ? "term" : it.field
        let v = canonical(it)
        return existing.contains { f in
            guard f.rawSpan == it.span else { return false }
            if f.fields[name].map({ same($0, v) }) ?? false { return true }
            // a finding the rules already wrote as a symptom, history item, condition…
            if it.type == "finding" || it.type == "procedure" {
                let nv = EMSText.normalizePhrase(v)
                return f.fields.values.contains { let n = EMSText.normalizePhrase($0); return n.count > 3 && (n.contains(nv) || nv.contains(n)) }
            }
            return false
        }
    }

    func same(_ a: String, _ b: String) -> Bool {
        if let x = Double(a), let y = Double(b) { return x == y }
        return EMSText.normalizePhrase(a) == EMSText.normalizePhrase(b)
    }

    /// The value as the rules would write it: generic drug, canonical unit/route, plain numbers.
    func canonical(_ it: RecoveryItem) -> String {
        let v = it.value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (it.type, it.field) {
        case ("medication", "drug"): return drugIndex(v).map { dict.drug($0).generic } ?? v
        case ("medication", "unit"): return dict.unitIndex[EMSText.normalizePhrase(v)] ?? v
        case ("medication", "route"): return dict.routeIndex[EMSText.normalizePhrase(v)] ?? v
        case ("procedure", _), ("finding", _): return v
        default:
            guard let d = Double(v) else { return v }
            return d == d.rounded() ? String(Int(d)) : String(d)
        }
    }

    func drugIndex(_ v: String) -> Int? {
        let k = EMSText.normalizePhrase(v)
        return dict.aliasIndex[k] ?? dict.variantIndex[k]
    }

    /// The quote after cleanup: spoken numbers as digits, ASR drug variants fixed. Lowercase tokens.
    func normalizedTokens(_ quote: String) -> [String] {
        let (clean, _) = cleanup.clean(RawSegment(id: "q", startMs: 0, endMs: 0, text: quote))
        let cleaned = clean.tokens.map { $0.text.lowercased() }
        return cleaned + EMSText.tokenize(quote).map(\.norm)   // the raw words count too ("ninety" stays matchable as a word)
    }

    /// All 1..maxAliasTokens-word phrases in the tokens.
    func phrases(_ toks: [String]) -> [String] {
        var out: [String] = []
        let n = max(3, dict.maxAliasTokens)
        for i in toks.indices {
            for len in 1...n where i + len <= toks.count { out.append(toks[i..<(i + len)].joined(separator: " ")) }
        }
        return out
    }

    func drugsHeard(_ toks: [String]) -> Set<Int> {
        Set(phrases(toks).compactMap { dict.aliasIndex[$0] ?? dict.variantIndex[$0] })
    }

    /// Every number in the tokens, with "142/88" giving 142 and 88 and "95%" giving 95.
    func numbers(_ toks: [String]) -> Set<Double> {
        var out = Set<Double>()
        for t in toks {
            for part in t.split(whereSeparator: { $0 == "/" }) {
                let s = part.trimmingCharacters(in: CharacterSet(charactersIn: "%.,;:"))
                if let d = Double(s) { out.insert(d) }
            }
        }
        return out
    }

    func receipt(_ it: RecoveryItem, _ seg: RawSegment) -> FieldReceipt {
        let q = it.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        var range: [Int]? = nil
        if let r = seg.text.range(of: q) {
            let a = seg.text.distance(from: seg.text.startIndex, to: r.lowerBound)
            range = [a, a + q.count]
        }
        return FieldReceipt(rawSpan: seg.id, quote: q, rawRange: range, inferred: nil)
    }

    /// When the quote was said: the ASR word time at or before its first character, else the segment start.
    func time(of quote: String, in seg: RawSegment) -> Int64 {
        guard let r = seg.text.range(of: quote.trimmingCharacters(in: .whitespacesAndNewlines)), let wt = seg.wordTimes, !wt.isEmpty else { return seg.startMs }
        let a = Int64(seg.text.distance(from: seg.text.startIndex, to: r.lowerBound))
        return wt.last(where: { $0.count >= 2 && $0[0] <= a })?[1] ?? seg.startMs
    }
}

/// The recovery pass: windows of about 8 raw segments, one model call each, every proposal
/// through `RecoveryVerifier`.
public struct RecoveryPass {
    let dict: EMSDictionary
    let llm: LLMEngine
    let window: Int

    public init(dict: EMSDictionary, llm: LLMEngine, window: Int = 8) {
        self.dict = dict; self.llm = llm; self.window = max(1, window)
    }

    public static let system = #"""
    You help an ambulance crew check a call transcript. It comes from speech recognition, so numbers and drug \
    names are often split or misheard. Rules have already found some values; they are listed in already_found. \
    Find values that were spoken in these segments but are missing from already_found:
    - vital signs: bp_systolic, bp_diastolic, heart_rate, resp_rate, spo2, etco2, glucose, gcs, temp, pain
    - medications given: drug, dose, unit, route (one item per field)
    - procedures done: procedure
    - physical findings the crew saw on exam (not symptoms the patient reports): term
    For each value give type, field, value, span (the segment id) and quote: words copied exactly, character for \
    character, from that segment, that contain the value.
    Spoken numbers: "one ten" is 110, "one fifty eight over ninety two" is 158 over 92, "a hundred and ten" is 110, \
    "ninety four" is 94. Write values as digits. Use generic drug names.
    Only include what was actually said. Never guess, never fill in typical values, never name a diagnosis or a \
    condition, never give advice. If nothing is missing, return {"items":[]}.

    Example input:
    {"already_found":[{"field":"bp_systolic","span":"s3","type":"vitals","value":"120"},{"field":"bp_diastolic","span":"s3","type":"vitals","value":"80"}],"segments":[{"id":"s3","start_ms":40000,"text":"Pressure's one twenty over eighty, heart's going about ninety, pulse ox says ninety eight."}]}
    Example output:
    {"items":[{"type":"vitals","field":"heart_rate","value":"90","span":"s3","quote":"heart's going about ninety"},{"type":"vitals","field":"spo2","value":"98","span":"s3","quote":"pulse ox says ninety eight"}]}
    """#

    struct WindowSegment: Encodable { var id: String; var start_ms: Int64; var text: String }
    struct Known: Encodable { var span: String; var type: String; var field: String; var value: String }
    struct Input: Encodable { var segments: [WindowSegment]; var already_found: [Known] }

    public func run(raw: [RawSegment], findings: [Finding], report: inout RecoveryReport) -> [Finding] {
        let verifier = RecoveryVerifier(dict: dict, model: llm.modelName)
        var byId: [String: RawSegment] = [:]
        for s in raw { byId[s.id] = s }
        var out: [Finding] = []
        var w = 0
        var i = 0
        while i < raw.count {
            let win = Array(raw[i..<min(raw.count, i + window)])
            i += window
            w += 1
            let ids = Set(win.map(\.id))
            let known = (findings + out).filter { ids.contains($0.rawSpan) }.flatMap { f in
                f.fields.filter { k, _ in RecoveryFields.allowed(Self.typeName(f)).contains(k) }
                    .sorted { $0.key < $1.key }
                    .map { Known(span: f.rawSpan, type: Self.typeName(f), field: $0.key, value: $0.value) }
            }
            let input = Input(segments: win.map { WindowSegment(id: $0.id, start_ms: $0.startMs, text: $0.text) }, already_found: known)
            let reply: String
            do {
                reply = try llm.complete(system: Self.system, user: LLMJSON.encode(input), grammar: Self.grammar(spans: win.map(\.id)), maxTokens: 600)
            } catch {
                report.errors.append("window \(w): \(error)")
                continue
            }
            guard let data = LLMJSON.object(reply), let parsed = try? JSONDecoder().decode(RecoveryReply.self, from: data) else {
                report.errors.append("window \(w): reply is not valid JSON")
                continue
            }
            let (found, decisions) = verifier.verify(parsed.items, window: w, segments: byId, existing: findings + out)
            out += found
            report.decisions += decisions
        }
        report.windows += w
        return out
    }

    static func typeName(_ f: Finding) -> String {
        switch f.type {
        case .vitals: return "vitals"
        case .medication: return "medication"
        case .procedure: return "procedure"
        default: return f.fields["kind"] == "finding" ? "finding" : "other"
        }
    }

    /// Output is always `{"items":[...]}` with known types, known fields, and spans from this window.
    public static func grammar(spans: [String]) -> String {
        func item(_ type: String, _ fields: [String]) -> String {
            #""{" ws "\"type\":" ws "\"\#(type)\"" ws "," ws "\"field\":" ws (\#(GBNF.oneOf(fields))) ws "," ws "\"value\":" ws str ws "," ws "\"span\":" ws span ws "," ws "\"quote\":" ws str ws "}""#
        }
        return """
        root ::= "{" ws "\\"items\\":" ws "[" ws (item (ws "," ws item){0,11})? ws "]" ws "}"
        item ::= vit | med | proc | fnd
        vit ::= \(item("vitals", RecoveryFields.vitals))
        med ::= \(item("medication", RecoveryFields.medication))
        proc ::= \(item("procedure", RecoveryFields.procedure))
        fnd ::= \(item("finding", RecoveryFields.finding))
        span ::= \(GBNF.oneOf(spans.isEmpty ? ["s1"] : spans))
        \(GBNF.common)
        """
    }
}
