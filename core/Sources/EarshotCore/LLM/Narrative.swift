import Foundation

/// One sentence of the model-written narrative and the events it rests on.
public struct NarrativeSentence: Codable, Equatable, Sendable {
    public var text: String
    public var events: [String]
    public init(text: String, events: [String]) { self.text = text; self.events = events }
}

public struct NarrativeReply: Codable, Sendable { public var sentences: [NarrativeSentence] }

public struct NarrativeReport: Codable, Sendable {
    /// true: the model's narrative passed the checker and is in chart.md and eNarrative.01.
    public var used = false
    /// Why the template narrative was used instead.
    public var fallbackReason: String?
    public var sentences: [NarrativeSentence] = []
    public var failures: [String] = []
    public init() {}
    enum CodingKeys: String, CodingKey { case used, fallbackReason = "fallback_reason", sentences, failures }
}

/// Checks a narrative against the events it cites. Any failure means the template narrative
/// for the whole call.
public struct NarrativeChecker {
    let dict: EMSDictionary
    let cleanup: Cleanup
    public init(dict: EMSDictionary) { self.dict = dict; self.cleanup = Cleanup(dict: dict) }

    /// Words that turn documentation into advice. Not in `Diagnosis` because they are fine in a quote.
    static let advice = try! NSRegularExpression(pattern: #"\b(?:recommend\w*|should|advis\w*|suggest\w*|consider|likely|probabl\w*|possibl\w*|rule out|indicat\w* (?:a|an)\b)"#, options: [.caseInsensitive])
    static let timeRx = try! NSRegularExpression(pattern: #"\b([01]?\d|2[0-3]):([0-5]\d)(?::[0-5]\d)?\b"#)

    /// Fields that are never heard values, so a sentence may not rest on them.
    static let hiddenFields: Set<String> = ["unit_suggested", "drug_as_heard", "route_as_heard", "heard_as", "note", "kind", "negated", "inferred"]

    /// Every failure, one line each; empty means the narrative may be used.
    public func failures(_ sentences: [NarrativeSentence], events: [EarshotEvent], clock: CallClock) -> [String] {
        var out: [String] = []
        if sentences.isEmpty { return ["no sentences"] }
        var byId: [String: EarshotEvent] = [:]
        for e in events { byId[e.id] = e }
        for (n, s) in sentences.enumerated() {
            let tag = "sentence \(n + 1)"
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { out.append("\(tag): empty"); continue }
            if s.events.isEmpty { out.append("\(tag): cites no event"); continue }
            let cited = s.events.compactMap { byId[$0] }
            if cited.count != s.events.count { out.append("\(tag): cites an event that does not exist"); continue }
            if Diagnosis.contains(text) { out.append("\(tag): diagnosis term"); continue }
            if Self.advice.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil {
                out.append("\(tag): advice or interpretation"); continue
            }
            let values = cited.flatMap { e in e.fields.filter { !Self.hiddenFields.contains($0.key) }.map(\.value) }
            // times: "14:05" must be the clock time of a cited event
            let ns = text as NSString
            var rest = text
            for m in Self.timeRx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let t = ns.substring(with: m.range)
                let hhmm = String(format: "%02d:%@", Int(ns.substring(with: m.range(at: 1))) ?? -1, ns.substring(with: m.range(at: 2)))
                let times = cited.map { String(clock.clock($0.tMs).prefix(5)) } + values.filter { $0.contains(":") }.map { String($0.prefix(5)) }
                if !times.contains(hhmm) { out.append("\(tag): time \(t) is not a cited event's time") }
                rest = rest.replacingOccurrences(of: t, with: " ")
            }
            // blood pressure: "a/b" must be one cited reading, systolic first
            for (sys, dia) in Self.pressures(rest) where !cited.contains(where: { e in
                e.fields["bp_systolic"].flatMap(Double.init) == sys && (e.fields["bp_diastolic"].flatMap(Double.init) == dia)
            }) {
                out.append("\(tag): blood pressure \(fmt(sys))/\(fmt(dia)) is not a cited reading")
            }
            let toks = tokens(rest)
            let allowedNumbers = numbers(values.flatMap(tokens))
            // a phrase that is part of a cited value ("IV" in "IV access") is the record's own words
            let valueText = " " + values.map(EMSText.normalizePhrase).joined(separator: " | ") + " "
            func inValues(_ p: String) -> Bool { valueText.contains(" \(p) ") }
            let oxygenCited = cited.contains { $0.fields["o2_on"] != nil }
            for v in numbers(toks) where !allowedNumbers.contains(v) {
                out.append("\(tag): number \(fmt(v)) is not in a cited event")
            }
            let allowedDrugs = Set(values.map(EMSText.normalizePhrase).compactMap { drugIndex($0) }).union(values.compactMap { drugIndex(EMSText.normalizePhrase($0)) })
            let allowedText = Set(values.map(EMSText.normalizePhrase))
            for p in phrases(toks) where !inValues(p) {
                if let di = drugIndex(p), !allowedDrugs.contains(di), !(oxygenCited && dict.drug(di).generic == "oxygen") {
                    out.append("\(tag): drug \(dict.drug(di).generic) is not in a cited event")
                }
                else if dict.homeMeds.contains(p), !allowedText.contains(p) { out.append("\(tag): medication \(p) is not in a cited event") }
                // a unit must have been heard: unit_suggested is the protocol's, not the medic's
                if let u = dict.unitIndex[p], p.contains(where: { $0.isLetter }), !cited.contains(where: { $0.fields["unit"] == u }),
                   !values.contains(where: { EMSText.normalizePhrase($0).split(separator: " ").contains(Substring(u.lowercased())) }) {
                    out.append("\(tag): unit \(u) was not heard in a cited event")
                }
                if let r = dict.routeIndex[p], !values.contains(where: { $0 == r || dict.routeIndex[EMSText.normalizePhrase($0)] == r }) {
                    out.append("\(tag): route \(r) is not in a cited event")
                }
            }
        }
        // the narrative replaces the template, so it may not leave out a medication or procedure
        let citedIds = Set(sentences.flatMap(\.events))
        let left = NarrativePass.eligible(events).filter { [.medication, .procedure].contains($0.type) && !citedIds.contains($0.id) }
        if !left.isEmpty { out.append("leaves out \(left.map(\.id).joined(separator: ", "))") }
        var unique: [String] = []
        for f in out where !unique.contains(f) { unique.append(f) }
        return unique
    }

    func fmt(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }

    static let bpRx = try! NSRegularExpression(pattern: #"\b(\d{2,3})\s*/\s*(\d{2,3})\b"#)
    /// Every "a/b" pair in the text, as numbers.
    static func pressures(_ s: String) -> [(Double, Double)] {
        let ns = s as NSString
        return bpRx.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let a = Double(ns.substring(with: m.range(at: 1))), let b = Double(ns.substring(with: m.range(at: 2))) else { return nil }
            return (a, b)
        }
    }

    func tokens(_ s: String) -> [String] {
        let (clean, _) = cleanup.clean(RawSegment(id: "n", startMs: 0, endMs: 0, text: s))
        return clean.tokens.map { $0.text.lowercased() }
    }

    func drugIndex(_ p: String) -> Int? { dict.aliasIndex[p] ?? dict.variantIndex[p] }

    func phrases(_ toks: [String]) -> [String] {
        var out: [String] = []
        let n = max(3, dict.maxAliasTokens)
        for i in toks.indices {
            for len in 1...n where i + len <= toks.count { out.append(toks[i..<(i + len)].joined(separator: " ")) }
        }
        return out
    }

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
}

/// The narrative pass: events in, cited sentences out, checked by `NarrativeChecker`.
public struct NarrativePass {
    let dict: EMSDictionary
    let llm: LLMEngine
    public init(dict: EMSDictionary, llm: LLMEngine) { self.dict = dict; self.llm = llm }

    public static let system = """
    You write the narrative section of an ambulance patient care report from a list of documented events. \
    Write short, plain, factual sentences in the past tense, in time order. Each sentence must list the ids of the \
    events it is based on, and may only state what those events contain: the same numbers, drug names, doses, \
    routes and times. Do not add anything else: no ages, weights, causes or reasons that are not in the events. \
    Write blood pressure as systolic/diastolic. Do not write event ids in the text, and give a clock time only for \
    medications, procedures and vital signs. Write a unit only when the event's unit is not "not said". Cover every \
    medication and procedure. Never name a diagnosis or a condition, never interpret, never give advice. \
    Use at most 16 sentences.
    """

    /// Event types that make sense in prose; taps, consent and gaps stay in the structured sections.
    static let types: Set<EventType> = [.vitals, .medication, .procedure, .status, .dispatch, .transport, .arrival, .handoff]
    /// Longest input the 4096-token context takes with room for the reply.
    static let maxInputChars = 7000

    struct InputEvent: Encodable { var id: String; var type: String; var time: String; var fields: [String: String] }

    /// Events the model may write about: heard or entered, not waiting for confirmation.
    public static func eligible(_ events: [EarshotEvent]) -> [EarshotEvent] {
        events.filter { types.contains($0.type) && !$0.needsConfirm && $0.fields["kind"] != "llm_unverified" }
    }

    public func run(events: [EarshotEvent], clock: CallClock, report: inout NarrativeReport) -> [NarrativeSentence]? {
        let use = Self.eligible(events)
        guard !use.isEmpty else { report.fallbackReason = "no events to narrate"; return nil }
        let input = use.map { e in
            var f = e.fields.filter { !NarrativeChecker.hiddenFields.contains($0.key) || $0.key == "kind" }
            // a dose with no spoken unit says so, so the model does not supply the usual one (input only)
            if e.type == .medication, f["dose"] != nil, f["unit"] == nil { f["unit"] = "not said" }
            return InputEvent(id: e.id, type: e.type.rawValue, time: String(clock.clock(e.tMs).prefix(5)), fields: f)
        }
        let user = LLMJSON.encode(["events": input])
        guard user.count <= Self.maxInputChars else { report.fallbackReason = "call too long for the model's context"; return nil }
        let reply: String
        do {
            reply = try llm.complete(system: Self.system, user: user, grammar: Self.grammar(ids: use.map(\.id)), maxTokens: 1400)
        } catch {
            report.fallbackReason = "model error: \(error)"; return nil
        }
        guard let data = LLMJSON.object(reply), let parsed = try? JSONDecoder().decode(NarrativeReply.self, from: data) else {
            report.fallbackReason = "reply is not valid JSON"; return nil
        }
        report.sentences = parsed.sentences
        let fails = NarrativeChecker(dict: dict).failures(parsed.sentences, events: events, clock: clock)
        guard fails.isEmpty else { report.failures = fails; report.fallbackReason = "checker failed"; return nil }
        report.used = true
        return parsed.sentences
    }

    public static func grammar(ids: [String]) -> String {
        """
        root ::= "{" ws "\\"sentences\\":" ws "[" ws sent (ws "," ws sent){0,15} ws "]" ws "}"
        sent ::= "{" ws "\\"text\\":" ws str ws "," ws "\\"events\\":" ws "[" ws eid (ws "," ws eid){0,7} ws "]" ws "}"
        eid ::= \(GBNF.oneOf(ids.isEmpty ? ["e1"] : ids))
        \(GBNF.common)
        """
    }
}
