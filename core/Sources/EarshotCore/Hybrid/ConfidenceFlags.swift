import Foundation

/// Marks a drug, dose or vital sign "please confirm" when Whisper was unsure of the words it came
/// from. Whisper gives each token a probability; a value whose words include a token below
/// `minConfidence` is flagged (flags "confirm" and "low_confidence"). Nothing is changed or
/// removed: the value stays as heard, the medic checks it.
public enum ConfidenceFlags {
    public static let checkedFields: Set<String> = Set(CrossCheck.vitalKeys + ["drug", "dose", "unit"])

    public static func apply(_ findings: [Finding], seg: CleanSegment, minConfidence: Double) -> [Finding] {
        guard minConfidence > 0, let wt = seg.wordTimes, let conf = seg.wordConf, wt.count == conf.count, !wt.isEmpty else { return findings }
        return findings.map { f0 in
            guard f0.type == .medication || f0.type == .vitals else { return f0 }
            var f = f0
            var low: [String] = []
            for (key, r) in f.receipts where checkedFields.contains(key) {
                guard let range = r.rawRange, range.count == 2,
                      let p = lowest(conf, wt, from: range[0], to: range[1]), p < minConfidence else { continue }
                low.append(key)
            }
            guard !low.isEmpty else { return f }
            if !f.flags.contains("confirm") { f.flags.append("confirm") }
            f.flags.append("low_confidence")
            return f
        }
    }

    /// Lowest token probability over the characters [a, b) of the raw text. The token that starts
    /// at or before `a` covers the first word, so it is included.
    static func lowest(_ conf: [Double], _ wt: [[Int64]], from a: Int, to b: Int) -> Double? {
        var idx: [Int] = []
        if let first = wt.lastIndex(where: { $0[0] <= Int64(a) }) { idx.append(first) }
        for (i, w) in wt.enumerated() where w[0] > Int64(a) && w[0] < Int64(b) { idx.append(i) }
        return idx.map { conf[$0] }.min()
    }
}
