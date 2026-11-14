import Foundation

/// Marks a drug, dose or vital sign "please confirm" when Whisper was unsure of the value itself.
/// Whisper gives each token a probability. Only the tokens that carry the value count: the digits
/// of a number, the letters of a drug name or unit. Label words ("heart rate", "gave") do not:
/// Whisper is often unsure of those while the number is clear, and flagging them only adds noise
/// (19 of 19 flags were on correct values when labels counted). Nothing is changed or removed.
public enum ConfidenceFlags {
    public static let checkedFields: Set<String> = Set(CrossCheck.vitalKeys + ["drug", "dose", "unit"])

    public static func apply(_ findings: [Finding], seg: CleanSegment, minConfidence: Double) -> [Finding] {
        guard minConfidence > 0, let wt = seg.wordTimes, let conf = seg.wordConf, wt.count == conf.count, !wt.isEmpty else { return findings }
        return findings.map { f0 in
            guard f0.type == .medication || f0.type == .vitals else { return f0 }
            var f = f0
            var low: [String] = []
            for (key, r) in f.receipts where checkedFields.contains(key) {
                guard let range = r.rawRange, range.count == 2 else { continue }
                let numeric = key != "drug" && key != "unit"
                let valueText = numeric ? (f.fields[key] ?? "") : (r.quote)
                guard let p = lowest(conf, wt, text: seg.rawText, from: range[0], to: range[1], numeric: numeric, value: valueText),
                      p < minConfidence else { continue }
                low.append(key)
            }
            guard !low.isEmpty else { return f }
            if !f.flags.contains("confirm") { f.flags.append("confirm") }
            f.flags.append("low_confidence")
            return f
        }
    }

    /// Lowest probability among the tokens inside [a, b) of the raw text that carry the value:
    /// tokens with a digit for numbers; for a drug or unit, tokens whose letters are part of the
    /// value's words (so "gave" and "of" in the receipt are ignored). Nil when none qualify.
    static func lowest(_ conf: [Double], _ wt: [[Int64]], text: String, from a: Int, to b: Int, numeric: Bool, value: String) -> Double? {
        let chars = Array(text)
        let words = Set(value.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 })
        var ps: [Double] = []
        for i in wt.indices {
            let s = Int(wt[i][0]), e = i + 1 < wt.count ? Int(wt[i + 1][0]) : chars.count
            // token overlaps the receipt
            guard e > a, s < b, s >= 0, s < chars.count else { continue }
            let tok = String(chars[s..<min(max(s, e), chars.count)]).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let letters = tok.filter(\.isLetter)
            let carries = numeric ? tok.contains(where: \.isNumber)
                                  : (!letters.isEmpty && words.contains { $0.contains(letters) || letters.contains($0) })
            if carries { ps.append(conf[i]) }
        }
        return ps.min()
    }
}
