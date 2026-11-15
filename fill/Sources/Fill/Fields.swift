import Foundation

/// The one report a call produces: a NEMSIS record, the XML that ambulance services share nationally.
///
/// This is its shape: the sections, and the fields in each. A call keeps its answers by element name, like
/// "ePatient.15": "68". In a section that repeats (vitals, medications, procedures) the second set is
/// "eVitals.06#2", the third "eVitals.06#3".
/// Element names and choices follow the NEMSIS 3.5.1 data dictionary.
public enum Nemsis {
    /// What kind of answer a field takes, which decides how the model's answer is held to shape and checked.
    public enum Kind {
        case text                          // words that must be found in the line cited
        case judged                        // a conclusion drawn from what was said; always marked to be checked
        case drug                          // a drug name that must be found in the line cited
        case number(ClosedRange<Double>)   // a number inside this range that must be found in the line cited
        case choice([String])              // one of these
        case time                          // the clock time of the line cited
    }

    public struct Field: Identifiable {
        public let id: String       // the NEMSIS element, like "ePatient.15"
        public let label: String
        public var kind = Kind.text
        public var key: String?     // what the model calls it. Nil: the model is not asked for it
        public var hint = ""        // one line telling the model what to look for
        public var long = false     // free text that wants several lines

        init(_ id: String, _ label: String, _ kind: Kind = .text, key: String? = nil, _ hint: String = "", long: Bool = false) {
            self.id = id; self.label = label; self.kind = kind; self.key = key; self.hint = hint; self.long = long
        }
    }

    public struct Section: Identifiable {
        public let id: String       // the NEMSIS section, like "ePatient"
        public let emoji: String
        public let title: String
        public var repeats = false  // more than one set in a call
        public let fields: [Field]
    }

    public static let routes = ["IV", "IO", "IM", "Intranasal", "Oral", "Sublingual", "Subcutaneous", "Nebulizer", "Inhalation", "Nasal cannula", "Non-rebreather mask"]
    public static let doseUnits = ["mg", "mcg", "g", "mL", "L", "L/min", "units", "puffs"]

    public static let sections: [Section] = [
        Section(id: "eTimes", emoji: "🕐", title: "Times", fields: [
            Field("eTimes.03", "Unit notified"),
            Field("eTimes.05", "En route", .time, key: "en_route", "the crew says they are on the way to the call"),
            Field("eTimes.06", "Arrived on scene", .time, key: "on_scene", "the crew says they have arrived at the scene"),
            Field("eTimes.07", "Arrived at patient"),
            Field("eTimes.09", "Left scene", .time, key: "left_scene", "the crew says they are leaving the scene or starting transport"),
            Field("eTimes.11", "Arrived at destination", .time, key: "at_destination", "the crew says they have arrived at the hospital (\"we're at the E D\")"),
        ]),
        Section(id: "ePatient", emoji: "🧑", title: "Patient", fields: [
            Field("ePatient.03", "First name", key: "first_name", "the patient's first name"),
            Field("ePatient.02", "Last name", key: "last_name", "the patient's last name"),
            Field("ePatient.15", "Age", .number(1...120), key: "age", "the patient's age, as a number"),
            Field("ePatient.16", "Age units", .choice(["Years", "Months", "Days", "Hours", "Minutes"]), key: "age_units", "the unit the age was given in"),
            Field("ePatient.25", "Sex", .choice(["Female", "Male"]), key: "sex", "the patient's sex, when said (male, female, man, woman)"),
            Field("ePatient.17", "Date of birth"),
        ]),
        Section(id: "eScene", emoji: "📍", title: "Scene", fields: [
            Field("eScene.09", "Location type", .choice(["Home", "Street or highway", "Business", "Healthcare facility", "School", "Public place", "Other"]), key: "location_type", "the kind of place the patient was found"),
            Field("eScene.15", "Street address"), Field("eScene.17", "City"), Field("eScene.18", "State"), Field("eScene.19", "ZIP code"),
            Field("eScene.06", "Patients at scene", .choice(["Single", "Multiple", "None"])),
        ]),
        Section(id: "eSituation", emoji: "🩺", title: "Situation", fields: [
            Field("eSituation.04", "Complaint", key: "complaint", "the main complaint, in the words used"),
            Field("eSituation.05", "Duration of complaint", .number(1...365), key: "duration", "how long today's complaint has lasted, as the number said (\"an hour\" is 1)"),
            Field("eSituation.06", "Duration units", .choice(["Seconds", "Minutes", "Hours", "Days", "Weeks", "Months", "Years"]), key: "duration_units", "the unit of that duration"),
            Field("eSituation.01", "Symptom onset"),
            Field("eSituation.09", "Primary symptom", key: "symptom", "the main symptom, in the words used"),
            Field("eSituation.07", "Where on the body", .choice(["Abdomen", "Back", "Chest", "Extremity-Lower", "Extremity-Upper", "General/Global", "Genitalia", "Head", "Neck"]), key: "body_area", "where on the body the complaint is"),
            Field("eSituation.11", "Primary impression", .judged, key: "impression", "what the crew says they think is wrong (their working diagnosis)"),
        ]),
        Section(id: "eHistory", emoji: "📋", title: "History", fields: [
            Field("eHistory.06", "Medication allergies", key: "allergies", "what the patient is allergic to, or \"none\" if they say no allergies"),
            Field("eHistory.12", "Current medications", key: "home_medications", "medicines the patient takes at home"),
            Field("eHistory.08", "Medical and surgical history", key: "history", "illnesses and operations the patient had before today, not today's complaint"),
            Field("eHistory.17", "Alcohol or drug use"),
        ]),
        Section(id: "eVitals", emoji: "❤️", title: "Vitals", repeats: true, fields: [
            Field("eVitals.01", "Taken at", .time),
            Field("eVitals.06", "Systolic BP", .number(30...300), key: "bp_systolic", "blood pressure, the first (higher) number"),
            Field("eVitals.07", "Diastolic BP", .number(10...200), key: "bp_diastolic", "blood pressure, the second (lower) number"),
            Field("eVitals.10", "Heart rate", .number(10...300), key: "heart_rate", "heart rate or pulse, beats a minute"),
            Field("eVitals.14", "Respiratory rate", .number(4...60), key: "resp_rate", "breaths a minute (resps, respirations)"),
            Field("eVitals.12", "Pulse oximetry", .number(30...100), key: "spo2", "oxygen saturation (sats, SpO2), percent"),
            Field("eVitals.18", "Blood glucose", .number(10...1500), key: "glucose", "blood sugar"),
            Field("eVitals.24", "Temperature", .number(20...110), key: "temperature", "temperature"),
            Field("eVitals.23", "Glasgow Coma Score", .number(3...15), key: "gcs", "GCS total"),
            Field("eVitals.27", "Pain, 0 to 10", .number(0...10), key: "pain", "pain score out of ten"),
        ]),
        Section(id: "eMedications", emoji: "💊", title: "Medications given", repeats: true, fields: [
            Field("eMedications.03", "Medication", .drug), Field("eMedications.05", "Dose", .number(0.001...10000)),
            Field("eMedications.06", "Dose units", .choice(doseUnits)), Field("eMedications.04", "Route", .choice(routes)),
            Field("eMedications.01", "Given at", .time), Field("eMedications.07", "Response", .choice(["Improved", "Unchanged", "Worse"])),
        ]),
        Section(id: "eProcedures", emoji: "🛠️", title: "Procedures", repeats: true, fields: [
            Field("eProcedures.03", "Procedure", .judged), Field("eProcedures.01", "Done at", .time),
            Field("eProcedures.05", "Attempts", .number(1...10)), Field("eProcedures.06", "Successful", .choice(["Yes", "No"])),
            Field("eProcedures.08", "Response", .choice(["Improved", "Unchanged", "Worse"])),
        ]),
        Section(id: "eDisposition", emoji: "🏥", title: "Disposition", fields: [
            Field("eDisposition.01", "Destination", key: "destination", "the hospital or place the patient is taken to"),
            Field("eDisposition.30", "Transport disposition"),
            Field("eDisposition.17", "Transport mode from scene", .choice(["Emergent", "Non-emergent"]), key: "transport_mode", "Emergent if lights and sirens are said; Non-emergent if said to be without"),
            Field("eDisposition.19", "Acuity at release", .choice(["Critical", "Emergent", "Lower acuity"])),
            Field("eDisposition.20", "Why this destination"),
        ]),
        Section(id: "eNarrative", emoji: "📝", title: "Narrative", fields: [
            Field("eNarrative.01", "Patient care report narrative", long: true),
        ]),
    ]

    public static let fields: [String: Field] = Dictionary(uniqueKeysWithValues: sections.flatMap(\.fields).map { ($0.id, $0) })
    public static let fieldCount = fields.count

    /// The element of a field in the nth set of a repeating section: "eVitals.06" for the first, "eVitals.06#2" for the second.
    public static func element(_ id: String, set: Int) -> String { set <= 1 ? id : "\(id)#\(set)" }

    /// How many sets of a repeating section a report holds; 1 when it holds none.
    public static func sets(of section: Section, in report: [String: String]) -> Int {
        guard section.repeats else { return 1 }
        return report.keys.filter { $0.hasPrefix(section.id + ".") && !answer(report[$0]).isEmpty }
            .map { Int($0.split(separator: "#").dropFirst().first ?? "1") ?? 1 }.max() ?? 1
    }

    /// How many fields have an answer: in one set of a section, or (with no section) in the whole report.
    public static func filled(_ report: [String: String], in section: Section? = nil, set: Int = 1) -> Int {
        guard let section else { return report.values.filter { !answer($0).isEmpty }.count }
        return section.fields.filter { !answer(report[element($0.id, set: set)]).isEmpty }.count
    }

    /// How many fields there are to fill, counting every set of the sections that repeat.
    public static func total(in report: [String: String]) -> Int {
        sections.reduce(0) { $0 + $1.fields.count * sets(of: $1, in: report) }
    }

    /// What to call a call in a list: the patient's name, or age and sex, or the complaint. Nil when none is known.
    public static func title(of report: [String: String]) -> String? {
        func at(_ id: String) -> String { answer(report[id]) }
        let name = [at("ePatient.03"), at("ePatient.02")].filter { !$0.isEmpty }.joined(separator: " ")
        let who = [at("ePatient.15").isEmpty ? "" : "\(at("ePatient.15")) \(at("ePatient.16").isEmpty ? "years" : at("ePatient.16").lowercased())", at("ePatient.25")]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        return [name, who, at("eSituation.04")].first { !$0.isEmpty }
    }

    private static func answer(_ value: String?) -> String { (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
}
