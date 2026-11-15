import Foundation

/// Writes a call's report as a NEMSIS 3.5.1 EMSDataSet, the XML that ambulance services send to their state.
///
/// The file passes the national schema (the XSD); the test runs `xmllint` on it. It is not yet checked against
/// the national business rules (Schematron) or any state's own.
///
/// An answer goes in when NEMSIS takes it as it is (a number, a time, a name) or when it is one of the choices
/// this app offers, which map straight to NEMSIS codes. A field with no answer is written the NEMSIS way,
/// as "not recorded". The layout of the required sections follows Shourya Yadav's `Render/NEMSIS.swift`.
/// ponytail: NEMSIS wants codes where the report holds words: impression and symptom (ICD-10), procedure
/// (SNOMED), allergies and home medicines (RxNorm), city (GNIS), location type (ICD-10 Y92). Only drugs have a
/// table here, and a short one. The rest are written as not recorded and their words stay in the narrative.
public enum NemsisXML {
    /// The values that are the same on every call for one crew and truck.
    public struct Agency {
        public var number = "", stateID = "", state = ""            // eResponse.01 and dAgency.02, dAgency.01, dAgency.04
        public var unit = "", callSign = ""                         // eResponse.13, eResponse.14
        public var capability = "", serviceType = "", responseMode = ""   // eResponse.07, .05, .23, each a NEMSIS code
        public init() {}
    }

    /// - times: the full date and time behind each time answer, by element. An answer with none here is placed
    ///   on the day the call started.
    public static func write(_ report: [String: String], id: UUID, start: Date, end: Date, times: [String: Date] = [:], agency: Agency, version: String) -> String {
        func said(_ element: String) -> String? {
            guard let value = report[element]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        func none(_ element: String) -> String { "<\(element) xsi:nil=\"true\" NV=\"7701003\"/>" }
        func put(_ element: String, _ value: String?) -> String { value.map { "<\(element)>\(escape($0))</\(element)>" } ?? none(element) }
        func coded(_ element: String, _ key: String, _ codes: [String: String]) -> String { put(element, said(key).flatMap { codes[$0] }) }
        func number(_ element: String, _ key: String) -> String { put(element, said(key).flatMap { Double($0) == nil ? nil : $0 }) }
        func time(_ element: String, _ key: String) -> String { put(element, (times[key] ?? said(key).flatMap { moment($0, on: start) }).map(stamp)) }
        func sets(_ section: String) -> Int { Nemsis.sections.first { $0.id == section }.map { Nemsis.sets(of: $0, in: report) } ?? 1 }

        // A few elements may not be empty in NEMSIS. Where the crew has set none, a stand-in is written and
        // named in a comment at the top of the file, so nobody takes it for something that was recorded.
        var standIns: [String] = []
        func must(_ element: String, _ value: String?, else standIn: String, _ what: String) -> String {
            if value == nil { standIns.append("\(element) \(what)") }
            return put(element, value ?? standIn)
        }
        // Why the crew was sent, from the complaint's own words; "unknown problem" when they say nothing NEMSIS lists.
        let complaint = Words.of((said("eSituation.04") ?? "") + " " + (said("eSituation.09") ?? ""))
        let reason = dispatch.first { $0.0.contains { complaint.contains($0) } }?.1

        var x: [String] = []
        x.append("<EMSDataSet xmlns=\"http://www.nemsis.org\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:schemaLocation=\"http://www.nemsis.org https://nemsis.org/media/nemsis_v3/release-3.5.1/XSDs/NEMSIS_XSDs/EMSDataSet_v3.xsd\">")
        x.append("<Header>")
        x.append("<DemographicGroup>" + must("dAgency.01", text(agency.stateID), else: "UNSET", "agency's state ID: not set in Settings")
                 + must("dAgency.02", text(agency.number), else: "UNSET", "agency number: not set in Settings") + must("dAgency.04", state(agency.state), else: "00", "agency state: not set in Settings") + "</DemographicGroup>")
        x.append("<PatientCareReport UUID=\"\(id.uuidString.lowercased())\">")

        x.append("<eRecord>" + put("eRecord.01", "PCR-" + id.uuidString.prefix(8).lowercased())
                 + "<eRecord.SoftwareApplicationGroup>" + put("eRecord.02", "Earshot") + put("eRecord.03", "Earshot") + put("eRecord.04", version) + "</eRecord.SoftwareApplicationGroup></eRecord>")

        x.append("<eResponse><eResponse.AgencyGroup>" + put("eResponse.01", text(agency.number) ?? "UNSET") + "</eResponse.AgencyGroup>"
                 + none("eResponse.03") + none("eResponse.04")
                 + "<eResponse.ServiceGroup>" + must("eResponse.05", text(agency.serviceType), else: "2205001", "type of service: not set in Settings, written as an emergency response") + "</eResponse.ServiceGroup>"
                 + must("eResponse.07", text(agency.capability), else: "2207017", "unit capability: not set in Settings, written as ground transport, BLS")
                 + ["08", "09", "10", "11", "12"].map { none("eResponse.\($0)") }.joined()
                 + must("eResponse.13", text(agency.unit), else: "UNSET", "unit number: not set in Settings") + must("eResponse.14", text(agency.callSign), else: "UNSET", "call sign: not set in Settings")
                 + must("eResponse.23", text(agency.responseMode), else: "2223001", "response mode: not set in Settings, written as emergent") + none("eResponse.24") + "</eResponse>")

        x.append("<eDispatch>" + must("eDispatch.01", reason, else: "2301079", "dispatch reason: not known, written as unknown problem") + none("eDispatch.02") + "</eDispatch>")

        x.append("<eTimes>" + none("eTimes.01") + must("eTimes.03", (times["eTimes.03"] ?? said("eTimes.03").flatMap { moment($0, on: start) }).map(stamp), else: stamp(start), "unit notified: not given, the time the recording started stands in")
                 + time("eTimes.05", "eTimes.05") + time("eTimes.06", "eTimes.06") + time("eTimes.07", "eTimes.07") + time("eTimes.09", "eTimes.09")
                 + time("eTimes.11", "eTimes.11") + none("eTimes.12") + must("eTimes.13", nil, else: stamp(end), "unit back in service: not recorded, the time the recording ended stands in") + "</eTimes>")

        var patient = "<ePatient>"
        if said("ePatient.02") != nil || said("ePatient.03") != nil {
            patient += "<ePatient.PatientNameGroup>" + put("ePatient.02", said("ePatient.02")) + put("ePatient.03", said("ePatient.03")) + "</ePatient.PatientNameGroup>"
        }
        patient += none("ePatient.07") + none("ePatient.08") + none("ePatient.09") + none("ePatient.14")
        patient += "<ePatient.AgeGroup>" + number("ePatient.15", "ePatient.15") + coded("ePatient.16", "ePatient.16", ["Days": "2516001", "Hours": "2516003", "Minutes": "2516005", "Months": "2516007", "Years": "2516009"]) + "</ePatient.AgeGroup>"
        patient += coded("ePatient.25", "ePatient.25", ["Female": "9919001", "Male": "9919003"]) + "</ePatient>"
        x.append(patient)

        x.append("<ePayment>" + none("ePayment.01") + none("ePayment.50") + "</ePayment>")

        x.append("<eScene>" + none("eScene.01") + coded("eScene.06", "eScene.06", ["Multiple": "2707001", "None": "2707003", "Single": "2707005"]) + none("eScene.07") + none("eScene.08") + none("eScene.09")
                 + (said("eScene.15").map { "<eScene.15>\(escape($0))</eScene.15>" } ?? "")
                 + put("eScene.18", said("eScene.18").flatMap(state)) + put("eScene.19", said("eScene.19").flatMap { $0.range(of: #"^\d{5}(-\d{4})?$"#, options: .regularExpression) == nil ? nil : $0 })
                 + none("eScene.21") + "</eScene>")

        var situation = "<eSituation>" + none("eSituation.01") + none("eSituation.02")
        if let complaint = said("eSituation.04") {
            situation += "<eSituation.PatientComplaintGroup>" + put("eSituation.04", complaint)
            if let lasted = said("eSituation.05"), Int(lasted) != nil, let unit = said("eSituation.06").flatMap({ ["Seconds": "2806001", "Minutes": "2806003", "Hours": "2806005", "Days": "2806007", "Weeks": "2806009", "Months": "2806011", "Years": "2806013"][$0] }) {
                situation += put("eSituation.05", lasted) + put("eSituation.06", unit)
            }
            situation += "</eSituation.PatientComplaintGroup>"
        }
        situation += coded("eSituation.07", "eSituation.07", ["Abdomen": "2807001", "Back": "2807003", "Chest": "2807005", "Extremity-Lower": "2807007", "Extremity-Upper": "2807009",
                                                             "General/Global": "2807011", "Genitalia": "2807013", "Head": "2807015", "Neck": "2807017"])
        situation += ["08", "09", "10", "11", "12", "13", "18", "20"].map { none("eSituation.\($0)") }.joined() + "</eSituation>"
        x.append(situation)

        x.append("<eInjury>" + ["01", "03", "04"].map { none("eInjury.\($0)") }.joined() + "</eInjury>")
        x.append("<eArrest>" + ["01", "02", "03", "04", "07", "09", "11", "12", "14", "16", "17", "18", "20", "21", "22"].map { none("eArrest.\($0)") }.joined() + "</eArrest>")
        x.append("<eHistory>" + none("eHistory.01") + none("eHistory.17") + "</eHistory>")
        if let narrative = said("eNarrative.01") { x.append("<eNarrative>" + put("eNarrative.01", narrative) + "</eNarrative>") }

        var vitals = "<eVitals>"
        for set in 1...sets("eVitals") {
            func at(_ id: String) -> String { Nemsis.element(id, set: set) }
            vitals += "<eVitals.VitalGroup>" + time("eVitals.01", at("eVitals.01")) + put("eVitals.02", "9923001")
            vitals += "<eVitals.CardiacRhythmGroup>" + none("eVitals.03") + none("eVitals.04") + none("eVitals.05") + "</eVitals.CardiacRhythmGroup>"
            vitals += "<eVitals.BloodPressureGroup>" + number("eVitals.06", at("eVitals.06")) + (said(at("eVitals.06")) != nil && said(at("eVitals.07")) != nil ? number("eVitals.07", at("eVitals.07")) : "") + "</eVitals.BloodPressureGroup>"
            vitals += "<eVitals.HeartRateGroup>" + number("eVitals.10", at("eVitals.10")) + "</eVitals.HeartRateGroup>"
            vitals += number("eVitals.12", at("eVitals.12")) + number("eVitals.14", at("eVitals.14")) + none("eVitals.16") + number("eVitals.18", at("eVitals.18"))
            vitals += "<eVitals.GlasgowScoreGroup>" + ["19", "20", "21", "22"].map { none("eVitals.\($0)") }.joined() + (said(at("eVitals.23")).map { "<eVitals.23>\($0)</eVitals.23>" } ?? "") + "</eVitals.GlasgowScoreGroup>"
            vitals += none("eVitals.26") + "<eVitals.PainScaleGroup>" + number("eVitals.27", at("eVitals.27")) + "</eVitals.PainScaleGroup>"
            vitals += "<eVitals.StrokeScaleGroup>" + none("eVitals.29") + none("eVitals.30") + "</eVitals.StrokeScaleGroup>" + none("eVitals.31") + "</eVitals.VitalGroup>"
        }
        x.append(vitals + "</eVitals>")

        x.append("<eProtocols><eProtocols.ProtocolGroup>" + none("eProtocols.01") + "</eProtocols.ProtocolGroup></eProtocols>")

        var medications = "<eMedications>"
        for set in 1...sets("eMedications") {
            func at(_ id: String) -> String { Nemsis.element(id, set: set) }
            let code = said(at("eMedications.03")).flatMap { rxnorm[Words.drug($0)] }
            medications += "<eMedications.MedicationGroup>" + time("eMedications.01", at("eMedications.01")) + put("eMedications.02", said(at("eMedications.03")) == nil ? nil : "9923001")
            medications += code.map { "<eMedications.03 CodeType=\"9924003\">\($0)</eMedications.03>" } ?? none("eMedications.03")
            medications += coded("eMedications.04", at("eMedications.04"), routes)
            medications += "<eMedications.DosageGroup>" + number("eMedications.05", at("eMedications.05")) + coded("eMedications.06", at("eMedications.06"), units) + "</eMedications.DosageGroup>"
            medications += coded("eMedications.07", at("eMedications.07"), ["Improved": "9916001", "Unchanged": "9916003", "Worse": "9916005"]) + none("eMedications.08") + none("eMedications.10") + "</eMedications.MedicationGroup>"
        }
        x.append(medications + "</eMedications>")

        var procedures = "<eProcedures>"
        for set in 1...sets("eProcedures") {
            func at(_ id: String) -> String { Nemsis.element(id, set: set) }
            procedures += "<eProcedures.ProcedureGroup>" + time("eProcedures.01", at("eProcedures.01")) + put("eProcedures.02", said(at("eProcedures.03")) == nil ? nil : "9923001") + none("eProcedures.03")
            procedures += number("eProcedures.05", at("eProcedures.05")) + coded("eProcedures.06", at("eProcedures.06"), ["No": "9923001", "Yes": "9923003"]) + none("eProcedures.07")
            procedures += coded("eProcedures.08", at("eProcedures.08"), ["Improved": "9916001", "Unchanged": "9916003", "Worse": "9916005"]) + none("eProcedures.10") + "</eProcedures.ProcedureGroup>"
        }
        x.append(procedures + "</eProcedures>")

        x.append("<eDisposition><eDisposition.DestinationGroup>" + put("eDisposition.01", said("eDisposition.01")) + none("eDisposition.05") + none("eDisposition.06") + none("eDisposition.07") + "</eDisposition.DestinationGroup>"
                 + "<eDisposition.IncidentDispositionGroup>" + put("eDisposition.27", "4227001") + none("eDisposition.28") + none("eDisposition.29") + none("eDisposition.30") + "</eDisposition.IncidentDispositionGroup>"
                 + none("eDisposition.16") + coded("eDisposition.17", "eDisposition.17", ["Emergent": "4217001", "Non-emergent": "4217005"])
                 + ["18", "19", "20", "21", "22", "23"].map { none("eDisposition.\($0)") }.joined()
                 + "<eDisposition.HospitalTeamActivationGroup>" + none("eDisposition.24") + none("eDisposition.25") + "</eDisposition.HospitalTeamActivationGroup>" + none("eDisposition.32") + "</eDisposition>")

        x.append("<eOutcome>" + none("eOutcome.01") + none("eOutcome.02") + "<eOutcome.EmergencyDepartmentProceduresGroup>" + none("eOutcome.09") + none("eOutcome.19") + "</eOutcome.EmergencyDepartmentProceduresGroup>"
                 + none("eOutcome.10") + none("eOutcome.11") + "<eOutcome.HospitalProceduresGroup>" + none("eOutcome.12") + none("eOutcome.20") + "</eOutcome.HospitalProceduresGroup>"
                 + none("eOutcome.13") + none("eOutcome.16") + none("eOutcome.18") + "</eOutcome>")
        x.append("</PatientCareReport>")
        x.append("</Header>")
        x.append("</EMSDataSet>")
        let head = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
                    "<!-- Written by Earshot from the call's transcript and checked by the medic. A field with no answer is \"not recorded\". Checked against the NEMSIS 3.5.1 schema, not the national or state business rules. -->"]
            + (standIns.isEmpty ? [] : ["<!-- NEEDS CREW ENTRY. NEMSIS does not allow these to be empty, so a stand-in was written:\n" + standIns.map { "     " + escape($0) }.joined(separator: "\n") + "\n-->"])
        return (head + x).joined(separator: "\n") + "\n"
    }

    /// Words in the complaint, and the NEMSIS reason for dispatch they point to.
    static let dispatch: [([String], String)] = [
        (["chest"], "2301021"), (["breath", "breathing", "asthma", "wheezing"], "2301013"), (["fall", "fell"], "2301033"), (["stroke", "facial", "slurred"], "2301067"),
        (["seizure", "seizing", "convulsions"], "2301025"), (["abdominal", "abdomen", "stomach", "belly"], "2301001"), (["allergic", "sting", "anaphylaxis"], "2301003"),
        (["overdose", "poisoning", "ingestion"], "2301053"), (["unconscious", "fainted", "syncope", "unresponsive"], "2301077"), (["diabetic", "sugar", "hypoglycemia"], "2301027"),
        (["bleeding", "laceration", "hemorrhage"], "2301045"), (["back"], "2301011"), (["crash", "collision", "mvc", "accident"], "2301069"),
    ]

    static let routes = ["IV": "9927023", "IO": "9927021", "IM": "9927015", "Intranasal": "9927017", "Oral": "9927035", "Sublingual": "9927047", "Subcutaneous": "9927045",
                         "Nebulizer": "9927071", "Inhalation": "9927009", "Nasal cannula": "9927025", "Non-rebreather mask": "9927031"]
    static let units = ["mg": "3706021", "mcg": "3706015", "g": "3706001", "mL": "3706025", "L": "3706009", "L/min": "3706035", "units": "3706049", "puffs": "3706043"]

    /// RxNorm codes of the drugs crews give most, by the name `Words.drug` settles on.
    /// ponytail: ten drugs, with codes not yet checked against RxNav. A drug not here is written as not recorded.
    static let rxnorm = ["aspirin": "1191", "nitroglycerin": "4917", "epinephrine": "3992", "naloxone": "7242", "albuterol": "435", "ondansetron": "26225",
                         "fentanyl": "4337", "oxygen": "7806", "midazolam": "6960", "dextrose": "4850"]

    private static func text(_ value: String) -> String? { value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : value }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A moment the way NEMSIS writes it: 2026-11-15T14:02:26-05:00.
    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// A clock time like "14:02:26" as a moment on the day the call started (the next day, if the call ran past midnight).
    static func moment(_ clock: String, on start: Date) -> Date? {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard (2...3).contains(parts.count), parts.count == clock.split(separator: ":").count else { return nil }
        let calendar = Calendar.current
        guard let same = calendar.date(bySettingHour: parts[0], minute: parts[1], second: parts.count > 2 ? parts[2] : 0, of: start) else { return nil }
        return same < start.addingTimeInterval(-12 * 3600) ? calendar.date(byAdding: .day, value: 1, to: same) : same
    }

    /// A state as NEMSIS wants it, a two-digit ANSI code: "MA" or "Massachusetts" is "25".
    static func state(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.count == 2, Int(name) != nil { return name }
        return states.first { $0.0.caseInsensitiveCompare(name) == .orderedSame || $0.1.caseInsensitiveCompare(name) == .orderedSame }?.2
    }
    private static let states: [(String, String, String)] = [
        ("AL", "Alabama", "01"), ("AK", "Alaska", "02"), ("AZ", "Arizona", "04"), ("AR", "Arkansas", "05"), ("CA", "California", "06"), ("CO", "Colorado", "08"), ("CT", "Connecticut", "09"),
        ("DE", "Delaware", "10"), ("DC", "District of Columbia", "11"), ("FL", "Florida", "12"), ("GA", "Georgia", "13"), ("HI", "Hawaii", "15"), ("ID", "Idaho", "16"), ("IL", "Illinois", "17"),
        ("IN", "Indiana", "18"), ("IA", "Iowa", "19"), ("KS", "Kansas", "20"), ("KY", "Kentucky", "21"), ("LA", "Louisiana", "22"), ("ME", "Maine", "23"), ("MD", "Maryland", "24"),
        ("MA", "Massachusetts", "25"), ("MI", "Michigan", "26"), ("MN", "Minnesota", "27"), ("MS", "Mississippi", "28"), ("MO", "Missouri", "29"), ("MT", "Montana", "30"), ("NE", "Nebraska", "31"),
        ("NV", "Nevada", "32"), ("NH", "New Hampshire", "33"), ("NJ", "New Jersey", "34"), ("NM", "New Mexico", "35"), ("NY", "New York", "36"), ("NC", "North Carolina", "37"), ("ND", "North Dakota", "38"),
        ("OH", "Ohio", "39"), ("OK", "Oklahoma", "40"), ("OR", "Oregon", "41"), ("PA", "Pennsylvania", "42"), ("RI", "Rhode Island", "44"), ("SC", "South Carolina", "45"), ("SD", "South Dakota", "46"),
        ("TN", "Tennessee", "47"), ("TX", "Texas", "48"), ("UT", "Utah", "49"), ("VT", "Vermont", "50"), ("VA", "Virginia", "51"), ("WA", "Washington", "53"), ("WV", "West Virginia", "54"),
        ("WI", "Wisconsin", "55"), ("WY", "Wyoming", "56"),
    ]
}
