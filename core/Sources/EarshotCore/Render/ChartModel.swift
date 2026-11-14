import Foundation

/// A value with the event(s) it came from. Renderers print `[e12]` receipts.
public struct Sourced: Equatable, Sendable {
    public var text: String
    public var events: [String]
    public var time: String?
    public var flags: [String]
    public init(_ text: String, _ events: [String], time: String? = nil, flags: [String] = []) {
        self.text = text; self.events = events; self.time = time; self.flags = flags
    }
}

/// Everything the renderers need, derived from events only.
/// Missing values are nil and render as "not heard".
public struct ChartModel: Sendable {
    public static let notHeard = "not heard"

    public var callId: String
    public var clock: CallClock
    public var age: Sourced?
    public var sex: Sourced?
    public var weight: Sourced?
    public var dispatch: Sourced?
    public var found: Sourced?
    public var chiefComplaint: Sourced?
    public var symptoms: [Sourced] = []
    public var denied: [Sourced] = []
    public var history: [Sourced] = []
    public var allergies: [Sourced] = []
    public var homeMeds: [Sourced] = []
    public var ptaMeds: [Sourced] = []
    public var vitals: [EarshotEvent] = []
    public var meds: [EarshotEvent] = []
    public var medsNotGiven: [Sourced] = []
    public var notDone: [Sourced] = []
    public var procedures: [EarshotEvent] = []
    public var conditions: [Sourced] = []
    public var mental: Sourced?
    public var pupils: Sourced?
    public var ecg: [Sourced] = []
    public var transport: [EarshotEvent] = []
    public var arrival: EarshotEvent?
    public var onScene: EarshotEvent?        // eTimes.06, heard
    public var departed: EarshotEvent?       // eTimes.09, heard
    public var backInService: EarshotEvent?  // eTimes.13, heard
    public var findings: [Sourced] = []
    public var handoff: EarshotEvent?
    public var consent: EarshotEvent?
    public var unlabeledTaps: [EarshotEvent] = []
    public var confirmItems: [EarshotEvent] = []
    public var gaps: [EarshotEvent] = []

    public var wallTimeMs: Int64? {
        guard let a = arrival, let h = handoff, h.tMs >= a.tMs else { return nil }
        return h.tMs - a.tMs
    }
    public var dispatchChanged: Bool {
        guard let d = dispatch?.text.lowercased() else { return false }
        let f = (found ?? chiefComplaint)?.text.lowercased()
        return f != nil && f != d
    }

    public init(events: [EarshotEvent], callId: String, clock: CallClock) {
        self.callId = callId; self.clock = clock
        for e in events {
            let t = clock.clock(e.tMs)
            let fl = e.flags ?? []
            func s(_ text: String) -> Sourced { Sourced(text, [e.id], time: t, flags: fl) }
            if e.needsConfirm { confirmItems.append(e) }
            switch e.type {
            case .vitals:
                vitals.append(e)
                if let m = e.fields["mental_status"], mental == nil { mental = s(m) }
                if let p = e.fields["pupils"], pupils == nil { pupils = s(p) }
                if let r = e.fields["ecg"] { ecg.append(s(r)) }
            case .medication: meds.append(e)
            case .procedure: procedures.append(e)
            case .transport:
                switch e.fields["kind"] {
                case "on_scene": if onScene == nil { onScene = e }
                case "departed": if departed == nil { departed = e }
                case "back_in_service": if backInService == nil { backInService = e }
                default: transport.append(e)
                }
            case .arrival: if arrival == nil || e.source == .tablet { arrival = e }
            case .handoff: if handoff == nil || e.source == .tablet { handoff = e }
            case .consent: if consent == nil { consent = e }
            case .audioGap: gaps.append(e)
            case .tap: if e.isUnlabeledTap { unlabeledTaps.append(e) }
            case .dispatch:
                if let v = e.fields["dispatch_reason"], dispatch == nil { dispatch = s(v) }
                if let v = e.fields["found"], found == nil { found = s(v) }
                if let v = e.fields["chief_complaint"], chiefComplaint == nil { chiefComplaint = s(v) }
            case .status:
                let neg = e.fields["negated"] == "true"
                switch e.fields["kind"] ?? "" {
                case "patient":
                    if let a = e.fields["age"], age == nil { age = s(a + (e.fields["age_units"] == "months" ? " months" : "")) }
                    if let x = e.fields["sex"], sex == nil { sex = s(x) }
                    if let w = e.fields["weight_kg"], weight == nil {
                        weight = s("\(w) kg" + (e.fields["weight_estimated"] == "true" ? " (estimated)" : ""))
                    }
                case "symptom":
                    let v = e.fields["symptom"] ?? ""
                    if neg { if !denied.contains(where: { $0.text == v }) { denied.append(s(v)) } }
                    else if !symptoms.contains(where: { $0.text == v }) { symptoms.append(s(v)) }
                case "history": if !neg { history.append(s(e.fields["history"] ?? "")) }
                case "allergy": allergies.append(s(e.fields["allergy"] ?? ""))
                case "home_med": homeMeds.append(s(e.fields["drug"] ?? ""))
                case "prior_to_arrival_med":
                    ptaMeds.append(s([e.fields["drug"], e.fields["dose"], e.fields["unit"]].compactMap { $0 }.joined(separator: " ")))
                case "med_not_given": medsNotGiven.append(s(e.fields["drug"] ?? ""))
                case "not_done": notDone.append(s(e.fields["procedure"] ?? ""))
                case "finding": findings.append(s((neg ? "no " : "") + (e.fields["term"] ?? "")))
                case "condition": conditions.append(s((neg ? "not " : "") + (e.fields["condition"] ?? "")))
                default: break
                }
            }
        }
    }

    // MARK: formatting helpers shared by renderers

    public static func receipt(_ ids: [String]) -> String { ids.isEmpty ? "" : " [" + ids.joined(separator: ", ") + "]" }
    public static func show(_ s: Sourced?) -> String {
        guard let s = s else { return notHeard }
        return s.text + receipt(s.events) + (s.flags.contains("confirm") ? " (confirm)" : "")
    }
    public static func list(_ xs: [Sourced]) -> String {
        xs.isEmpty ? notHeard : xs.map { $0.text + receipt($0.events) + ($0.flags.contains("confirm") ? " (confirm)" : "") }.joined(separator: "; ")
    }

    public static func medLine(_ e: EarshotEvent, clock: CallClock) -> String {
        let f = e.fields
        var dose = ChartModel.notHeard
        if let d = f["dose"] {
            if let u = f["unit"] { dose = d + " " + u }
            else { dose = d + " (unit not heard" + (f["unit_suggested"].map { "; protocol dose is in \($0)" } ?? "") + ")" }
        }
        let route = f["route"] ?? "route not heard"
        var s = "\(clock.clock(e.tMs)) \(f["drug"] ?? "?") \(dose) \(route)"
        if let h = f["drug_as_heard"] { s += " (heard as \"\(h)\")" }
        s += " — \(srcLabel(e))" + receipt([e.id])
        if e.needsConfirm { s += " (confirm)" }
        return s
    }

    public static let vitalOrder: [(String, String)] = [("bp", "BP"), ("heart_rate", "HR"), ("resp_rate", "RR"), ("spo2", "SpO2"),
                                                         ("etco2", "EtCO2"), ("glucose", "BGL"), ("gcs", "GCS"), ("temp", "Temp"),
                                                         ("pain", "Pain")]
    public static func vitalsLine(_ e: EarshotEvent) -> String {
        var parts: [String] = []
        let f = e.fields
        for (k, label) in vitalOrder {
            if k == "bp" {
                if let s = f["bp_systolic"] { parts.append("BP \(s)/\(f["bp_diastolic"] ?? (f["bp_method"] == "palpation" ? "palp" : "diastolic not heard"))") }
            } else if let v = f[k] {
                parts.append("\(label) \(v)\(k == "spo2" ? "%" : k == "pain" ? "/10" : "")")
            }
        }
        if let o = f["o2_on"] { parts.append("on \(o)") }
        if let m = f["mental_status"] { parts.append(m) }
        if let p = f["pupils"] { parts.append(p) }
        if let r = f["ecg"] { parts.append("ECG: \(r)") }
        return parts.joined(separator: ", ")
    }

    public static func srcLabel(_ e: EarshotEvent) -> String {
        switch e.source {
        case .tapHeard: return "tap + heard"
        case .tap: return "tap"
        case .heard: return "heard"
        case .tablet: return e.enteredBy.map { "entered by \($0)" } ?? "tablet"
        }
    }

    /// First and last value of a vital, for trend lines ("HR 118 → 96").
    public func trend(_ key: String) -> (String, String, [String])? {
        let xs = vitals.filter { $0.fields[key] != nil }
        guard let a = xs.first, let b = xs.last, xs.count >= 2 else { return nil }
        return (a.fields[key]!, b.fields[key]!, [a.id, b.id])
    }

    public static func duration(_ ms: Int64) -> String {
        let s = ms / 1000
        return String(format: "%d min %02d s", s / 60, s % 60)
    }
}
