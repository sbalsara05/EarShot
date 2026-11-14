import Foundation

/// A tap placed on the call timeline (call-relative ms).
public struct PlacedTap: Equatable, Sendable {
    public var tMs: Int64
    public var source: String
    public var gesture: String
    public var clipMs: Int64
    public init(tMs: Int64, source: String, gesture: String, clipMs: Int64) {
        self.tMs = tMs; self.source = source; self.gesture = gesture; self.clipMs = clipMs
    }
}

public struct MergeConfig: Codable, Equatable, Sendable {
    public var windowMs: Int64 = 3000        // ± window for labeling a tap
    public var extendedMs: Int64 = 10000     // forward extension when nothing in ± window
    public init() {}
}

/// Turns findings + taps + gaps into the final, ordered event list.
/// Rules (docs/ARCHITECTURE.md#taps):
///  * a tap's time is the event time, even if speech about it comes later;
///  * a tap is labeled by the nearest labelable finding whose speech segment
///    overlaps ±3 s, else (tap, tap+10 s]; one finding labels at most one tap;
///  * two taps are never merged with each other; unlabeled taps stay;
///  * findings that no tap claims become `heard` events.
public struct TapMerger {
    public var cfg: MergeConfig
    public var callId: String
    public var clock: CallClock
    public var models: ModelInfo
    public init(cfg: MergeConfig = MergeConfig(), callId: String, clock: CallClock, models: ModelInfo) {
        self.cfg = cfg; self.callId = callId; self.clock = clock; self.models = models
    }

    static let labelable: Set<EventType> = [.vitals, .medication, .procedure, .status]
    /// Every status kind is rendered somewhere, so any of them may label a tap.
    static let labelableStatusKinds: Set<String> = ["condition", "symptom", "drug_mention", "med_not_given", "not_done", "prior_to_arrival_med",
                                                    "patient", "allergy", "history", "home_med"]
    static let typePriority: [EventType: Int] = [.medication: 0, .procedure: 1, .vitals: 2, .status: 3]

    static let labelableTimeKinds: Set<String> = ["on_scene", "departed", "arrived_heard", "handoff_heard", "back_in_service"]
    func isLabelable(_ f: Finding) -> Bool {
        if f.type == .transport { return TapMerger.labelableTimeKinds.contains(f.fields["kind"] ?? "") }
        guard TapMerger.labelable.contains(f.type) else { return false }
        if f.type == .status { return TapMerger.labelableStatusKinds.contains(f.fields["kind"] ?? "") }
        return true
    }

    public func merge(findings: [Finding], segments: [String: (Int64, Int64)], taps: [PlacedTap], gaps: [(Int64, Int64, Int)],
                      extra: [EarshotEvent] = []) -> [EarshotEvent] {
        var out: [EarshotEvent] = []
        var claimed = Set<Int>()
        let sortedTaps = taps.sorted { ($0.tMs, $0.source) < ($1.tMs, $1.source) }
        var arrivalFromTablet = extra.contains { $0.type == .arrival }
        // 1. non-mark gestures
        var marks: [PlacedTap] = []
        for tap in sortedTaps {
            switch tap.gesture {
            case "yes", "no":
                out.append(make(.consent, tap.tMs, ["consent": tap.gesture == "yes" ? "yes" : "no (refused, nothing recorded)"],
                                .tap, nil, nil, 1.0, tap: tap))
            case "arrival":
                out.append(make(.arrival, tap.tMs, ["method": "tap", "nemsis": "eTimes.11"], .tablet, nil, nil, 1.0, tap: tap))
                arrivalFromTablet = true
            case "handoff":
                out.append(make(.handoff, tap.tMs, ["method": "nurse accept", "nemsis": "eTimes.12"], .tablet, nil, nil, 1.0, tap: tap))
            case "start", "stop":
                break
            default:
                marks.append(tap)
            }
        }
        // 2. label marks: distance is from the tap to the finding's own word time.
        //    In-window (±3 s) pairs beat forward-extended (+10 s) pairs; pairs are
        //    assigned globally, closest first, one finding per tap and vice versa.
        struct Pair { var tap: Int; var finding: Int; var score: Int64; var pri: Int }
        var pairs: [Pair] = []
        for (ti, tap) in marks.enumerated() {
            for (fi, f) in findings.enumerated() where isLabelable(f) {
                let d = abs(f.tMs - tap.tMs)
                if d <= cfg.windowMs { pairs.append(Pair(tap: ti, finding: fi, score: d, pri: TapMerger.typePriority[f.type] ?? 9)) }
                else if f.tMs > tap.tMs && f.tMs - tap.tMs <= cfg.extendedMs {
                    pairs.append(Pair(tap: ti, finding: fi, score: cfg.windowMs + d, pri: TapMerger.typePriority[f.type] ?? 9))
                }
            }
        }
        pairs.sort { ($0.score, $0.pri, $0.tap, $0.finding) < ($1.score, $1.pri, $1.tap, $1.finding) }
        var tapLabel: [Int: Int] = [:]
        for p in pairs where tapLabel[p.tap] == nil && !claimed.contains(p.finding) {
            tapLabel[p.tap] = p.finding; claimed.insert(p.finding)
        }
        for (ti, tap) in marks.enumerated() {
            if let fi = tapLabel[ti] {
                let f = findings[fi]
                // a tap on a heard time becomes that time (arrival / transfer of care) at the tap moment
                var type = f.type
                var fields = f.fields
                if f.type == .transport && f.fields["kind"] == "arrived_heard" && !arrivalFromTablet {
                    type = .arrival; fields = ["method": "tap + heard", "nemsis": "eTimes.11"]; if let d = f.fields["destination"] { fields["destination"] = d }
                    arrivalFromTablet = true
                } else if f.type == .transport && f.fields["kind"] == "handoff_heard" && !taps.contains(where: { $0.gesture == "handoff" }) {
                    type = .handoff; fields = ["method": "tap + heard", "nemsis": "eTimes.12"]
                }
                var e = make(type, tap.tMs, fields, .tapHeard, f.quote, f.rawSpan, f.confidence, tap: tap, receipts: f.receipts,
                             flags: f.flags.filter { $0 != "confirm" || type == f.type }, extractor: f.extractor)
                e.fields["heard_at"] = clock.clock(f.tMs)
                out.append(e)
            } else {
                out.append(make(.tap, tap.tMs, ["label": "no label"], .tap, nil, nil, 1.0, tap: tap, flags: ["unlabeled"]))
            }
        }
        var arrivalHeardUsed = arrivalFromTablet || out.contains { $0.type == .arrival }
        let extraHasHandoff = taps.contains { $0.gesture == "handoff" } || extra.contains { $0.type == .handoff }
        var handoffHeardUsed = false
        var lastProc: [String: Int64] = [:]
        for (i, f) in findings.enumerated() where f.type == .procedure {
            let name = (f.fields["procedure"] ?? "") + "|" + (f.fields["site"] ?? "")
            if claimed.contains(i) { lastProc[name] = f.tMs; continue }
            if let t = lastProc[name], f.tMs - t < 120_000, f.fields["procedure"] != "IV access" || f.fields["site"] == nil {
                claimed.insert(i)   // same procedure said again ("get a 12 lead" ... "12 lead shows"): one event
                continue
            }
            lastProc[name] = f.tMs
        }
        for (i, f) in findings.enumerated() where !claimed.contains(i) {
            if f.type == .transport && f.fields["kind"] == "handoff_heard" {
                if !handoffHeardUsed && !extraHasHandoff && !out.contains(where: { $0.type == .handoff }) {
                    handoffHeardUsed = true
                    out.append(make(.handoff, f.tMs, ["method": "heard", "nemsis": "eTimes.12"], .heard, f.quote, f.rawSpan, f.confidence,
                                    receipts: f.receipts, flags: ["confirm"], extractor: f.extractor))
                }
                continue
            }
            if f.type == .transport && f.fields["kind"] == "arrived_heard" && !arrivalHeardUsed {
                arrivalHeardUsed = true
                var flds = ["method": "heard", "nemsis": "eTimes.11"]
                if let d = f.fields["destination"] { flds["destination"] = d }
                out.append(make(.arrival, f.tMs, flds, .heard, f.quote, f.rawSpan, f.confidence, receipts: f.receipts, flags: ["confirm"], extractor: f.extractor))
                continue
            }
            out.append(make(f.type, f.tMs, f.fields, .heard, f.quote, f.rawSpan, f.confidence, receipts: f.receipts, flags: f.flags, extractor: f.extractor))
        }
        for g in gaps {
            out.append(make(.audioGap, g.0, ["duration_ms": String(g.1 - g.0), "missing_frames": String(g.2)], .tablet, nil, nil, 1.0))
        }
        out.append(contentsOf: extra)
        // deterministic order + ids
        let order: [EventType: Int] = Dictionary(uniqueKeysWithValues: EventType.allCases.enumerated().map { ($1, $0) })
        out.sort { a, b in
            if a.tMs != b.tMs { return a.tMs < b.tMs }
            if a.type != b.type { return order[a.type]! < order[b.type]! }
            let ka: String = TapMerger.sortKey(a), kb: String = TapMerger.sortKey(b)
            return ka < kb
        }
        for k in out.indices { out[k].id = "e\(k + 1)" }
        return out
    }

    static func sortKey(_ e: EarshotEvent) -> String {
        let f: String = e.fields.keys.sorted().map { k in k + "=" + (e.fields[k] ?? "") }.joined(separator: "|")
        return (e.rawSpan ?? "") + "\u{1}" + (e.quote ?? "") + "\u{1}" + f
    }

    func make(_ type: EventType, _ t: Int64, _ fields: [String: String], _ source: EventSource, _ quote: String?, _ span: String?,
              _ conf: Double, tap: PlacedTap? = nil, receipts: [String: FieldReceipt]? = nil, flags: [String] = [],
              extractor: String? = nil) -> EarshotEvent {
        EarshotEvent(id: "", callId: callId, time: clock.iso(t), tMs: t, type: type, fields: fields, source: source, quote: quote,
                     rawSpan: span, confidence: conf,
                     models: ModelInfo(asr: span == nil ? "none" : models.asr, extract: extractor ?? (span == nil ? "none" : models.extract)),
                     receipts: (receipts?.isEmpty ?? true) ? nil : receipts, flags: flags.isEmpty ? nil : flags,
                     tapSource: tap?.source, tapClipMs: tap?.clipMs)
    }
}
