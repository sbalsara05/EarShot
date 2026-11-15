import SwiftUI
import Fill

// The report's shape (its sections and fields) is `Nemsis`, in the Fill package, which also fills it from the
// transcript. This file is how the app shows it.

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

/// The NEMSIS record of a call, a card for each section; vitals, medications and procedures get a card for each
/// set. With `edit`, every answer can be typed over; without, it is read only. A field with no answer reads "n/a".
///
/// An answer the transcript filled in carries a chip with the time of the line it came from. Tap it to see that
/// line and hear it. Yellow answers are the ones to look at: the line was doubted, or it is a conclusion.
struct SummaryView: View {
    var call: Call
    var filling: Filling? = nil                     // how far along the filling is, while it runs
    var edit: ((String, String) -> Void)? = nil     // (element, new answer)
    var hear: ((Item) -> Void)? = nil               // play a transcript line
    var playing: Item.ID? = nil
    @State private var shown: String?               // the element whose line is on show

    private var report: [String: String] { call.report ?? [:] }

    var body: some View {
        let rows = Dictionary(uniqueKeysWithValues: call.recordings.flatMap(\.items).map { ($0.id, $0) })
        VStack(alignment: .leading, spacing: fit(20, 16)) {
            let filled = Nemsis.filled(report), check = (call.evidence ?? [:]).values.filter(\.check).count
            HStack(spacing: 10) {
                Text("🚑").font(.system(size: 22))
                Text("NEMSIS report").font(geist(17, 600))
                Spacer()
                if check > 0 { Text("\(check) to check").font(geist(15, 600).monospacedDigit()).foregroundStyle(Color.yellow) }
                Text("\(filled) of \(Nemsis.total(in: report)) filled").font(geist(15, 600).monospacedDigit())
                    .foregroundStyle(filled == 0 ? Color.dim : .green)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if waiting { Working() }
                Text(note).font(geist(15, 500)).foregroundStyle(waiting ? Color.yellow : .dim).fixedSize(horizontal: false, vertical: true)
            }
            if let filling { WorkBar(done: filling.done) }
            ForEach(Nemsis.sections) { section in
                ForEach(1...Nemsis.sets(of: section, in: report), id: \.self) { set in card(section, set, rows) }
            }
        }
    }

    /// The call is still being worked on: its transcript is being finished, or its report filled.
    private var waiting: Bool { filling != nil || (edit != nil && !call.drafted) }

    /// One line under the heading: what filled the report, or why nothing did.
    private var note: String {
        if let filling { return "Filling the report from the transcript on this \(deviceName). \(filling.text)." }
        if waiting { return "Finishing the transcript. The report fills from it next." }
        if let why = call.fillNote { return why }
        if let model = call.filledBy { return "Filled from the transcript by \(model), on this \(deviceName). Tap a time to hear where an answer came from." }
        return edit == nil ? "This report was filled in by hand." : "Not filled from the transcript. You can type any answer in yourself."
    }

    private func card(_ section: Nemsis.Section, _ set: Int, _ rows: [Item.ID: Item]) -> some View {
        let filled = Nemsis.filled(report, in: section, set: set)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(section.emoji).font(.system(size: fit(28, 24)))
                Text(section.repeats && Nemsis.sets(of: section, in: report) > 1 ? "\(section.title) \(set)" : section.title).font(doto(fit(26, 22)))
                Text(section.id).font(geist(14, 500).monospaced()).foregroundStyle(Color.mid)
                Spacer()
                Text("\(filled)/\(section.fields.count)").font(geist(15, 600).monospacedDigit())
                    .foregroundStyle(filled == 0 ? Color.mid : filled == section.fields.count ? .green : .yellow)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(section.title), \(filled) of \(section.fields.count) filled")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: section.fields.contains { $0.long } ? 600 : fit(220, 140)), spacing: 20, alignment: .topLeading)],
                      alignment: .leading, spacing: 18) {
                ForEach(section.fields) { field in answer(field, Nemsis.element(field.id, set: set), rows) }
            }
        }
        .padding(fit(24, 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func answer(_ field: Nemsis.Field, _ element: String, _ rows: [Item.ID: Item]) -> some View {
        let value = report[element] ?? ""
        let evidence = call.evidence?[element]
        let row = evidence?.line.flatMap { rows[$0] }
        let tint: Color = evidence?.check == true ? .yellow : .ink
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(field.label).font(geist(15, 600)).foregroundStyle(Color.dim).lineLimit(1).minimumScaleFactor(0.8)
                Text(field.id.split(separator: ".").last.map(String.init) ?? "").font(geist(12, 500).monospaced()).foregroundStyle(Color.mid)
            }
            if let edit {
                TextField(field.label, text: Binding { value } set: { edit(element, $0) }, prompt: Text(waiting ? "…" : "n/a").foregroundColor(.mid), axis: field.long ? .vertical : .horizontal)
                    .lineLimit(field.long ? 3...12 : 1...1)
                    .font(geist(fit(20, 18), 500)).tint(.yellow).foregroundStyle(tint)
                    .frame(minHeight: 36)
                    .accessibilityLabel("\(field.label), \(field.id)")
                Color.ghost.frame(height: 1)
            } else {
                Text(value.isEmpty ? "n/a" : value).font(geist(fit(20, 18), 500)).foregroundStyle(value.isEmpty ? Color.mid : tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let evidence, !value.isEmpty {
                HStack(spacing: 8) {
                    if let row {
                        Button {
                            shown = shown == element ? nil : element
                            if shown == element, !row.text.isEmpty { hear?(row) }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: playing == row.id ? "speaker.wave.2.fill" : row.text.isEmpty ? "mappin" : "play.fill").font(.system(size: 11))
                                Text(stamp(row.time)).font(geist(13, 600).monospacedDigit())
                            }
                            .foregroundStyle(playing == row.id ? Color.green : .dim)
                            .padding(.horizontal, 9).frame(height: 26)
                            .background(Color.ghost, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("From the transcript at \(stamp(row.time)). Tap to hear it.")
                    }
                    if evidence.check { Text("check").font(geist(13, 600)).foregroundStyle(Color.yellow) }
                    if let other = evidence.other { Text("or \(other)").font(geist(13, 500)).foregroundStyle(Color.yellow).lineLimit(1) }
                }
                .padding(.top, 2)
                if shown == element, let row {
                    Text(row.text.isEmpty ? (row.place?.line ?? "") : "\u{201C}\(row.text)\u{201D}").font(geist(14, 500)).italic().foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
