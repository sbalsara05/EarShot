import Foundation

/// A pre-event extracted from one clean segment. Turned into `EarshotEvent`s
/// by the tap merger (which assigns IDs, times and sources).
public struct Finding: Equatable, Sendable {
    public var type: EventType
    public var fields: [String: String]
    public var receipts: [String: FieldReceipt]
    public var tMs: Int64
    public var rawSpan: String
    public var quote: String
    public var confidence: Double
    public var flags: [String]
    public var extractor: String
}

/// Regex helper over a clean segment's joined token text.
struct TokText {
    let seg: CleanSegment
    let text: String
    var starts: [Int] = []
    var ends: [Int] = []
    init(_ seg: CleanSegment) {
        self.seg = seg
        // Clause punctuation becomes " ;" and sentence ends " |" so patterns
        // using \s+ between words never run across a boundary.
        var s = ""
        for (i, t) in seg.tokens.enumerated() {
            if i > 0 { s += " " }
            starts.append(s.count); s += t.text; ends.append(s.count)
            if let p = t.punct { s += ".?!".contains(p) ? " |" : " ;" }
        }
        text = s
    }
    /// Token index range covering character range [a, b).
    func tokens(_ r: NSRange) -> ClosedRange<Int>? {
        guard r.location != NSNotFound, !seg.tokens.isEmpty else { return nil }
        let a = r.location, b = r.location + r.length
        guard let f = ends.firstIndex(where: { $0 > a }), let l = starts.lastIndex(where: { $0 < b }), f <= l else { return nil }
        return f...l
    }
    func receipt(_ r: ClosedRange<Int>, inferred: String? = nil) -> FieldReceipt {
        FieldReceipt(rawSpan: seg.rawSpan, quote: seg.quote(r.lowerBound, r.upperBound),
                     rawRange: [seg.tokens[r.lowerBound].rawStart, seg.tokens[r.upperBound].rawEnd], inferred: inferred)
    }
    func sub(_ r: NSRange) -> String { (text as NSString).substring(with: r) }
}

final class Rx {
    let re: NSRegularExpression
    init(_ p: String) { re = try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    func all(_ s: String) -> [NSTextCheckingResult] { re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)) }
}

public final class RulesExtractor {
    public static let version = "rules-v1"
    let dict: EMSDictionary
    public init(dict: EMSDictionary) {
        self.dict = dict
        var p: [String: (String, String)] = [:]
        var s: [String: (String, String)] = [:]
        for t in dict.terms.terms {
            let k = Text.normalizePhrase(t.term)
            switch t.category {
            case "procedure" where !RulesExtractor.ambiguousProcedures.contains(k): p[k] = (RulesExtractor.procName[t.expansion] ?? t.expansion, t.term)
            case "status" where !["priority one", "priority 1", "code", "postictal", "seizing", "unresponsive", "combative"].contains(k): s[k] = (t.term, "condition")   // keep the medic's own word, never a definition
            case "symptom": s[k] = (t.expansion, "symptom")
            default: break
            }
        }
        // extra procedure phrasings not in the term list
        for (k, v) in [("bagging", "BVM ventilation"), ("start bagging", "BVM ventilation"), ("bag him", "BVM ventilation"), ("bag her", "BVM ventilation"),
                       ("monitor on", "cardiac monitor"), ("on the monitor", "cardiac monitor"), ("hooked up to the monitor", "cardiac monitor"),
                       ("checking a sugar", "glucose check"), ("check her sugar", "glucose check"), ("check his sugar", "glucose check"),
                       ("check sugar", "glucose check"), ("check a glucose", "glucose check"), ("checking her glucose", "glucose check"),
                       ("saline lock", "intravenous access"), ("hep lock", "intravenous access"), ("put her on the monitor", "cardiac monitor"),
                       ("put him on the monitor", "cardiac monitor"), ("check a sugar", "glucose check"), ("checking her sugar", "glucose check"),
                       ("checking his sugar", "glucose check"), ("d stick", "glucose check"), ("finger stick", "glucose check"), ("dextro", "glucose check"),
                       ("neb going", "nebulizer"), ("starting a neb", "nebulizer"), ("breathing treatment", "nebulizer"), ("duoneb going", "nebulizer"),
                       ("vagal", "vagal maneuver"), ("vagal maneuver", "vagal maneuver"), ("modified valsalva", "vagal maneuver"), ("bear down", "vagal maneuver"),
                       ("be fast", "BE-FAST screen"), ("cincinnati", "Cincinnati scale"), ("stroke scale", "neuro screen"), ("lams", "LAMS score"),
                       ("signed the refusal", "refusal"), ("signed refusal", "refusal"), ("for the refusal", "refusal"), ("refusal against medical advice", "refusal"),
                       ("traction splint", "splinting"), ("refusal form", "refusal"), ("refusing transport", "refusal"), ("signed a refusal", "refusal"),
                       ("splinted", "splinting"), ("splint", "splinting"), ("suction", "suction"), ("suctioning", "suction"), ("cpr", "CPR"),
                       ("tourniquet on", "tourniquet"), ("npa", "NPA"),
                       ("started an iv", "intravenous access"), ("got an iv", "intravenous access"), ("iv in", "intravenous access"),
                       ("line in", "intravenous access"), ("got a line", "intravenous access"), ("shock delivered", "defibrillation"),
                       ("shocking", "defibrillation"), ("delivered a shock", "defibrillation"), ("starting compressions", "chest compressions"),
                       ("start compressions", "chest compressions"), ("12 lead", "12-lead ECG"), ("pads on", "defibrillation pads applied"),
                       ("on the monitor", "cardiac monitoring"), ("tube is in", "endotracheal intubation"), ("igel", "i-gel supraglottic airway"),
                       ("c collar", "cervical collar"), ("on cpap", "continuous positive airway pressure")] {
            p[Text.normalizePhrase(k)] = (RulesExtractor.procName[v] ?? v, k)
        }
        procLex = p; statusLex = s
        maxProcTokens = (p.keys.map { $0.split(separator: " ").count } + [1]).max()!
        maxStatusTokens = (s.keys.map { $0.split(separator: " ").count } + [1]).max()!
    }

    static let ambiguousProcedures: Set<String> = ["shock", "pacing", "tq"]
    /// Common EMS names for procedures (what a medic writes on the chart).
    static let procName: [String: String] = [
        "bag-valve-mask ventilation": "BVM ventilation", "intravenous access": "IV access", "intravenous access established": "IV access",
        "intraosseous access": "IO access", "EZ-IO intraosseous device": "IO access", "cardiopulmonary resuscitation": "CPR",
        "chest compressions": "CPR", "airway suctioning": "suction", "airway suctioned": "suction", "splint applied": "splinting",
        "tourniquet applied": "tourniquet", "tourniquet": "tourniquet", "nasopharyngeal airway": "NPA", "oropharyngeal airway": "OPA",
        "continuous positive airway pressure": "CPAP", "cervical collar": "cervical collar", "cervical collar applied": "cervical collar",
        "cardiac monitoring": "cardiac monitor", "electrocardiogram": "12-lead ECG", "12-lead ECG": "12-lead ECG",
        "endotracheal intubation": "intubation", "i-gel supraglottic airway": "supraglottic airway", "King LT supraglottic airway": "supraglottic airway",
        "supraglottic airway": "supraglottic airway", "needle chest decompression": "needle decompression", "defibrillation pads applied": "defibrillation pads",
        "transcutaneous pacing": "pacing", "synchronized cardioversion": "cardioversion", "synchronized cardioversion delivered": "cardioversion",
        "defibrillation delivered": "defibrillation", "oxygen applied": "oxygen", "spinal motion restriction": "spinal motion restriction",
    ]
    let procLex: [String: (String, String)]
    let statusLex: [String: (String, String)]
    let maxProcTokens: Int
    let maxStatusTokens: Int

    static let adminVerbs: Set<String> = ["gave", "given", "give", "giving", "administered", "administer", "administering", "pushed",
                                          "pushing", "push", "hung", "hanging", "started", "starting", "got", "spray", "sprayed",
                                          "dose", "repeat", "repeated", "another", "drew", "drawing", "ivp", "titrating", "bolus"]
    static let homeMedCues: Set<String> = ["takes", "taking", "prescribed", "home", "history", "uses", "regular", "daily", "prescription"]
    static let ptaCues: Set<String> = ["took", "before"]
    static let negCues: Set<String> = ["no", "not", "didn't", "don't", "held", "withheld", "hold", "holding", "refused", "declined",
                                       "without", "never", "denies", "deny", "negative", "won't", "didnt", "dont", "contraindicated"]

    public func extract(_ seg: CleanSegment) -> [Finding] {
        guard !seg.tokens.isEmpty else { return [] }
        let tt = TokText(seg)
        var out: [Finding] = []
        var used = Set<Int>()   // token indices consumed by vitals (so numbers aren't reused as doses)
        out += vitals(tt, &used)
        out += medications(tt, used: used)
        out += homeMeds(tt)
        if !out.contains(where: { $0.type == .medication && $0.fields["drug"] == "oxygen" }) { out += oxygenDevice(tt) }
        out += procedures(tt)
        out += statuses(tt)
        out += patientInfo(tt)
        out += assessmentFindings(tt)
        out += dispatch(tt)
        out += transport(tt)
        return out.sorted { ($0.tMs, $0.type.rawValue) < ($1.tMs, $1.type.rawValue) }
    }

    // MARK: vitals

    struct VitalRule {
        let fields: [String]; let rx: Rx; let ranges: [ClosedRange<Double>]; let conf: Double
        var groupOnly = false   // context may overlap an earlier vital ("104/66, rate 132"); only the value must be new
    }
    static let N = #"(?:is |of |was |at |now |about |around |reading |reads )?"#
    /// Up to 4 filler words between a vital name and its value ("sat's coming up, 95", "rate's down to 132").
    static let NF = #"(?:(?:is|are|was|of|at|now|about|around|reading|reads|coming|up|down|to|still|only|;)\s+){0,4}"#
    static let vitalRules: [VitalRule] = [
        VitalRule(fields: ["bp_systolic", "bp_diastolic"], rx: Rx(#"\b(?:bp|blood pressure|pressure|bps)\s+"# + N + #"(\d{2,3})/(\d{2,3})\b"#), ranges: [40...300, 20...200], conf: 0.92),
        VitalRule(fields: ["bp_systolic"], rx: Rx(#"\b(?:bp|blood pressure|pressure)\s+"# + N + #"(\d{2,3})\s+(?:by\s+)?palp"#), ranges: [40...300], conf: 0.88),
        VitalRule(fields: ["bp_systolic", "bp_diastolic"], rx: Rx(#"(?<![\w/])(\d{2,3})/(\d{2,3})(?![\w/])"#), ranges: [60...260, 30...160], conf: 0.7),
        VitalRule(fields: ["resp_rate"], rx: Rx(#"\b(?:rr|resps|resp|respirations|respiratory rate|resp rate|breathing|breathing at|respiration|ress|reps|resp's|respirations are|rest rate)\s+"# + #"(?:are |is |of |at |about |around )?(\d{1,2})\b"#), ranges: [2...70], conf: 0.88),
        VitalRule(fields: ["heart_rate"], rx: Rx(#"\b(?:hr|heart rate|pulse|pulse rate|pulses|heart rates)\s+"# + NF + #"(\d{2,3})\b"#), ranges: [20...260], conf: 0.9),
        // bare "rate N" right after a BP or sat reading ("Recheck, 104 over 66, rate 132"): heart rate when N > 40
        VitalRule(fields: ["heart_rate"], rx: Rx(#"(?:\d{2,3}/\d{2,3}|sats?\s+\d{2,3})\s*;?\s+(?:heart\s+)?rate\s+"# + NF + #"(\d{2,3})\b"#), ranges: [41...260], conf: 0.8, groupOnly: true),
        VitalRule(fields: ["heart_rate"], rx: Rx(#"(?<!resp |respiratory |breathing |drip |flow |infusion |pump )\brate\s+(?:is |at |of |now |down to |up to )?(\d{2,3})\b"#), ranges: [41...260], conf: 0.75),
        // "breathing, rate 14": respiratory rate when the sentence is about breathing and N <= 40
        VitalRule(fields: ["resp_rate"], rx: Rx(#"\bbreathing\s*;?\s+(?:rate|at)\s+"# + NF + #"(\d{1,2})\b"#), ranges: [2...40], conf: 0.8),
        VitalRule(fields: ["heart_rate"], rx: Rx(#"\b(?:tachy|tachycardic|brady|bradycardic|sinus tach|sinus brady|sinus|afib|tachycardia|bradycardia)\s+(?:at|in the|of)\s+(?:about\s+)?(\d{2,3})s?\b"#), ranges: [20...260], conf: 0.85),
        VitalRule(fields: ["spo2"], rx: Rx(#"\b(?:spo2|sats|sat|o2 sat|o2 sats|pulse ox|satting|sating|saturation|saturating|sats are|o2 saturation)\s+"# + NF + #"(\d{2,3})\b(?!\s*(?:lpm|l|liters))"#), ranges: [40...100], conf: 0.9),
        // ASR hears "sat 95" as "set 95" / "SAC's 95" (review R4-1): only at a sentence start or right after another vital
        VitalRule(fields: ["spo2"], rx: Rx(#"(?:^|\|\s+|(?:\d{2,3}(?:/\d{2,3})?|room air|ra)\s*;\s+)(?:set|sets|sac|sacs|sac's|satz|sad)\s+"# + NF + #"(\d{2,3})\b(?!\s*(?:lpm|l|liters|minutes|mins|seconds))"#), ranges: [70...100], conf: 0.7, groupOnly: true),
        VitalRule(fields: ["spo2"], rx: Rx(#"\b(\d{2,3})\s*(?:%)\s+(?:on\s+)?(?:room air|ra|\d+\s*lpm|nrb|nc|non rebreather|nasal cannula)"#), ranges: [40...100], conf: 0.85),
        VitalRule(fields: ["glucose"], rx: Rx(#"\b(?:bgl|cbg|glucose|sugar|blood sugar|blood glucose|d stick|dextro|accucheck|accu check|sugars)\s+"# + N + #"(\d{2,3}|high|hi|low|lo)\b"#), ranges: [10...700], conf: 0.88),
        VitalRule(fields: ["gcs"], rx: Rx(#"\bgcs\s+(?:is |of |was |a |at )?(\d{1,2})\b"#), ranges: [3...15], conf: 0.92),
        VitalRule(fields: ["etco2"], rx: Rx(#"\b(?:etco2|end tidal|capno|capnography|end tidal co2)\s+"# + N + #"(\d{1,3})\b"#), ranges: [0...150], conf: 0.88),
        VitalRule(fields: ["temp"], rx: Rx(#"\b(?:temp|temperature)\s+"# + N + #"(\d{2,3}(?:\.\d)?)\b"#), ranges: [25...110], conf: 0.85),
        VitalRule(fields: ["pain"], rx: Rx(#"\bpain\s+(?:is |of |at |score |scale |level )*(?:a |an )?(\d{1,2})(?:\s+out of\s+10|/10)?\b"#), ranges: [0...10], conf: 0.85),
        VitalRule(fields: ["pain"], rx: Rx(#"\b(\d{1,2})\s+out of\s+10\b"#), ranges: [0...10], conf: 0.75),
    ]
    static let aoRx = Rx(#"\ba&ox([1-4])\b"#)
    static let perrlRx = Rx(#"\b(perrla?|pupils equal(?: round)?(?: and)? reactive)\b"#)
    static let rhythmRx = Rx(#"\b(normal sinus rhythm|nsr|sinus rhythm|sinus tach(?:ycardia)?|sinus brady(?:cardia)?|afib(?: with rvr)?|atrial fibrillation|vfib|v fib|vtach|v tach|svt|pea|asystole)\b"#)
    static let o2onRx = Rx(#"\bon\s+(room air|ra|\d+\s*(?:lpm|l)(?:\s+(?:nrb|nc|non rebreather|nasal cannula|via nrb|via nc))?|nrb|non rebreather|nasal cannula|cpap)\b"#)

    /// All vitals in a segment. A field that repeats ("BP 120/80 … repeat BP
    /// 110/70") starts a new vitals event, so every reading is kept.
    func vitals(_ tt: TokText, _ used: inout Set<Int>) -> [Finding] {
        struct Hit { var fields: [String]; var vals: [String]; var tr: ClosedRange<Int>; var conf: Double; var extra: [String: String] }
        var hits: [Hit] = []
        for rule in RulesExtractor.vitalRules {
            for m in rule.rx.all(tt.text) {
                guard var tr = tt.tokens(m.range) else { continue }
                if rule.groupOnly, let gr = tt.tokens(m.range(at: 1)) { tr = gr }
                if tr.contains(where: { used.contains($0) }) { continue }
                var vals: [String] = []
                var ok = true
                for (gi, _) in rule.fields.enumerated() {
                    let v = tt.sub(m.range(at: gi + 1))
                    if let d = Double(v), !rule.ranges[gi].contains(d) { ok = false; break }
                    vals.append(v)
                }
                if rule.fields.count == 2, let s = Double(vals.first ?? ""), let d = Double(vals.last ?? ""), s <= d { ok = false }
                guard ok, vals.count == rule.fields.count else { continue }
                for k in tr { used.insert(k) }
                hits.append(Hit(fields: rule.fields, vals: vals, tr: tr, conf: rule.conf,
                                extra: rule.fields == ["bp_systolic"] ? ["bp_method": "palpation"] : [:]))
            }
        }
        func simple(_ rx: Rx, _ field: String, _ map: (String) -> String) {
            for m in rx.all(tt.text) {
                guard let tr = tt.tokens(m.range) else { continue }
                hits.append(Hit(fields: [field], vals: [map(tt.sub(m.range(at: 1)))], tr: tr, conf: 0.9, extra: [:]))
            }
        }
        simple(RulesExtractor.aoRx, "mental_status") { "A&O×\($0)" }
        simple(RulesExtractor.perrlRx, "pupils") { _ in "PERRL" }
        let hasCore = !hits.isEmpty
        if hasCore { simple(RulesExtractor.o2onRx, "o2_on") { $0 } }
        hits.sort { $0.tr.lowerBound < $1.tr.lowerBound }
        // group in speaking order; a repeated field opens a new group
        var groups: [[Hit]] = []
        for h in hits {
            if groups.isEmpty || groups[groups.count - 1].contains(where: { g in g.fields.contains { h.fields.contains($0) } }) {
                if h.fields == ["o2_on"], !groups.isEmpty { groups[groups.count - 1].append(h); continue }
                groups.append([h])
            } else { groups[groups.count - 1].append(h) }
        }
        return groups.compactMap { g in
            var fields: [String: String] = [:]
            var rec: [String: FieldReceipt] = [:]
            for h in g {
                for (i, f) in h.fields.enumerated() { fields[f] = h.vals[i]; rec[f] = tt.receipt(h.tr) }
                for (k, v) in h.extra { fields[k] = v; rec[k] = tt.receipt(h.tr) }
            }
            if fields.keys.allSatisfy({ $0 == "o2_on" }) { return nil }
            let lo = g.map(\.tr.lowerBound).min()!, hi = g.map(\.tr.upperBound).max()!
            return Finding(type: .vitals, fields: fields, receipts: rec, tMs: tt.seg.timeOf(token: lo), rawSpan: tt.seg.rawSpan,
                           quote: tt.seg.quote(lo, hi), confidence: g.map(\.conf).min()!, flags: [], extractor: RulesExtractor.version)
        }
    }

    // MARK: medications

    struct DrugHit { let drug: Int; let range: ClosedRange<Int>; let conf: Double; let how: String }

    static let callSignWords: Set<String> = ["medic", "rescue", "engine", "ambulance", "ladder", "squad", "unit", "car", "truck", "battalion", "station", "md"]

    func drugHits(_ tt: TokText, used: Set<Int> = []) -> [DrugHit] {
        let toks = tt.seg.tokens
        var hits: [DrugHit] = []
        var i = 0
        while i < toks.count {
            var found: DrugHit? = nil
            // never a drug: tokens already read as a vital, or a unit call sign ("Medic 14")
            if used.contains(i) || (RulesExtractor.callSignWords.contains(toks[i].text) && i + 1 < toks.count && isNumber(toks[i + 1].text)) {
                i += 1; continue
            }
            for n in stride(from: min(dict.maxAliasTokens, toks.count - i), through: 1, by: -1) {
                let phrase = toks[i..<(i + n)].map(\.text).joined(separator: " ")
                if let di = dict.aliasIndex[phrase] {
                    let rule = toks[i].rule
                    let conf = rule == "formulary:asr_variant" ? 0.75 : rule == "formulary:fuzzy" ? 0.65 : 0.9
                    if dict.contextRequired.contains(phrase) && !hasMedContext(toks, i, i + n - 1) { break }
                    // spelling corrections from cleanup need real medication context nearby
                    if (rule == "formulary:asr_variant" || rule == "formulary:fuzzy") && !RulesExtractor.hasDoseOrRoute(toks.map(\.text), i, dict) { break }
                    found = DrugHit(drug: di, range: i...(i + n - 1), conf: conf, how: rule ?? "alias")
                    break
                }
            }
            if found == nil, toks[i].text.count >= 5, toks[i].text.allSatisfy({ $0.isLetter }), dict.termIndex[toks[i].text] == nil,
               RulesExtractor.hasDoseOrRoute(toks.map(\.text), i, dict) {
                // Exact sound-alike only, and the heard word must also be spelled close to a real
                // name of that drug (same first letter, >= 60% letters). No edit-distance-1 keys:
                // "pressure" ~ Lopressor and "Memorial" ~ Medrol were wrong (review R3-1).
                let key = Phonetic.key(toks[i].text)
                if let ds = dict.phoneticIndex[key], ds.count == 1 {
                    let d = dict.drug(ds[0])
                    let w = toks[i].text
                    let close = ([d.generic] + d.slang + d.brands + d.aliases).contains { a in
                        let al = a.lowercased(); return al.first == w.first && Text.similarity(w, al) >= 0.6
                    }
                    if close { found = DrugHit(drug: ds[0], range: i...i, conf: 0.55, how: "phonetic") }
                }
            }
            if let f = found { hits.append(f); i = f.range.upperBound + 1 } else { i += 1 }
        }
        return hits
    }

    func isNumber(_ s: String) -> Bool { Double(s) != nil }

    /// Stricter context for sound-alike matches: a dose unit, route or
    /// administration verb within 3 tokens (a bare number is not enough).
    func hasStrongMedContext(_ toks: [CleanToken], _ i: Int) -> Bool {
        let lo = max(0, i - 3), hi = min(toks.count - 1, i + 3)
        for k in lo...hi where k != i {
            let t = toks[k].text
            if dict.formulary.units[t] != nil || RulesExtractor.adminVerbs.contains(t) || ["po", "sl", "iv", "io", "im", "sq", "neb"].contains(t) { return true }
        }
        return false
    }

    /// For anything that is not an exact drug name (ASR variant, fuzzy, sound-alike):
    /// a dose unit, a route, or a number followed by a unit within 4 tokens.
    /// An administration verb alone is not enough ("give me 2 seconds").
    static func hasDoseOrRoute(_ t: [String], _ i: Int, _ dict: EMSDictionary) -> Bool {
        let lo = max(0, i - 4), hi = min(t.count - 1, i + 4)
        guard lo <= hi else { return false }
        let routes: Set<String> = ["po", "sl", "iv", "io", "im", "sq", "neb", "in", "ivp", "sublingual", "intranasal", "intravenous", "intramuscular", "chewed", "nebulized"]
        for k in lo...hi where k != i {
            if dict.formulary.units[t[k]] != nil || routes.contains(t[k]) { return true }
            if Double(t[k]) != nil, k + 1 <= hi, dict.unitIndex[t[k + 1]] != nil, !["l", "u", "in"].contains(t[k + 1]) { return true }
        }
        return false
    }

    func hasMedContext(_ toks: [CleanToken], _ a: Int, _ b: Int) -> Bool {
        let lo = max(0, a - 5), hi = min(toks.count - 1, b + 5)
        for k in lo...hi where k < a || k > b {
            let t = toks[k].text
            if isNumber(t) || dict.unitIndex[t] != nil || RulesExtractor.adminVerbs.contains(t) || ["po", "sl", "iv", "io", "im", "sq", "neb", "mg", "mcg"].contains(t) { return true }
        }
        return false
    }

    // Clause helpers: a token's `punct` marks a boundary after it.
    func sentenceEnd(_ toks: [CleanToken], _ i: Int) -> Int {
        var k = i; while k < toks.count - 1 { if let p = toks[k].punct, ".?!".contains(p) { return k }; k += 1 }; return toks.count - 1
    }
    func sentenceStart(_ toks: [CleanToken], _ i: Int) -> Int {
        var k = i - 1; while k >= 0 { if let p = toks[k].punct, ".?!".contains(p) { return k + 1 }; k -= 1 }; return 0
    }
    func clauseStart(_ toks: [CleanToken], _ i: Int) -> Int {
        var k = i - 1; while k >= 0 { if toks[k].punct != nil { return k + 1 }; k -= 1 }; return 0
    }
    func clauseEnd(_ toks: [CleanToken], _ i: Int) -> Int {
        var k = i; while k < toks.count - 1 { if toks[k].punct != nil { return k }; k += 1 }; return toks.count - 1
    }

    static let notDoseBefore: Set<String> = ["times", "x", "by", "every", "q", "times", "over", "for"]
    static let notDoseAfter: Set<String> = ["year", "years", "yo", "minutes", "minute", "min", "mins", "seconds", "hours", "hour", "times", "%",
                                            "percent", "kilos", "kg", "pounds", "lbs", "days", "weeks", "months", "beats", "bpm", "liters"]
    static let postNeg: Set<String> = ["held", "withheld", "refused", "declined", "hold", "holding", "contraindicated", "deferred"]

    func medications(_ tt: TokText, used: Set<Int>) -> [Finding] {
        let toks = tt.seg.tokens
        let hits = drugHits(tt, used: used)
        var out: [Finding] = []
        for (hi, h) in hits.enumerated() {
            let d = dict.drug(h.drug)
            let a0 = h.range.lowerBound, b0 = h.range.upperBound
            let prevEnd = hi > 0 ? hits[hi - 1].range.upperBound + 1 : 0
            let nextStart = hi + 1 < hits.count ? hits[hi + 1].range.lowerBound - 1 : toks.count - 1
            let sStart = sentenceStart(toks, a0), sEnd = sentenceEnd(toks, b0)
            let cStart = clauseStart(toks, a0), cEnd = clauseEnd(toks, b0)
            let lo = max(prevEnd, sStart, a0 - 5), hiW = min(nextStart, sEnd, b0 + 7)
            var fields: [String: String] = ["drug": d.generic]
            var rec: [String: FieldReceipt] = ["drug": tt.receipt(h.range)]
            var flags: [String] = []
            var span = h.range
            if h.how != "alias" { flags.append("confirm") }   // sound-alike / misspelling / fuzzy: always confirm
            if h.conf < 0.7 { flags.append("confirm") }
            if Text.normalizePhrase(d.generic) != toks[a0].text || h.range.count > 1 || h.how != "alias" {
                fields["drug_as_heard"] = tt.seg.quote(a0, b0)
            }
            // cues before the drug, inside its own clause only
            let beforeIdx = Array(max(cStart, a0 - 4)..<a0)
            let before = beforeIdx.map { toks[$0].text }
            let postEnd = min(cEnd, b0 + 4)
            let after: [String] = postEnd > b0 ? toks[(b0 + 1)...postEnd].map(\.text) : []
            let negated = before.suffix(3).contains { RulesExtractor.negCues.contains($0) }
                || after.contains { RulesExtractor.postNeg.contains($0) }
                || (after.count >= 2 && after[0] == "not" && ["given", "administered", "indicated"].contains(after[1]))
            // allergy only when "allergic to X" / "allergy to X" / "allergies to X" sits right before the drug
            let allergy = before.count >= 2 && before.last == "to" && before[before.count - 2].hasPrefix("allerg")
            func cueBeforeWithoutAdmin(_ cues: (String) -> Bool) -> Bool {
                guard let ci = beforeIdx.lastIndex(where: { cues(toks[$0].text) }) else { return false }
                return !toks[(ci + 1)..<a0].contains { RulesExtractor.adminVerbs.contains($0.text) }
            }
            let homeMed = cueBeforeWithoutAdmin { RulesExtractor.homeMedCues.contains($0) }
                || before.suffix(2) == ["is", "on"] || before.suffix(2) == ["she's", "on"] || before.suffix(2) == ["he's", "on"] || before.suffix(1) == ["on"] && before.count >= 2 && ["she", "he", "they", "patient", "pt"].contains(before[before.count - 2])
            let pta = cueBeforeWithoutAdmin { RulesExtractor.ptaCues.contains($0) }
            // dose: number (+ unit) after the drug within the sentence, or "<n> <unit> of <drug>" / "<n> of <drug>"
            var amount: (String, ClosedRange<Int>)? = nil
            var unit: (String, ClosedRange<Int>)? = nil
            var k = b0 + 1
            while k <= hiW {
                if !used.contains(k), isNumber(toks[k].text),
                   !(k > 0 && RulesExtractor.notDoseBefore.contains(toks[k - 1].text)),
                   !(k + 1 < toks.count && RulesExtractor.notDoseAfter.contains(toks[k + 1].text)) {
                    amount = (toks[k].text, k...k)
                    if k + 1 <= hiW, let u = unitOf(toks[k + 1].text) { unit = (u, (k + 1)...(k + 1)) }
                    break
                }
                if toks[k].punct != nil && k > b0 + 1 { break }   // dose stays in the drug's clause (allow "aspirin, 324")
                k += 1
            }
            if amount == nil {
                var j = a0 - 1
                if j >= lo && toks[j].text == "of" { j -= 1 }
                if j >= lo, let u = unitOf(toks[j].text), j - 1 >= lo, isNumber(toks[j - 1].text), !used.contains(j - 1) {
                    amount = (toks[j - 1].text, (j - 1)...(j - 1)); unit = (u, j...j)
                } else if j >= lo, isNumber(toks[j].text), !used.contains(j), a0 >= 1, toks[a0 - 1].text == "of" {
                    amount = (toks[j].text, j...j)
                } else if a0 >= 1, a0 - 1 >= sStart, isNumber(toks[a0 - 1].text), !used.contains(a0 - 1), toks[a0 - 1].punct == nil,
                          !(a0 >= 2 && RulesExtractor.notDoseBefore.contains(toks[a0 - 2].text)) {
                    amount = (toks[a0 - 1].text, (a0 - 1)...(a0 - 1))   // "10 Valium rectal"
                }
            }
            if let a = amount {
                fields["dose"] = a.0; rec["dose"] = tt.receipt(a.1); span = min(span.lowerBound, a.1.lowerBound)...max(span.upperBound, a.1.upperBound)
                if let u = unit {
                    fields["unit"] = u.0; rec["unit"] = tt.receipt(u.1); span = min(span.lowerBound, u.1.lowerBound)...max(span.upperBound, u.1.upperBound)
                } else {
                    // Unit not spoken: never filled. If the amount matches exactly one
                    // protocol dose, offer it as a suggestion the medic can accept.
                    let units = Set(d.typical_doses.filter { $0.amount == a.0 }.map(\.unit))
                    if units.count == 1, let u = units.first { fields["unit_suggested"] = u }
                }
            }
            // route (same sentence; may cross a comma: "324 of aspirin, chewed")
            var routeHit = route(toks, lo, hiW, drug: d)
            if routeHit == nil, hi + 1 < hits.count, hiW + 1 < toks.count, toks[(b0 + 1)...max(b0 + 1, min(hiW + 1, toks.count - 1))].contains(where: { $0.text == "and" }) {
                routeHit = route(toks, hits[hi + 1].range.upperBound + 1, sEnd, drug: d)   // route said once for both drugs
            }
            if let (r, rr, heard) = routeHit {
                fields["route"] = r; rec["route"] = tt.receipt(rr); span = min(span.lowerBound, rr.lowerBound)...max(span.upperBound, rr.upperBound)
                if let w = heard { fields["route_as_heard"] = w }
            }
            let admin = toks[lo...hiW].contains { RulesExtractor.adminVerbs.contains($0.text) }
            var type = EventType.medication
            if allergy {
                type = .status; fields = ["kind": "allergy", "allergy": d.generic]; rec = ["allergy": rec["drug"]!]
            } else if negated {
                type = .status; fields["kind"] = "med_not_given"
            } else if homeMed && amount == nil {
                type = .status; fields["kind"] = "home_med"
            } else if pta {
                type = .status; fields["kind"] = "prior_to_arrival_med"
            } else if amount == nil && !admin {
                type = .status; fields["kind"] = "drug_mention"; flags.append("confirm")
            }
            if h.how == "phonetic" && (type != .medication || fields["dose"] == nil) { continue }
            if d.high_alert && type == .medication && fields["dose"] == nil { flags.append("confirm") }
            out.append(Finding(type: type, fields: fields, receipts: rec, tMs: tt.seg.timeOf(token: a0), rawSpan: tt.seg.rawSpan,
                               quote: tt.seg.quote(span.lowerBound, span.upperBound), confidence: h.conf, flags: Array(Set(flags)).sorted(),
                               extractor: RulesExtractor.version + (h.how == "alias" ? "" : ":" + h.how)))
        }
        return out
    }

    /// Oxygen named by its device: "non-rebreather at 15 liters", "2 liters nasal cannula".
    static let o2Devices: [(String, String)] = [("non rebreather", "NRB"), ("nrb", "NRB"), ("now we're breather", "NRB"), ("now we are breather", "NRB"),
        ("non rib breather", "NRB"), ("non re breather", "NRB"), ("nonrebreather", "NRB"), ("now rebreather", "NRB"), ("non breather", "NRB"), ("nasal cannula", "NC"), ("nasal canula", "NC"), ("blow by", "BLOWBY")]
    func oxygenDevice(_ tt: TokText) -> [Finding] {
        let toks = tt.seg.tokens
        let texts = toks.map(\.text)
        guard let d = dict.drug(named: "oxygen") else { return [] }
        for (phrase, route) in RulesExtractor.o2Devices {
            let w = phrase.split(separator: " ").map(String.init)
            guard w.count <= texts.count else { continue }
            for i in 0...(texts.count - w.count) where Array(texts[i..<(i + w.count)]) == w {
                if i > 0 && texts[i - 1] == "on" && i > 1 && ["room", "sats", "sat"].contains(texts[i - 2]) { continue }
                let r = i...(i + w.count - 1)
                var fields = ["drug": d.generic, "route": route, "route_as_heard": tt.seg.quote(r.lowerBound, r.upperBound)]
                var rec: [String: FieldReceipt] = ["drug": tt.receipt(r), "route": tt.receipt(r)]
                var span = r
                let lo = max(clauseStart(toks, i), i - 4), hi = min(sentenceEnd(toks, r.upperBound), r.upperBound + 4)
                for k in lo...hi where !r.contains(k) && isNumber(texts[k]) {
                    if let v = Double(texts[k]), v >= 0.5, v <= 25 {
                        fields["dose"] = texts[k]; rec["dose"] = tt.receipt(k...k)
                        if k + 1 < texts.count, let u = unitOf(texts[k + 1]) ?? (["liters", "l", "lpm", "liter"].contains(texts[k + 1]) ? "lpm" : nil) {
                            fields["unit"] = u == "l" ? "lpm" : u; rec["unit"] = tt.receipt((k + 1)...(k + 1))
                            span = min(span.lowerBound, k)...max(span.upperBound, k + 1)
                        } else { span = min(span.lowerBound, k)...max(span.upperBound, k) }
                        break
                    }
                }
                return [Finding(type: .medication, fields: fields, receipts: rec, tMs: tt.seg.timeOf(token: i), rawSpan: tt.seg.rawSpan,
                                quote: tt.seg.quote(span.lowerBound, span.upperBound), confidence: 0.85, flags: [], extractor: RulesExtractor.version + ":o2device")]
            }
        }
        return []
    }

    /// Home medications that EMS does not carry (lisinopril, Eliquis…): only in
    /// home-med context ("takes", "on", "prescribed", "home meds") in the same clause.
    func homeMeds(_ tt: TokText) -> [Finding] {
        let toks = tt.seg.tokens
        var out: [Finding] = []
        for (i, t) in toks.enumerated() where dict.homeMeds.contains(t.text) && dict.aliasIndex[t.text] == nil {
            let before = toks[max(clauseStart(toks, i), i - 6)..<i].map(\.text)
            let cue = before.contains { RulesExtractor.homeMedCues.contains($0) || ["on", "meds", "medications", "medication"].contains($0) }
            guard cue else { continue }
            out.append(Finding(type: .status, fields: ["kind": "home_med", "drug": t.text], receipts: ["drug": tt.receipt(i...i)],
                               tMs: tt.seg.timeOf(token: i), rawSpan: tt.seg.rawSpan, quote: tt.seg.quote(max(clauseStart(toks, i), i - 6), i),
                               confidence: 0.8, flags: [], extractor: RulesExtractor.version))
        }
        return out
    }

    func unitOf(_ t: String) -> String? {
        if dict.formulary.units[t] != nil { return t }
        if let u = dict.unitIndex[t], !["l", "u", "in"].contains(t) { return u }
        return nil
    }

    static let routeWords: [String: String] = ["chewed": "PO", "chew": "PO", "chewable": "PO", "swallow": "PO", "push": "IV", "pushed": "IV",
                                               "ivp": "IV", "drip": "IV", "spray": "IN", "atomized": "IN", "nostril": "IN", "nose": "IN",
                                               "thigh": "IM", "deltoid": "IM", "tongue": "SL", "neb": "NEB", "nebulizer": "NEB", "patch": "TD", "rectal": "PR", "rectally": "PR"]
    static let routePhrasesExtra: [String: String] = ["through the line": "IV", "in the line": "IV", "via the line": "IV", "down the line": "IV", "into the line": "IV"]
    func route(_ toks: [CleanToken], _ lo: Int, _ hi: Int, drug: Drug) -> (String, ClosedRange<Int>, String?)? {
        guard lo <= hi else { return nil }
        for k in lo...hi {
            for n in stride(from: min(4, hi - k + 1), through: 1, by: -1) {
                let phrase = toks[k..<(k + n)].map(\.text).joined(separator: " ")
                if (phrase == "in" || phrase == "et") && toks[k].rule != "route:normalize" { continue }  // ambiguous unless cleanup normalized it
                if let r = dict.routeIndex[phrase] ?? RulesExtractor.routePhrasesExtra[phrase] ?? (n == 1 ? RulesExtractor.routeWords[phrase] : nil) {
                    if r == "IV" && (phrase == "push" || phrase == "pushed") && !drug.routes.contains("IV") { continue }
                    let heard: String? = phrase == r.lowercased() ? nil : phrase   // e.g. "chewed" -> PO is shown as heard
                    return (r, k...(k + n - 1), heard)
                }
            }
        }
        return nil
    }

    // MARK: procedures

    static let ivRx = Rx(#"\b(1[4-9]|2[0-4])\s*(?:gauge)\b(?:\s+(?:iv|in the|in))?(?:\s+(?:the\s+)?(left|right|l|r))?\s*(ac|antecubital|hand|forearm|wrist|ej|external jugular|arm)?"#)
    static let ivSiteRx = Rx(#"\b(1[4-9]|2[0-4])\s+(?:gauge\s+)?(?:iv\s+)?(?:;\s+)?(?:in the\s+|in\s+)?(left|right)\s+(ac|antecubital|hand|forearm|wrist|ej|external jugular|arm)\b"#)
    static let joulesRx = Rx(#"\b(?:shock(?:ed|ing)?|defib(?:rillated)?|cardioverted|cardiovert)\s+(?:at\s+)?(\d{2,3})\s*(?:joules|j)\b"#)

    func procedures(_ tt: TokText) -> [Finding] {
        let toks = tt.seg.tokens
        var out: [Finding] = []
        var taken = Set<Int>()
        for m in RulesExtractor.ivSiteRx.all(tt.text) + RulesExtractor.ivRx.all(tt.text) {
            guard let tr = tt.tokens(m.range), !tr.contains(where: { taken.contains($0) }) else { continue }
            var f: [String: String] = ["procedure": "IV access", "gauge": tt.sub(m.range(at: 1))]
            if m.range(at: 2).location != NSNotFound || m.range(at: 3).location != NSNotFound {
                let side = m.range(at: 2).location != NSNotFound ? tt.sub(m.range(at: 2)) : ""
                let site = m.range(at: 3).location != NSNotFound ? tt.sub(m.range(at: 3)) : ""
                f["site"] = [side, site].filter { !$0.isEmpty }.joined(separator: " ").uppercased().replacingOccurrences(of: "LEFT", with: "left").replacingOccurrences(of: "RIGHT", with: "right")
            }
            var rec: [String: FieldReceipt] = [:]
            for k in f.keys { rec[k] = tt.receipt(tr) }
            for k in tr { taken.insert(k) }
            out.append(Finding(type: .procedure, fields: f, receipts: rec, tMs: tt.seg.timeOf(token: tr.lowerBound), rawSpan: tt.seg.rawSpan,
                               quote: tt.seg.quote(tr.lowerBound, tr.upperBound), confidence: 0.88, flags: [], extractor: RulesExtractor.version))
        }
        for m in RulesExtractor.joulesRx.all(tt.text) {
            guard let tr = tt.tokens(m.range) else { continue }
            for k in tr { taken.insert(k) }
            let f = ["procedure": "defibrillation", "energy_j": tt.sub(m.range(at: 1))]
            out.append(Finding(type: .procedure, fields: f, receipts: ["procedure": tt.receipt(tr), "energy_j": tt.receipt(tr)],
                               tMs: tt.seg.timeOf(token: tr.lowerBound), rawSpan: tt.seg.rawSpan, quote: tt.seg.quote(tr.lowerBound, tr.upperBound),
                               confidence: 0.88, flags: [], extractor: RulesExtractor.version))
        }
        var i = 0
        var seen = Set<String>()
        while i < toks.count {
            var adv = 1
            if !taken.contains(i) {
                for n in stride(from: min(maxProcTokens, toks.count - i), through: 1, by: -1) {
                    let phrase = toks[i..<(i + n)].map(\.text).joined(separator: " ")
                    if let (canon, _) = procLex[phrase] {
                        if i + n < toks.count && toks[i + n].text == "time" { adv = n; break }   // "tourniquet time 02:34" is a finding
                        let before = toks[max(clauseStart(toks, i), i - 3)..<i].map(\.text)
                        let neg = before.contains { RulesExtractor.negCues.contains($0) }
                        if !seen.contains(canon) {
                            seen.insert(canon)
                            let tr = i...(i + n - 1)
                            var f = ["procedure": canon]
                            if neg { f["kind"] = "not_done" }
                            out.append(Finding(type: neg ? .status : .procedure, fields: f, receipts: ["procedure": tt.receipt(tr)],
                                               tMs: tt.seg.timeOf(token: i), rawSpan: tt.seg.rawSpan, quote: tt.seg.quote(i, i + n - 1),
                                               confidence: 0.85, flags: [], extractor: RulesExtractor.version))
                        }
                        adv = n; break
                    }
                }
            }
            i += adv
        }
        return out
    }

    // MARK: status (condition, symptoms, history)

    func statuses(_ tt: TokText) -> [Finding] {
        let toks = tt.seg.tokens
        var out: [Finding] = []
        var i = 0
        var seen = Set<String>()
        while i < toks.count {
            var adv = 1
            for n in stride(from: min(maxStatusTokens, toks.count - i), through: 1, by: -1) {
                let phrase = toks[i..<(i + n)].map(\.text).joined(separator: " ")
                guard let (exp, kind) = statusLex[phrase] else { continue }
                // "code" / "stable" etc. are common words; require them not to be part of a bigger phrase handled elsewhere
                if phrase == "code" && i + 1 < toks.count && ["3", "2", "1", "blue", "status"].contains(toks[i + 1].text) { break }
                if phrase == "stable" && i > 0 && ["hemodynamically"].contains(toks[i - 1].text) == false && i + 1 < toks.count && toks[i + 1].text == "angina" { break }
                let before = toks[max(clauseStart(toks, i), i - 3)..<i].map(\.text)
                let neg = before.contains { RulesExtractor.negCues.contains($0) } || (before.last == "longer")
                let key = kind + ":" + exp + (neg ? ":neg" : "")
                if !seen.contains(key) {
                    seen.insert(key)
                    let tr = (neg ? max(0, i - min(3, before.count)) : i)...(i + n - 1)
                    var f: [String: String] = ["kind": kind, kind == "condition" ? "condition" : kind: exp]
                    if neg { f["negated"] = "true" }
                    let key2 = kind == "condition" ? "condition" : kind
                    out.append(Finding(type: .status, fields: f, receipts: [key2: tt.receipt(tr)], tMs: tt.seg.timeOf(token: i),
                                       rawSpan: tt.seg.rawSpan, quote: tt.seg.quote(tr.lowerBound, tr.upperBound), confidence: 0.8, flags: [],
                                       extractor: RulesExtractor.version))
                }
                adv = n; break
            }
            i += adv
        }
        return out
    }

    // MARK: assessment findings (what the crew observed, in their words)

    static let findingLex: [(String, String)] = [
        ("slurred speech", "slurred speech"), ("facial droop", "facial droop"), ("arm drift", "arm drift"), ("pinpoint pupils", "pinpoint pupils"),
        ("pupils pinpoint", "pinpoint pupils"), ("pupils are pinpoint", "pinpoint pupils"), ("tripoding", "tripoding"), ("tripod", "tripoding"),
        ("wheezes", "wheezes"), ("wheezing", "wheezes"), ("actively seizing", "actively seizing"), ("still seizing", "actively seizing"),
        ("postictal", "postictal"), ("post ictal", "postictal"), ("rales", "rales"), ("crackles", "crackles"), ("stridor", "stridor"),
        ("diminished breath sounds", "diminished breath sounds"), ("accessory muscle use", "accessory muscle use"), ("retractions", "retractions"),
        ("jvd", "JVD"), ("pedal edema", "pedal edema"), ("cyanotic", "cyanotic"), ("mottled", "mottled"), ("unresponsive", "unresponsive"),
        ("combative", "combative"), ("pale cool and diaphoretic", "pale, cool and diaphoretic"), ("pale cool and sweaty", "pale, cool and diaphoretic"), ("pale cool diaphoretic", "pale, cool and diaphoretic"),
        ("pale cool and clammy", "pale, cool and clammy"), ("pale cool clammy", "pale, cool and clammy"), ("diaphoretic", "diaphoretic"),
        ("pink warm and dry", "pink, warm and dry"), ("pink warm dry", "pink, warm and dry"),
    ]
    static let clockTime = #"((?:0\s+)?\d{1,2}(?:[:\s]\d{2})?|\d{3,4})"#
    static let lkwRx = Rx(#"\b(?:last known well|lkw|last seen normal)\s+(?:at\s+|was\s+|is\s+|around\s+)?(?:oh\s+)?"# + clockTime + #"\b"#)
    static let tqTimeRx = Rx(#"\btourniquet\s+(?:time\s+|on at\s+|on\s+|at\s+|applied at\s+)(?:oh\s+)?"# + clockTime + #"\b"#)

    func hhmm(_ s: String) -> String {
        let digits = s.filter(\.isNumber)
        guard digits.count >= 3 else { return digits.count <= 2 ? String(format: "%02d:00", Int(digits) ?? 0) : s }
        let h = String(digits.dropLast(2)), m = String(digits.suffix(2))
        return String(format: "%02d:%@", Int(h) ?? 0, m)
    }

    func assessmentFindings(_ tt: TokText) -> [Finding] {
        let toks = tt.seg.tokens
        let texts = toks.map(\.text)
        var out: [Finding] = []
        var seen = Set<String>()
        func add(_ term: String, _ r: ClosedRange<Int>, negated: Bool = false) {
            guard !seen.contains(term) else { return }
            seen.insert(term)
            var f = ["kind": "finding", "term": term]
            if negated { f["negated"] = "true" }
            out.append(Finding(type: .status, fields: f, receipts: ["term": tt.receipt(r)], tMs: tt.seg.timeOf(token: r.lowerBound),
                               rawSpan: tt.seg.rawSpan, quote: tt.seg.quote(r.lowerBound, r.upperBound), confidence: 0.8, flags: [], extractor: RulesExtractor.version))
        }
        var consumed = Set<Int>()
        for (phrase, term) in RulesExtractor.findingLex.sorted(by: { $0.0.count > $1.0.count }) {
            let w = phrase.split(separator: " ").map(String.init)
            var i = 0
            while i + w.count <= texts.count {
                if Array(texts[i..<(i + w.count)]) == w && !(i..<(i + w.count)).contains(where: { consumed.contains($0) }) {
                    for k in i..<(i + w.count) { consumed.insert(k) }
                    let before = texts[max(clauseStart(toks, i), i - 3)..<i]
                    add(term, i...(i + w.count - 1), negated: before.contains { RulesExtractor.negCues.contains($0) })
                    i += w.count
                } else { i += 1 }
            }
        }
        for m in RulesExtractor.lkwRx.all(tt.text) {
            guard let tr = tt.tokens(m.range) else { continue }
            add("last known well " + hhmm(tt.sub(m.range(at: 1))), tr)
        }
        for m in RulesExtractor.tqTimeRx.all(tt.text) {
            guard let tr = tt.tokens(m.range) else { continue }
            add("tourniquet time " + hhmm(tt.sub(m.range(at: 1))), tr)
        }
        return out
    }

    // MARK: patient info

    static let ageRx = Rx(#"\b(\d{1,3})\s*(?:year|yr|years|yrs)\s*old\b(?:\s+(male|female|man|woman|boy|girl|gentleman|lady))?"#)
    static let ageShortRx = Rx(#"\b(\d{1,3})\s*(yom|yof|yo m|yo f|y o m|y o f)\b"#)
    static let ageMonthsRx = Rx(#"\b(\d{1,2})\s*(?:month|months|mo)\s*old\b"#)
    static let sexRx = Rx(#"\b(male|female)\s+(?:patient|pt)\b"#)
    static let weightRx = Rx(#"\b(?:weighs|weight|weighing|weight is|weight of)?\s*(about|around|approximately|approx|maybe|roughly|like|estimated|probably)?\s*(\d{2,3})\s*(kg|kilos|kilograms|kilo|pounds|lbs|lb)\b"#)
    static let allergyRx = Rx(#"\b(?:allergic to|allergies to|allergy to|allergies are|allergies include|allergic|allergies)\s+([a-z]+(?:\s+(?:and\s+)?[a-z]+){0,3}?)(?=\s+[|;]|\s+(?:she|he|they|takes|and no|no)\b|\s*$)"#)
    static let nkdaRx = Rx(#"\b(nkda|nka|no known drug allergies|no known allergies|no allergies)\b"#)
    static let historyRx = Rx(#"\b(?:history of|hx of|pmh of|past medical history of|past history of|pmh)\s+([a-z0-9]+(?:\s+(?:and\s+)?[a-z0-9]+){0,4}?)(?=\s+[|;]|\s+(?:she|he|they|takes|allergic|no)\b|\s*$)"#)

    func patientInfo(_ tt: TokText) -> [Finding] {
        var out: [Finding] = []
        func add(_ f: [String: String], _ key: String, _ tr: ClosedRange<Int>, _ conf: Double, flags: [String] = []) {
            out.append(Finding(type: .status, fields: f, receipts: [key: tt.receipt(tr)], tMs: tt.seg.timeOf(token: tr.lowerBound),
                               rawSpan: tt.seg.rawSpan, quote: tt.seg.quote(tr.lowerBound, tr.upperBound), confidence: conf, flags: flags,
                               extractor: RulesExtractor.version))
        }
        for m in RulesExtractor.ageRx.all(tt.text) {
            guard let tr = tt.tokens(m.range), let age = Int(tt.sub(m.range(at: 1))), (1...120).contains(age) else { continue }
            var f = ["kind": "patient", "age": String(age)]
            if m.range(at: 2).location != NSNotFound { f["sex"] = sexWord(tt.sub(m.range(at: 2))) }
            out.append(Finding(type: .status, fields: f, receipts: Dictionary(uniqueKeysWithValues: f.keys.filter { $0 != "kind" }.map { ($0, tt.receipt(tr)) }),
                               tMs: tt.seg.timeOf(token: tr.lowerBound), rawSpan: tt.seg.rawSpan, quote: tt.seg.quote(tr.lowerBound, tr.upperBound),
                               confidence: 0.9, flags: [], extractor: RulesExtractor.version))
        }
        for m in RulesExtractor.ageShortRx.all(tt.text) {
            guard let tr = tt.tokens(m.range), let age = Int(tt.sub(m.range(at: 1))), (1...120).contains(age) else { continue }
            let f = ["kind": "patient", "age": String(age), "sex": tt.sub(m.range(at: 2)).hasSuffix("m") ? "male" : "female"]
            out.append(Finding(type: .status, fields: f, receipts: ["age": tt.receipt(tr), "sex": tt.receipt(tr)], tMs: tt.seg.timeOf(token: tr.lowerBound),
                               rawSpan: tt.seg.rawSpan, quote: tt.seg.quote(tr.lowerBound, tr.upperBound), confidence: 0.85, flags: [], extractor: RulesExtractor.version))
        }
        for m in RulesExtractor.ageMonthsRx.all(tt.text) {
            guard let tr = tt.tokens(m.range), let n = Int(tt.sub(m.range(at: 1))), (1...36).contains(n) else { continue }
            add(["kind": "patient", "age": String(n), "age_units": "months"], "age", tr, 0.85)
        }
        for m in RulesExtractor.sexRx.all(tt.text) {
            guard let tr = tt.tokens(m.range) else { continue }
            add(["kind": "patient", "sex": tt.sub(m.range(at: 1)).lowercased()], "sex", tr, 0.85)
        }
        for m in RulesExtractor.weightRx.all(tt.text) {
            guard let tr = tt.tokens(m.range), let w = Double(tt.sub(m.range(at: 2))) else { continue }
            let u = tt.sub(m.range(at: 3)).lowercased()
            let kg = u.hasPrefix("k") ? w : (w * 0.4536).rounded()
            guard (2...350).contains(kg) else { continue }
            var f = ["kind": "patient", "weight_kg": String(Int(kg))]
            if !u.hasPrefix("k") { f["weight_as_heard"] = "\(Int(w)) lb" }
            if m.range(at: 1).location != NSNotFound { f["weight_estimated"] = "true" }
            add(f, "weight_kg", tr, 0.85)
        }
        for m in RulesExtractor.nkdaRx.all(tt.text) {
            guard let tr = tt.tokens(m.range) else { continue }
            add(["kind": "allergy", "allergy": "NKDA"], "allergy", tr, 0.9)
        }
        for m in RulesExtractor.allergyRx.all(tt.text) {
            guard let tr = tt.tokens(m.range) else { continue }
            let what = tt.sub(m.range(at: 1))
            if dict.aliasIndex[what] != nil { continue } // drug allergy handled by medication pass
            if ["to", "no", "none"].contains(what) { continue }
            add(["kind": "allergy", "allergy": what], "allergy", tr, 0.75, flags: ["confirm"])
        }
        for m in RulesExtractor.historyRx.all(tt.text) {
            guard let tr = tt.tokens(m.range) else { continue }
            guard let vr = tt.tokens(m.range(at: 1)) else { continue }
            add(["kind": "history", "history": tt.seg.quote(vr.lowerBound, vr.upperBound).trimmingCharacters(in: CharacterSet(charactersIn: " ,.;"))], "history", tr, 0.75)
        }
        return out
    }

    func sexWord(_ s: String) -> String {
        ["male", "man", "boy", "gentleman"].contains(s.lowercased()) ? "male" : "female"
    }

    // MARK: dispatch vs found

    static let W = #"[^\s|;]+"#
    static let phrase = #"("# + W + #"(?:\s+"# + W + #"){0,4}?)"#
    static let stop = #"(?=\s+[|;]|\s+(?:but|and|turned|turns|it|which|so|now|when|then|patient|pt|she|he|they|with|for)\b|\s*$)"#
    static let dispatchRx = Rx(#"\b(?:dispatched for|dispatched to|dispatched as|called for|call came in as|came in as|came in for|dispatch said|dispatch says|toned out for|sent for|we got called for|got called for|call was for)\s+(?:an?\s+|the\s+)?"# + phrase + stop)
    static let foundRx = Rx(#"\b(?:turned out to be|turns out to be|turns out it's|turned out it was|it's actually|it is actually|is actually|was actually|actually an?|found to be|looks more like|more like an?)\s+(?:an?\s+|the\s+)?"# + phrase + stop)
    static let ccRx = Rx(#"\b(?:complaining of|complains of|c/o|chief complaint is|chief complaint of|chief complaint|cc is|presenting with|presents with)\s+"# + phrase + stop)

    /// Radio dispatch: "Medic 14, respond priority one to 42 Elm for a 62 year old male, chest pain"
    static let radioRx = Rx(#"\b(?:respond|responding|dispatch|priority (?:one|two|three|1|2|3)|toned out|be advised)\b"#)
    static let dispatchComplaints: [String] = ["chest pain", "difficulty breathing", "trouble breathing", "shortness of breath", "fall", "fallen",
        "unresponsive", "unconscious", "seizure", "seizures", "mvc", "mva", "motor vehicle", "syncope", "fainted", "passed out", "abdominal pain",
        "back pain", "bleeding", "hemorrhage", "allergic reaction", "diabetic", "sick person", "lift assist", "assault", "burn", "burns",
        "headache", "altered mental status", "ams", "weakness", "dizziness", "nausea", "vomiting", "fever", "pregnancy", "labor",
        "psychiatric", "behavioral", "cardiac", "breathing problem", "breathing problems", "injury", "injured", "pain"]

    func dispatch(_ tt: TokText) -> [Finding] {
        var out: [Finding] = []
        for (rx, field, conf) in [(RulesExtractor.dispatchRx, "dispatch_reason", 0.85), (RulesExtractor.foundRx, "found", 0.75), (RulesExtractor.ccRx, "chief_complaint", 0.8)] {
            for m in rx.all(tt.text) {
                guard let tr = tt.tokens(m.range), let vr = tt.tokens(m.range(at: 1)) else { continue }
                let val = tt.seg.quote(vr.lowerBound, vr.upperBound).trimmingCharacters(in: CharacterSet(charactersIn: " ,.;"))
                if Diagnosis.contains(val) { continue }   // never turn a spoken diagnosis into a field
                out.append(Finding(type: .dispatch, fields: [field: val], receipts: [field: tt.receipt(tr)], tMs: tt.seg.timeOf(token: tr.lowerBound),
                                   rawSpan: tt.seg.rawSpan, quote: tt.seg.quote(tr.lowerBound, tr.upperBound), confidence: conf, flags: [],
                                   extractor: RulesExtractor.version))
            }
        }
        // radio-style dispatch with no "dispatched for": take the complaint words from the same segment
        if !out.contains(where: { $0.fields["dispatch_reason"] != nil }), RulesExtractor.radioRx.all(tt.text).first != nil {
            let toks = tt.seg.tokens
            var best: ClosedRange<Int>? = nil
            for c in RulesExtractor.dispatchComplaints.sorted(by: { $0.count > $1.count }) {
                let words = c.split(separator: " ").map(String.init)
                for i in 0..<max(0, toks.count - words.count + 1) where toks[i..<(i + words.count)].map(\.text) == words {
                    if best == nil || i < best!.lowerBound { best = i...(i + words.count - 1) }
                }
            }
            if let r = best {
                out.append(Finding(type: .dispatch, fields: ["dispatch_reason": tt.seg.quote(r.lowerBound, r.upperBound).trimmingCharacters(in: CharacterSet(charactersIn: " ,.;"))],
                                   receipts: ["dispatch_reason": tt.receipt(r)], tMs: tt.seg.timeOf(token: r.lowerBound), rawSpan: tt.seg.rawSpan,
                                   quote: tt.seg.quote(0, toks.count - 1), confidence: 0.7, flags: [], extractor: RulesExtractor.version))
            }
        }
        return out
    }

    // MARK: transport

    static let destRx = Rx(#"\b(?:transporting to|transport to|transporting him to|transporting her to|headed to|heading to|en route to|going to|taking (?:him|her|them|the patient|pt) to|we're going to|we are going to|transporting)\s+(?:the\s+)?"# + phrase + #"(?=\s+[|;]|\s+(?:eta|with|priority|code|lights|and|now|in|for)\b|\s*$)"#)
    static let modeRx = Rx(#"\b(lights and sirens|code 3|code three|emergent|non emergent|non-emergent|code 2|code two|no lights)\b"#)
    static let alertRx = Rx(#"\b(stemi alert|stroke alert|trauma alert|sepsis alert|cath lab|trauma team|code stroke|code stemi|activate|activated|pre-?alert|notify|notified)\b"#)
    static let etaRx = Rx(#"\beta\s+(?:is\s+|of\s+|about\s+|in\s+)*(\d{1,3})\s*(?:minutes|minute|mins|min)\b"#)
    static let onSceneRx = Rx(#"\b(?:on scene|on-scene|arriving on scene|arrived on scene|we're on location|on location)\b"#)
    static let departRx = Rx(#"\b(?:we're transporting|we are transporting|transporting|leaving (?:the )?scene|leaving now|en route to (?:the )?(?:hospital|ed|er)|heading in|departing)\b"#)
    static let handoffRx = Rx(#"\b(?:transfer of care|handing off|handed off|giving report|report given|gave report|patient handed over)\b"#)
    static let inServiceRx = Rx(#"\b(?:back in service|back available|clear(?:ing)? (?:the )?(?:scene|hospital)|we're clear)\b"#)
    static let weAreHereRx = Rx(#"(?:^|\|\s+|;\s+)(?:okay\s+;?\s*)?(?:we're here|we are here|here we are|we made it)\b"#)
    /// Sentence-initial "At the trauma center." (needs a facility word, checked by looksLikePlace + facilityOnly)
    static let atPlaceRx = Rx(#"(?:^|\|\s+)at\s+(?:the\s+)?((?:[^\s|;]+\s+){0,3}(?:hospital|ed|er|center|general|memorial|regional|medical|emergency|bay|mercy|children's))\b"#)
    static let atPlaceNowRx = Rx(#"(?:^|\|\s+|;\s+)\s*(?:we're\s+|we are\s+)?at\s+(?:the\s+)?"# + phrase + #"\s+now\b"#)
    static let arrivedRx = Rx(#"\b(?:we're at|we are at|arrived at|arriving at|arrive at|arrive that|arrived that|pulling into|pulling in to|we're here at|here at)\s+(?:the\s+)?"# + phrase + #"(?=\s+[|;]|\s+(?:now|and|with)\b|\s*$)"#)
    /// A destination must look like a place: a facility word, or a capitalized name (not a number, not a verb phrase).
    static let facilityWords: Set<String> = ["hospital", "ed", "er", "emergency", "medical", "center", "general", "memorial", "mercy", "regional",
        "university", "children's", "childrens", "st", "saint", "health", "clinic", "trauma", "ambulance", "bay", "mass", "mgh", "bmc", "brigham",
        "beth", "israel", "deaconess", "tufts", "county", "community", "valley", "baptist", "methodist", "presbyterian", "kaiser", "va"]
    func looksLikePlace(_ raw: String) -> Bool {
        let words = raw.split(separator: " ").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " ,.;")) }
        guard let first = words.first, !first.isEmpty, Double(first) == nil else { return false }
        if words.contains(where: { RulesExtractor.facilityWords.contains($0.lowercased()) }) { return true }
        return words.allSatisfy { $0.first?.isUppercase ?? false }
    }

    func transport(_ tt: TokText) -> [Finding] {
        var fields: [String: String] = [:]
        var rec: [String: FieldReceipt] = [:]
        var trs: [ClosedRange<Int>] = []
        func grab(_ rx: Rx, _ field: String, group: Int = 1, clean: Bool = false, accept: (String) -> Bool = { _ in true }, _ map: (String) -> String = { $0 }) {
            for m in rx.all(tt.text) where fields[field] == nil {
                guard let tr = tt.tokens(m.range) else { continue }
                let r = m.range(at: group)
                guard r.location != NSNotFound, let vr = tt.tokens(r) else { continue }
                let v = (clean ? tt.sub(r) : tt.seg.quote(vr.lowerBound, vr.upperBound)).trimmingCharacters(in: CharacterSet(charactersIn: " ,.;"))
                guard accept(v) else { continue }
                fields[field] = map(v)
                rec[field] = tt.receipt(tr); trs.append(tr)
            }
        }
        grab(RulesExtractor.destRx, "destination", accept: looksLikePlace)
        grab(RulesExtractor.modeRx, "mode") { $0.lowercased() }
        // the alert's type is often a diagnosis ("STEMI alert"): record only that a pre-alert was given
        grab(RulesExtractor.alertRx, "alert") { _ in "hospital pre-alert given (as said)" }
        grab(RulesExtractor.etaRx, "eta_min", clean: true)
        var out: [Finding] = []
        if !fields.isEmpty {
            let lo = trs.map(\.lowerBound).min()!, hi = trs.map(\.upperBound).max()!
            out.append(Finding(type: .transport, fields: fields, receipts: rec, tMs: tt.seg.timeOf(token: lo), rawSpan: tt.seg.rawSpan,
                               quote: tt.seg.quote(lo, hi), confidence: 0.8, flags: [], extractor: RulesExtractor.version))
        }
        func timeEvent(_ kind: String, _ etime: String, _ rx: Rx, conf: Double, flags: [String] = []) {
            for m in rx.all(tt.text) {
                guard let tr = tt.tokens(m.range) else { continue }
                out.append(Finding(type: .transport, fields: ["kind": kind, "etime": etime], receipts: ["kind": tt.receipt(tr)],
                                   tMs: tt.seg.startMs,   // a time stamp is when the utterance began
                                   rawSpan: tt.seg.rawSpan, quote: tt.seg.quote(tr.lowerBound, tr.upperBound),
                                   confidence: conf, flags: flags, extractor: RulesExtractor.version))
                return
            }
        }
        timeEvent("on_scene", "eTimes.06", RulesExtractor.onSceneRx, conf: 0.8)
        timeEvent("departed", "eTimes.09", RulesExtractor.departRx, conf: 0.75)
        timeEvent("handoff_heard", "eTimes.12", RulesExtractor.handoffRx, conf: 0.7, flags: ["confirm"])
        timeEvent("back_in_service", "eTimes.13", RulesExtractor.inServiceRx, conf: 0.75)
        for m in RulesExtractor.weAreHereRx.all(tt.text) {
            guard let tr = tt.tokens(m.range) else { continue }
            out.append(Finding(type: .transport, fields: ["kind": "arrived_heard", "etime": "eTimes.11"], receipts: ["kind": tt.receipt(tr)],
                               tMs: tt.seg.startMs, rawSpan: tt.seg.rawSpan, quote: tt.seg.quote(tr.lowerBound, tr.upperBound),
                               confidence: 0.55, flags: ["confirm"], extractor: RulesExtractor.version))
            break
        }
        for m in RulesExtractor.arrivedRx.all(tt.text) + RulesExtractor.atPlaceNowRx.all(tt.text) + RulesExtractor.atPlaceRx.all(tt.text) {
            guard let tr = tt.tokens(m.range), m.range(at: 1).location != NSNotFound, m.range(at: 1).length > 0,
                  let vr = tt.tokens(m.range(at: 1)) else { continue }
            let dest = tt.seg.quote(vr.lowerBound, vr.upperBound).trimmingCharacters(in: CharacterSet(charactersIn: " ,.;"))
            guard looksLikePlace(dest) else { continue }   // "sats, we're at 92" is not an arrival
            if out.contains(where: { $0.fields["kind"] == "arrived_heard" }) { continue }
            out.append(Finding(type: .transport, fields: ["kind": "arrived_heard", "destination": dest, "etime": "eTimes.11"], receipts: ["kind": tt.receipt(tr)],
                               tMs: tt.seg.startMs, rawSpan: tt.seg.rawSpan, quote: tt.seg.quote(tr.lowerBound, tr.upperBound),
                               confidence: 0.6, flags: ["confirm"], extractor: RulesExtractor.version))
        }
        return out
    }
}
