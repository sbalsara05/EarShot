import Foundation

/// Cleanup: normalizes spelling, numbers and abbreviations using the EMS
/// dictionary. Never adds content: every output token maps to raw text, and
/// every change is recorded as a `Correction` that links to the raw span.
public final class Cleanup {
    let dict: EMSDictionary
    private var nextId = 1
    public init(dict: EMSDictionary) { self.dict = dict }

    static let ones: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    /// Unambiguous route phrases (single short words like "in", "push" are
    /// left for extraction, which looks at context).
    static let routePhrases: [String: String] = [
        "by mouth": "po", "orally": "po", "under the tongue": "sl", "sublingual": "sl", "sub lingual": "sl",
        "sublingually": "sl", "intravenous": "iv", "intravenously": "iv", "intramuscular": "im", "intramuscularly": "im",
        "intraosseous": "io", "intranasal": "in", "intranasally": "in", "subcutaneous": "sq", "sub q": "sq", "subq": "sq",
        "nebulized": "neb", "i v": "iv", "i o": "io", "i m": "im", "p o": "po", "s l": "sl",
    ]
    /// Letter-by-letter or spoken forms of common abbreviations.
    static let spelled: [String: String] = [
        "s p o 2": "spo2", "s p o two": "spo2", "spo two": "spo2", "sp o2": "spo2", "s p o2": "spo2", "spo 2": "spo2",
        "e t c o 2": "etco2", "etco two": "etco2", "et co2": "etco2", "e t co2": "etco2", "etco 2": "etco2", "end tidal co2": "etco2",
        "o two": "o2", "o 2": "o2", "g c s": "gcs", "b g l": "bgl", "c b g": "cbg", "e k g": "ekg", "e c g": "ecg",
        "t x a": "txa", "c p r": "cpr", "a e d": "aed", "b v m": "bvm", "n r b": "nrb", "c pap": "cpap", "see pap": "cpap",
        "n k d a": "nkda", "p m h": "pmh", "c h f": "chf", "c o p d": "copd", "a fib": "afib", "v fib": "vfib", "v tach": "vtach",
        "r o s c": "rosc", "rosk": "rosc", "s v t": "svt", "s t e m i": "stemi", "stemmy": "stemi", "l k w": "lkw",
        "perl": "perrl", "p e r r l": "perrl", "pearl": "perrl", "pearla": "perrla", "a and o": "a&o", "a & o": "a&o",
        "a&o": "a&o", "ao": "a&o", "twelve lead": "12 lead", "i gel": "igel",
        "d ten": "d10", "d 10": "d10", "d fifty": "d50", "d 50": "d50", "d five": "d5", "d25": "d25", "d 25": "d25",
        "e t a": "eta", "e d": "ed", "e r": "er", "s t elevation": "st elevation", "s t depression": "st depression",
        "left a c": "left ac", "right a c": "right ac", "a c": "ac", "a fib with r v r": "afib with rvr", "r v r": "rvr",
        "i v push": "ivp", "e t": "et", "b p": "bp", "h r": "hr", "r r": "rr", "o d t": "odt", "l r": "lr", "n s": "ns",
    ]
    static let orientTimes: Set<String> = ["times", "x", "by", "×"]

    public func clean(_ seg: RawSegment) -> (CleanSegment, [Correction]) {
        let toks = Text.tokenize(seg.text)
        var out: [CleanToken] = []
        var corr: [Correction] = []
        var i = 0
        func emit(_ text: String, _ a: Int, _ b: Int, rule: String?) {
            let rs = toks[a].range.lowerBound, re = toks[b - 1].range.upperBound
            let lastRaw = toks[b - 1].raw
            var punct: String? = nil
            if let l = lastRaw.last, ".,?!;:".contains(l), !(l == "." && lastRaw.dropLast().last?.isNumber == true && false) { punct = String(l) }
            let origNorm = toks[a..<b].map(\.norm).joined(separator: " ")
            if let rule = rule, origNorm != text {
                let chars = Array(seg.text)
                corr.append(Correction(id: "c\(nextId)", rawSpan: seg.id, rawRange: [rs, re],
                                       original: String(chars[rs..<re]), replacement: text, rule: rule))
                nextId += 1
                out.append(CleanToken(text: text, rawStart: rs, rawEnd: re, rule: rule, punct: punct))
            } else {
                out.append(CleanToken(text: text, rawStart: rs, rawEnd: re, rule: nil, punct: punct))
            }
        }
        while i < toks.count {
            // 0. Whisper non-speech tags inside a segment ("[beep]", "(siren)") are dropped
            if let r = Cleanup.nonSpeechSpan(toks, i) {
                let rs = toks[i].range.lowerBound, re = toks[r - 1].range.upperBound
                let chars = Array(seg.text)
                corr.append(Correction(id: "c\(nextId)", rawSpan: seg.id, rawRange: [rs, re], original: String(chars[rs..<re]),
                                       replacement: "", rule: "asr:non_speech_tag"))
                nextId += 1; i = r; continue
            }
            // 1. spelled abbreviations / letter runs (longest first, up to 5 tokens)
            var matched = false
            for n in stride(from: min(5, toks.count - i), through: 1, by: -1) {
                let phrase = toks[i..<(i + n)].map(\.norm).joined(separator: " ")
                if let rep = Cleanup.spelled[phrase] {
                    // "a and o times four" -> a&ox4
                    if rep == "a&o", i + n + 1 < toks.count, Cleanup.orientTimes.contains(toks[i + n].norm),
                       let v = Cleanup.ones[toks[i + n + 1].norm] ?? Int(toks[i + n + 1].norm), (1...4).contains(v) {
                        emit("a&ox\(v)", i, i + n + 2, rule: "abbrev:orientation"); i += n + 2
                    } else if rep == "a&o", i + n < toks.count, let m = toks[i + n].norm.range(of: #"^x([1-4])$"#, options: .regularExpression) {
                        emit("a&o" + toks[i + n].norm[m], i, i + n + 1, rule: "abbrev:orientation"); i += n + 1
                    } else if n == 1 && rep == "a&o" {
                        emit(toks[i].norm, i, i + 1, rule: nil); i += 1  // bare "ao" too ambiguous alone
                    } else {
                        emit(rep, i, i + n, rule: "abbrev:spelled"); i += n
                    }
                    matched = true; break
                }
                if let rep = Cleanup.routePhrases[phrase], n >= 1, !(n == 1 && phrase.count <= 2) {
                    emit(rep, i, i + n, rule: "route:normalize"); i += n; matched = true; break
                }
            }
            if matched { continue }
            // 2. drug ASR variants (multi-token first)
            for n in stride(from: min(dict.maxAliasTokens, toks.count - i), through: 1, by: -1) {
                let phrase = toks[i..<(i + n)].map(\.norm).joined(separator: " ")
                if dict.aliasIndex[phrase] == nil, let di = dict.variantIndex[phrase],
                   RulesExtractor.hasDoseOrRoute(toks.map(\.norm), i, dict) {   // "this sucks, give me 2 seconds" stays as said
                    emit(dict.drug(di).generic, i, i + n, rule: "formulary:asr_variant"); i += n; matched = true; break
                }
            }
            if matched { continue }
            // 3. numbers spoken as words
            if let (val, used) = parseNumber(toks, i) {
                emit(val, i, i + used, rule: "number:words"); i += used; continue
            }
            // 4. digits with attached % or unit ("98%", "324mg", "0.4mg")
            let t = toks[i].norm
            if let m = t.range(of: #"^(\d+(?:\.\d+)?)(%|mg|mcg|ml|g|kg|cc|l|lpm|meq|units)$"#, options: .regularExpression), m.lowerBound == t.startIndex {
                let num = t.prefix { $0.isNumber || $0 == "." }
                let unit = String(t.dropFirst(num.count))
                let canon = unit == "%" ? "%" : (dict.unitIndex[unit] ?? unit)
                emit(String(num), i, i + 1, rule: nil)
                // the unit shares the raw token range; record as a normalization
                let rs = toks[i].range.lowerBound, re = toks[i].range.upperBound
                let p = out[out.count - 1].punct; out[out.count - 1].punct = nil
                out.append(CleanToken(text: canon, rawStart: rs, rawEnd: re, rule: "unit:split", punct: p))
                i += 1; continue
            }
            // 4b. glued vital name + number from ASR ("respS32", "sats94", "hr110") -> name, number
            if t.range(of: #"^(resps|resp|rr|sats|sat|spo2|hr|pulse|gcs|bgl|etco2)(\d{1,3})$"#, options: .regularExpression) != nil {
                let head = ["etco2", "spo2", "resps", "resp", "pulse", "sats", "sat", "gcs", "bgl", "rr", "hr"].first { t.hasPrefix($0) }!
                let num = String(t.dropFirst(head.count))
                let rs = toks[i].range.lowerBound, re = toks[i].range.upperBound
                let chars = Array(seg.text)
                corr.append(Correction(id: "c\(nextId)", rawSpan: seg.id, rawRange: [rs, re], original: String(chars[rs..<re]),
                                       replacement: head + " " + num, rule: "asr:split_glued"))
                nextId += 1
                out.append(CleanToken(text: head, rawStart: rs, rawEnd: re, rule: "asr:split_glued"))
                out.append(CleanToken(text: num, rawStart: rs, rawEnd: re, rule: "asr:split_glued", punct: toks[i].raw.last.map { ".,?!;:".contains($0) ? String($0) : nil } ?? nil))
                i += 1; continue
            }
            // 5. "120 over 80" -> 120/80
            if isNum(t), i + 2 < toks.count, toks[i + 1].norm == "over" || toks[i + 1].norm == "/", isNum(toks[i + 2].norm) {
                emit("\(t)/\(toks[i + 2].norm)", i, i + 3, rule: "number:over"); i += 3; continue
            }
            // 6. units after a number
            if let prev = out.last, isNum(prev.text) {
                var hit = false
                for n in stride(from: min(5, toks.count - i), through: 1, by: -1) {
                    let phrase = toks[i..<(i + n)].map(\.norm).joined(separator: " ")
                    if let u = dict.unitIndex[phrase] {
                        emit(u, i, i + n, rule: u == phrase ? nil : "unit:normalize"); i += n; hit = true; break
                    }
                }
                if hit { continue }
                if t == "percent" { emit("%", i, i + 1, rule: "unit:normalize"); i += 1; continue }
            }
            // 7. fuzzy drug spelling (long single words only)
            if t.count >= 6, dict.aliasIndex[t] == nil, dict.termIndex[t] == nil, RulesExtractor.hasDoseOrRoute(toks.map(\.norm), i, dict), let g = fuzzyDrug(t) {
                emit(g, i, i + 1, rule: "formulary:fuzzy"); i += 1; continue
            }
            emit(t, i, i + 1, rule: nil)
            i += 1
        }
        // post-pass: "<num> over <num>" built from number words -> "a/b"
        var k = 0
        while k + 2 < out.count {
            if isNum(out[k].text), out[k].punct == nil, out[k + 1].text == "over", out[k + 1].punct == nil, isNum(out[k + 2].text) {
                let merged = CleanToken(text: out[k].text + "/" + out[k + 2].text, rawStart: out[k].rawStart, rawEnd: out[k + 2].rawEnd,
                                        rule: "number:over", punct: out[k + 2].punct)
                let chars = Array(seg.text)
                corr.append(Correction(id: "c\(nextId)", rawSpan: seg.id, rawRange: [merged.rawStart, merged.rawEnd],
                                       original: String(chars[merged.rawStart..<merged.rawEnd]), replacement: merged.text, rule: "number:over"))
                nextId += 1
                out.replaceSubrange(k...(k + 2), with: [merged])
            }
            k += 1
        }
        return (CleanSegment(rawSpan: seg.id, startMs: seg.startMs, endMs: seg.endMs, rawText: seg.text, tokens: out, wordTimes: seg.wordTimes), corr)
    }

    /// If tokens starting at i form a bracketed tag ([...] or (...)), return the index after it.
    static func nonSpeechSpan(_ t: [Text.Token], _ i: Int) -> Int? {
        if !t[i].raw.contains(where: { $0.isLetter || $0.isNumber }) { return i + 1 }   // "♪♪♪", "🎵"
        guard let open = t[i].raw.first, open == "[" || open == "(" else { return nil }
        let close: Character = open == "[" ? "]" : ")"
        for j in i..<min(t.count, i + 5) {
            let r = t[j].raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
            if r.last == close { return j + 1 }
        }
        return nil
    }

    func isNum(_ s: String) -> Bool { !s.isEmpty && Double(s) != nil }

    func fuzzyDrug(_ t: String) -> String? {
        var best: (Double, String, String)? = nil
        for (alias, di) in dict.aliasIndex where !alias.contains(" ") && alias.count >= 5 && abs(alias.count - t.count) <= 2 {
            let s = Text.similarity(t, alias)
            guard s >= 0.84 else { continue }
            if best == nil || s > best!.0 || (s == best!.0 && alias < best!.2) { best = (s, dict.drug(di).generic, alias) }
        }
        return best?.1
    }

    /// Parses spoken numbers: "one twenty" (120), "three twenty four" (324),
    /// "one hundred and five", "ninety eight", "zero point four", "point
    /// five", "two and a half". Returns (digits, tokensConsumed).
    func parseNumber(_ t: [Text.Token], _ i: Int) -> (String, Int)? {
        func w(_ k: Int) -> String? { k < t.count ? t[k].norm : nil }
        func small(_ k: Int) -> (Int, Int)? { // 0-99 from words at k
            guard let a = w(k) else { return nil }
            if let v = Cleanup.teens[a] { return (v, 1) }
            if let v = Cleanup.tens[a] {
                if let b = w(k + 1), let u = Cleanup.ones[b], u > 0, b != "oh" { return (v + u, 2) }
                return (v, 1)
            }
            if let v = Cleanup.ones[a], a != "oh" { return (v, 1) }
            return nil
        }
        guard let first = w(i) else { return nil }
        var value: Double
        var used: Int
        if first == "point", let d = w(i + 1).flatMap({ Cleanup.ones[$0] }) {
            var s = "0.\(d)"; var k = i + 2
            while let x = w(k).flatMap({ Cleanup.ones[$0] }) { s += "\(x)"; k += 1 }
            return (s, k - i)
        }
        if first == "a", w(i + 1) == "hundred" { value = 100; used = 2 }
        else if first == "a" || first == "an", let nx = w(i + 1), ["liter", "leader", "gram", "milligram", "unit", "amp", "half"].contains(nx) {
            return (nx == "half" ? "0.5" : "1", nx == "half" ? 2 : 1)   // "a liter of saline" -> "1 liter"; "a half" -> 0.5
        }
        else if let (v, n) = small(i) {
            value = Double(v); used = n
            if w(i + used) == "hundred" {
                value *= 100; used += 1
                if w(i + used) == "and", let (r, m) = small(i + used + 1) { value += Double(r); used += m + 1 }
                else if let (r, m) = small(i + used) { value += Double(r); used += m }
            } else if w(i + used) == "thousand" {
                value *= 1000; used += 1
                if let (r, m) = small(i + used) { value += Double(r); used += m }
            } else if v >= 1 && v <= 9 && n == 1 {
                // colloquial hundreds: "one twenty", "one oh five", "three twenty four"
                if let nx = w(i + 1), Cleanup.tens[nx] != nil || Cleanup.teens[nx] != nil, let (r, m) = small(i + 1) {
                    value = Double(v * 100 + r); used += m
                } else if w(i + 1) == "oh", let u = w(i + 2).flatMap({ Cleanup.ones[$0] }) {
                    value = Double(v * 100 + u); used += 2
                }
            }
        } else { return nil }
        // decimals / halves
        if w(i + used) == "point", let d = w(i + used + 1).flatMap({ Cleanup.ones[$0] }) {
            var s = String(Int(value)) + ".\(d)"; var k = i + used + 2
            while let x = w(k).flatMap({ Cleanup.ones[$0] }) { s += "\(x)"; k += 1 }
            return (s, k - i)
        }
        if w(i + used) == "and", w(i + used + 1) == "a", w(i + used + 2) == "half" {
            return (String(Int(value)) + ".5", used + 3)
        }
        // lone "one" without numeric context stays a word ("no one", "that one")
        if used == 1 && first == "one" {
            let nx = w(i + 1) ?? ""
            if dict.unitIndex[nx] == nil && !["milligram", "gram", "liter", "amp", "dose", "mg", "mcg", "of"].contains(nx) { return nil }
        }
        let s = value == value.rounded() ? String(Int(value)) : String(value)
        return (s, used)
    }
}
