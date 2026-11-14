import Foundation

/// Replaces names, dates of birth, addresses and phone numbers with tokens
/// ([NAME_1], [DOB_1], [ADDR_1], [PHONE_1]). The vault (token -> original)
/// stays in memory on the device and is never exported by default.
public final class PIIScrubber {
    public private(set) var vault: [String: String] = [:]
    private var reverse: [String: String] = [:]
    private var counters: [String: Int] = [:]

    public init() {}

    static let nameCue = Rx(#"\b(?:my name is|name is|name's|this is mr\.?|this is mrs\.?|this is ms\.?|patient is|patient's name is|pt is|her name is|his name is|goes by)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)"#)
    static let honorific = Rx(#"\b(?:Mr|Mrs|Ms|Miss|Mister|Dr)\.?\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)"#)
    static let dob = Rx(#"\b(?:date of birth|d\.?o\.?b\.?|born on|birthday is|birth date)\s*(?:is\s+)?((?:january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)\.?\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{2,4}|\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{1,2}\s+\d{1,2}\s+\d{2,4})"#)
    static let addr = Rx(#"\b(\d{1,5}\s+(?:[A-Z][a-z]+\s+){1,3}(?:Street|St|Avenue|Ave|Road|Rd|Lane|Ln|Drive|Boulevard|Blvd|Court|Ct|Way|Place|Pl|Terrace|Circle|Parkway|Highway|Hwy)\b)"#)
    static let phone = Rx(#"\b(\(?\d{3}\)?[\s.-]\d{3}[\s.-]\d{4})\b"#)

    /// Learn PII from a raw segment (case-sensitive patterns need raw text).
    public func learn(_ text: String) {
        let ns = text as NSString
        // name cues are matched case-insensitively for the cue but need a capitalized name
        for (rx, kind) in [(PIIScrubber.nameCue, "NAME"), (PIIScrubber.honorific, "NAME"), (PIIScrubber.dob, "DOB"),
                           (PIIScrubber.addr, "ADDR"), (PIIScrubber.phone, "PHONE")] {
            for m in rx.all(text) {
                let v = ns.substring(with: m.range(at: 1))
                if kind == "NAME" {
                    // the capture must really be capitalized words (cue matching is case-insensitive)
                    guard v.split(separator: " ").allSatisfy({ $0.first?.isUppercase ?? false }) else { continue }
                    if PIIScrubber.notNames.contains(v.lowercased()) { continue }
                }
                if kind == "ADDR" {
                    guard v.split(separator: " ").dropFirst().allSatisfy({ $0.first?.isUppercase ?? false }) else { continue }
                }
                add(kind, v)
            }
        }
    }

    static let notNames: Set<String> = ["the", "she", "he", "unresponsive", "alert", "stable", "a", "in", "on", "not", "male", "female"]

    private func add(_ kind: String, _ value: String) {
        if reverse[value] != nil { return }
        counters[kind, default: 0] += 1
        let tok = "[\(kind)_\(counters[kind]!)]"
        vault[tok] = value; reverse[value] = tok
        if kind == "NAME" {
            // also scrub each part of a full name on its own
            for part in value.split(separator: " ") where part.count > 2 && reverse[String(part)] == nil {
                reverse[String(part)] = tok
            }
        }
    }

    public func scrub(_ s: String) -> String {
        var out = s
        for (v, tok) in reverse.sorted(by: { $0.key.count > $1.key.count }) {
            out = out.replacingOccurrences(of: v, with: tok)
        }
        return out
    }

    public func scrub(_ e: EarshotEvent) -> EarshotEvent {
        var e = e
        e.quote = e.quote.map(scrub)
        e.fields = e.fields.mapValues(scrub)
        if var r = e.receipts {
            for k in r.keys { r[k]!.quote = scrub(r[k]!.quote) }
            e.receipts = r
        }
        return e
    }

    public func wipe() { vault.removeAll(); reverse.removeAll(); counters.removeAll() }
}
