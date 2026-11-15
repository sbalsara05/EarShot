import SwiftUI

/// The one report a call produces: a NEMSIS record, the XML that ambulance services share nationally.
///
///   transcript ─► (not built yet: a step that reads it and fills the fields) ─► NEMSIS fields ─► XML
///
/// This file is the shape of that record as the app shows it: the sections, the fields in each, and the screen
/// that lays them out. A call keeps its answers by element name, like "ePatient.15": "68". Until the step that
/// reads the transcript exists every field starts empty, and the medic can fill any of them in by hand.
/// ponytail: one set of vitals, one medication and one procedure per call. NEMSIS lets each repeat; make those
/// sections lists when the filling step can produce more than one.
enum Nemsis {
    struct Field: Identifiable {
        let id: String      // the NEMSIS element, like "ePatient.15"
        let label: String
        var long = false    // free text that wants several lines
    }

    struct Section: Identifiable {
        let id: String      // the NEMSIS section, like "ePatient"
        let emoji: String
        let title: String
        let fields: [Field]
    }

    /// Element names follow the NEMSIS 3.5 data dictionary.
    static let sections: [Section] = [
        Section(id: "eTimes", emoji: "🕐", title: "Times", fields: [
            Field(id: "eTimes.03", label: "Unit notified"), Field(id: "eTimes.05", label: "En route"),
            Field(id: "eTimes.06", label: "Arrived on scene"), Field(id: "eTimes.07", label: "Arrived at patient"),
            Field(id: "eTimes.09", label: "Left scene"), Field(id: "eTimes.11", label: "Arrived at destination"),
        ]),
        Section(id: "ePatient", emoji: "🧑", title: "Patient", fields: [
            Field(id: "ePatient.03", label: "First name"), Field(id: "ePatient.02", label: "Last name"),
            Field(id: "ePatient.15", label: "Age"), Field(id: "ePatient.16", label: "Age units"),
            Field(id: "ePatient.13", label: "Gender"), Field(id: "ePatient.17", label: "Date of birth"),
        ]),
        Section(id: "eScene", emoji: "📍", title: "Scene", fields: [
            Field(id: "eScene.09", label: "Location type"), Field(id: "eScene.15", label: "Street address"),
            Field(id: "eScene.17", label: "City"), Field(id: "eScene.18", label: "State"),
            Field(id: "eScene.19", label: "ZIP code"), Field(id: "eScene.06", label: "Patients at scene"),
        ]),
        Section(id: "eSituation", emoji: "🩺", title: "Situation", fields: [
            Field(id: "eSituation.04", label: "Complaint"), Field(id: "eSituation.05", label: "Duration of complaint"),
            Field(id: "eSituation.01", label: "Symptom onset"), Field(id: "eSituation.09", label: "Primary symptom"),
            Field(id: "eSituation.07", label: "Where on the body"), Field(id: "eSituation.11", label: "Primary impression"),
        ]),
        Section(id: "eHistory", emoji: "📋", title: "History", fields: [
            Field(id: "eHistory.06", label: "Medication allergies"), Field(id: "eHistory.12", label: "Current medications"),
            Field(id: "eHistory.08", label: "Medical and surgical history"), Field(id: "eHistory.17", label: "Alcohol or drug use"),
        ]),
        Section(id: "eVitals", emoji: "❤️", title: "Vitals", fields: [
            Field(id: "eVitals.01", label: "Taken at"), Field(id: "eVitals.06", label: "Systolic BP"),
            Field(id: "eVitals.07", label: "Diastolic BP"), Field(id: "eVitals.10", label: "Heart rate"),
            Field(id: "eVitals.14", label: "Respiratory rate"), Field(id: "eVitals.12", label: "Pulse oximetry"),
            Field(id: "eVitals.18", label: "Blood glucose"), Field(id: "eVitals.24", label: "Temperature"),
            Field(id: "eVitals.23", label: "Glasgow Coma Score"), Field(id: "eVitals.27", label: "Pain, 0 to 10"),
        ]),
        Section(id: "eMedications", emoji: "💊", title: "Medications given", fields: [
            Field(id: "eMedications.03", label: "Medication"), Field(id: "eMedications.05", label: "Dose"),
            Field(id: "eMedications.06", label: "Dose units"), Field(id: "eMedications.04", label: "Route"),
            Field(id: "eMedications.01", label: "Given at"), Field(id: "eMedications.07", label: "Response"),
        ]),
        Section(id: "eProcedures", emoji: "🛠️", title: "Procedures", fields: [
            Field(id: "eProcedures.03", label: "Procedure"), Field(id: "eProcedures.01", label: "Done at"),
            Field(id: "eProcedures.05", label: "Attempts"), Field(id: "eProcedures.06", label: "Successful"),
            Field(id: "eProcedures.08", label: "Response"),
        ]),
        Section(id: "eDisposition", emoji: "🏥", title: "Disposition", fields: [
            Field(id: "eDisposition.01", label: "Destination"), Field(id: "eDisposition.30", label: "Transport disposition"),
            Field(id: "eDisposition.17", label: "Transport mode from scene"), Field(id: "eDisposition.19", label: "Final patient acuity"),
            Field(id: "eDisposition.20", label: "Why this destination"),
        ]),
        Section(id: "eNarrative", emoji: "📝", title: "Narrative", fields: [
            Field(id: "eNarrative.01", label: "Patient care report narrative", long: true),
        ]),
    ]

    static let fieldCount = sections.reduce(0) { $0 + $1.fields.count }

    /// How many of the fields shown have an answer.
    static func filled(_ report: [String: String], in section: Section? = nil) -> Int {
        (section.map { [$0] } ?? sections).flatMap(\.fields).filter { !(report[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    /// What to call a call in a list: the patient's name, or age and gender, or the complaint. Nil when none is known.
    static func title(of report: [String: String]) -> String? {
        func answer(_ id: String) -> String { (report[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = [answer("ePatient.03"), answer("ePatient.02")].filter { !$0.isEmpty }.joined(separator: " ")
        let who = [answer("ePatient.15").isEmpty ? "" : "\(answer("ePatient.15")) \(answer("ePatient.16").isEmpty ? "years" : answer("ePatient.16"))", answer("ePatient.13")]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        return [name, who, answer("eSituation.04")].first { !$0.isEmpty }
    }
}

/// The two views of a completed call.
enum ReportTab: String, CaseIterable, Identifiable {
    case summary = "Summary", transcript = "Transcript"
    var id: String { rawValue }
}

/// Summary | Transcript: the bar at the top of a completed call. The filled pill slides to the one chosen.
struct ReportTabs: View {
    @Binding var tab: ReportTab
    @Namespace private var pick

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ReportTab.allCases) { one in
                let on = one == tab
                Button { tab = one } label: {
                    Text(one.rawValue).font(geist(fit(17, 16), 600)).lineLimit(1)
                        .foregroundStyle(on ? Color.bg : .dim)
                        .padding(.horizontal, fit(36, 12))
                        .frame(maxWidth: phone ? .infinity : nil)
                        .frame(height: 44)
                        .background { if on { Capsule().fill(Color.ink).matchedGeometryEffect(id: "tab", in: pick) } }
                        .contentShape(Capsule())
                }
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .buttonStyle(.plain)
        .padding(4)
        .background(Color.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.line))
        .smooth(tab, 0.28)
    }
}

/// The NEMSIS record of a call, a card for each section. With `edit`, every answer can be typed over; without,
/// it is read only. A field with no answer reads "n/a".
struct SummaryView: View {
    var report: [String: String]
    var edit: ((String, String) -> Void)? = nil   // (element, new answer)

    var body: some View {
        VStack(alignment: .leading, spacing: fit(20, 16)) {
            let filled = Nemsis.filled(report)
            HStack(spacing: 10) {
                Text("🚑").font(.system(size: 22))
                Text("NEMSIS report").font(geist(17, 600))
                Spacer()
                Text("\(filled) of \(Nemsis.fieldCount) filled").font(geist(15, 600).monospacedDigit())
                    .foregroundStyle(filled == 0 ? Color.dim : .green)
            }
            if filled == 0 {
                Text(edit == nil ? "No fields were filled on this call."
                     : "Nothing is filled in yet: the step that reads the transcript into these fields is still being built. You can type any answer in yourself.")
                    .font(geist(15, 500)).foregroundStyle(Color.dim).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Nemsis.sections) { section in card(section) }
        }
    }

    private func card(_ section: Nemsis.Section) -> some View {
        let filled = Nemsis.filled(report, in: section)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(section.emoji).font(.system(size: fit(28, 24)))
                Text(section.title).font(doto(fit(26, 22)))
                Text(section.id).font(geist(14, 500).monospaced()).foregroundStyle(Color.mid)
                Spacer()
                Text("\(filled)/\(section.fields.count)").font(geist(15, 600).monospacedDigit())
                    .foregroundStyle(filled == 0 ? Color.mid : filled == section.fields.count ? .green : .yellow)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(section.title), \(filled) of \(section.fields.count) filled")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: section.fields.contains { $0.long } ? 600 : fit(220, 140)), spacing: 20, alignment: .topLeading)],
                      alignment: .leading, spacing: 18) {
                ForEach(section.fields) { field in answer(field) }
            }
        }
        .padding(fit(24, 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func answer(_ field: Nemsis.Field) -> some View {
        let value = report[field.id] ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(field.label).font(geist(15, 600)).foregroundStyle(Color.dim).lineLimit(1).minimumScaleFactor(0.8)
                Text(field.id.split(separator: ".").last.map(String.init) ?? "").font(geist(12, 500).monospaced()).foregroundStyle(Color.mid)
            }
            if let edit {
                TextField(field.label, text: Binding { value } set: { edit(field.id, $0) }, prompt: Text("n/a").foregroundColor(.mid), axis: field.long ? .vertical : .horizontal)
                    .lineLimit(field.long ? 3...12 : 1...1)
                    .font(geist(fit(20, 18), 500)).tint(.yellow)
                    .frame(minHeight: 36)
                    .accessibilityLabel("\(field.label), \(field.id)")
                Color.ghost.frame(height: 1)
            } else {
                Text(value.isEmpty ? "n/a" : value).font(geist(fit(20, 18), 500)).foregroundStyle(value.isEmpty ? Color.mid : .ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
