import Foundation

/// A line from the live recogniser (Apple's on-device speech, in the app). Display only: it never
/// becomes part of the record. Its one other use is the cross-check below.
public struct LiveLine: Codable, Equatable, Sendable {
    public var id: String
    public var startMs: Int64       // call time
    public var endMs: Int64
    public var text: String
    public init(id: String, startMs: Int64, endMs: Int64, text: String) {
        self.id = id; self.startMs = startMs; self.endMs = endMs; self.text = text
    }
}

/// What the second recogniser said about one event.
public struct CrossCheckNote: Codable, Equatable, Sendable {
    /// agree: the live recogniser heard the same values. disagree: it heard different values, or
    /// had words at that moment but not these values. no_live_text: it had nothing to compare.
    public var result: String
    /// The live recogniser's words around the event (shown next to "please confirm").
    public var liveText: String?
    /// The values that did not match, e.g. ["dose: 4 vs 40"].
    public var mismatches: [String]?
    public init(result: String, liveText: String? = nil, mismatches: [String]? = nil) {
        self.result = result; self.liveText = liveText; self.mismatches = mismatches
    }
}

/// Two-recogniser cross-check. Whisper's transcript is the record; Apple's live transcript is a
/// second opinion. Where the two disagree on a drug, dose or vital sign, the event is marked
/// "please confirm". Both transcripts go through the same cleanup and rules, so "one twenty over
/// eighty" and "120/80" compare equal.
public struct CrossCheck {
    public static let checkedTypes: Set<EventType> = [.vitals, .medication]
    /// Vital-sign fields compared as numbers.
    static let vitalKeys = ["bp_systolic", "bp_diastolic", "heart_rate", "spo2", "resp_rate", "gcs", "glucose", "etco2", "temperature"]

    let dict: EMSDictionary
    let cleaner: Cleanup
    let rules: RulesExtractor
    public var windowMs: Int64

    public init(dict: EMSDictionary, windowMs: Int64 = 4000) {
        self.dict = dict; cleaner = Cleanup(dict: dict); rules = RulesExtractor(dict: dict); self.windowMs = windowMs
    }

    /// Returns `events` with `crossCheck` set on every checked event, and "confirm" added where the
    /// recognisers disagree. Events typed by the medic are left alone.
    public func apply(_ events: [EarshotEvent], live: [LiveLine]) -> [EarshotEvent] {
        guard !live.isEmpty else { return events }
        var cache: [String: (text: String, findings: [Finding])] = [:]
        return events.map { e0 in
            var e = e0
            guard Self.checkedTypes.contains(e.type), e.enteredBy == nil, e.source == .heard || e.source == .tapHeard else { return e }
            let lines = live.filter { $0.endMs >= e.tMs - windowMs && $0.startMs <= e.tMs + windowMs }.sorted { $0.startMs < $1.startMs }
            let liveText = lines.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !liveText.isEmpty else {
                e.crossCheck = CrossCheckNote(result: "no_live_text")
                return e
            }
            let key = lines.map(\.id).joined(separator: "|") + "#" + liveText
            let heard = cache[key] ?? analyse(liveText, startMs: lines.first!.startMs, endMs: lines.last!.endMs)
            cache[key] = heard
            let mismatches = compare(e, liveFindings: heard.findings, liveClean: heard.text)
            if mismatches.isEmpty {
                e.crossCheck = CrossCheckNote(result: "agree", liveText: liveText)
            } else {
                e.crossCheck = CrossCheckNote(result: "disagree", liveText: liveText, mismatches: mismatches)
                if !e.needsConfirm { e.flags = (e.flags ?? []) + ["confirm"] }
            }
            return e
        }
    }

    private func analyse(_ text: String, startMs: Int64, endMs: Int64) -> (text: String, findings: [Finding]) {
        let c = cleaner.clean(RawSegment(id: "live", startMs: startMs, endMs: endMs, text: text)).0
        return (" " + c.text.lowercased() + " ", rules.extract(c))
    }

    /// Mismatch descriptions; empty means the live recogniser supports every checked value.
    func compare(_ e: EarshotEvent, liveFindings: [Finding], liveClean: String) -> [String] {
        let same = liveFindings.filter { $0.type == e.type }
        var out: [String] = []
        switch e.type {
        case .vitals:
            for k in Self.vitalKeys {
                guard let v = e.fields[k] else { continue }
                let theirs = same.compactMap { $0.fields[k] }
                if theirs.contains(where: { Self.numEq($0, v) }) { continue }
                if Self.hasToken(liveClean, v) { continue }
                out.append(theirs.first.map { "\(k): \(v) vs \($0)" } ?? "\(k): \(v) not heard live")
            }
        case .medication:
            let drug = e.fields["drug"]?.lowercased()
            let dose = e.fields["dose"]
            let liveDrugs = Set(same.compactMap { $0.fields["drug"]?.lowercased() })
            if let d = drug, !liveDrugs.contains(d), !Self.hasToken(liveClean, d) {
                out.append(liveDrugs.first.map { "drug: \(d) vs \($0)" } ?? "drug: \(d) not heard live")
            }
            if let v = dose {
                let theirs = same.filter { drug == nil || $0.fields["drug"]?.lowercased() == drug }.compactMap { $0.fields["dose"] }
                if !theirs.contains(where: { Self.numEq($0, v) }) && !Self.hasToken(liveClean, v) {
                    out.append(theirs.first.map { "dose: \(v) vs \($0)" } ?? "dose: \(v) not heard live")
                }
            }
        default:
            break
        }
        return out
    }

    static func numEq(_ a: String, _ b: String) -> Bool {
        if let x = Double(a), let y = Double(b) { return abs(x - y) < 0.001 }
        return a.lowercased() == b.lowercased()
    }

    /// Whole-token match in cleaned, lower-cased, space-padded text.
    static func hasToken(_ padded: String, _ value: String) -> Bool {
        let v = value.lowercased()
        let toks = padded.lowercased().split { !($0.isLetter || $0.isNumber || $0 == ".") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        return toks.contains(v)
    }
}
