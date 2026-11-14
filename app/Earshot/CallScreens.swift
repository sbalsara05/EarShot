import SwiftUI

// MARK: Live Call

struct LiveScreen: View {
    @Environment(Model.self) private var model

    @State private var completing = false

    private var number: Int { model.call.recordings.count }
    private var current: Recording { model.call.recordings.last ?? Recording() }

    var body: some View {
        switch model.live {
        case .none: idle
        case .ready: ready
        case .listening: Ticker(fps: 4) { _ in listening }   // redraws the clock
        case .between: between
        case .cutShort: cutShort
        }
    }

    /// iPad: headline, meter and controls in a left column, transcript on the right.
    /// iPhone: one column, with the controls at the bottom where a thumb reaches them.
    @ViewBuilder private func column(@ViewBuilder top: () -> some View, @ViewBuilder middle: () -> some View, @ViewBuilder bottom: () -> some View) -> some View {
        let panel = transcript
            .padding(.horizontal, fit(40, 20)).padding(.vertical, fit(36, 20))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panel()
        if phone {
            VStack(alignment: .leading, spacing: 16) {
                top()
                middle()
                panel
                bottom()
            }
        } else {
            HStack(spacing: 32) {
                VStack(alignment: .leading, spacing: 0) {
                    top()
                    Spacer()
                    middle()
                    Spacer()
                    bottom()
                }
                .padding(.top, 12).padding(.leading, 24)
                .frame(width: 420, alignment: .leading)
                panel
            }
        }
    }

    private func counter(_ label: String, _ value: String, labelColor: Color = .dim, valueColor: Color = .ink) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(geist(17, 500)).foregroundStyle(labelColor)
            Text(value).font(doto(fit(118, 84))).foregroundStyle(valueColor).lineLimit(1).minimumScaleFactor(0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private func stopwatch(_ seconds: Int) -> String { String(format: "%02d:%02d", seconds / 60, seconds % 60) }

    private func meter(lit: Color) -> some View {
        let levels = model.levels
        return Dots.meter(cols: 30, rows: 6, lit: lit) { levels[$0] }
    }

    private func recordButton(_ label: String) -> some View {
        Button { model.record() } label: {
            Circle().fill(Color.red).frame(width: 64, height: 64)
                .frame(width: 96, height: 96).overlay(Circle().strokeBorder(Color.ink, lineWidth: 3))
        }
        .buttonStyle(Press())
        .accessibilityLabel(label)
    }

    private var idle: some View {
        column {
            Text("No call yet").font(doto(fit(96, 52)))
        } middle: {
            Dots.meter(cols: 30, rows: 6, lit: .ink) { _ in 0 }
        } bottom: {
            Button { model.newCall() } label: {
                Circle().fill(Color.red).frame(width: 14, height: 14)
                Text("New call")
            }
            .buttonStyle(Pill(height: 76, size: 22, grow: true))
        }
    }

    private var ready: some View {
        column {
            counter("Recording", "00:00", valueColor: .mid)
        } middle: {
            Dots.meter(cols: 30, rows: 6, lit: .ink) { _ in 0 }
        } bottom: {
            HStack(spacing: 20) {
                recordButton("Start recording")
                Text("Start recording").font(geist(22, 600))
            }
        }
    }

    private var listening: some View {
        column {
            counter("Recording", stopwatch(current.seconds))
        } middle: {
            meter(lit: .ink)
        } bottom: {
            HStack(spacing: 20) {
                Button { model.stop() } label: {
                    // Two bars: this pauses. The same recording carries on when it is resumed.
                    HStack(spacing: 9) {
                        ForEach(0..<2, id: \.self) { _ in RoundedRectangle(cornerRadius: 3).fill(Color.bg).frame(width: 10, height: 30) }
                    }
                    .frame(width: 96, height: 96).background(Color.red, in: Circle())
                }
                .buttonStyle(Press())
                .accessibilityLabel("Pause recording")
                Button { model.mark() } label: {
                    Flag(color: .bg, size: 22)
                    Text("Mark")
                }
                .buttonStyle(Pill(fill: .yellow, height: 96, size: 26, grow: true))
            }
        }
    }

    private var between: some View {
        column {
            counter("Paused at", stopwatch(model.call.recordings.reduce(0) { $0 + $1.seconds }), valueColor: .mid)
        } middle: {
            meter(lit: .mid)
        } bottom: {
            HStack(spacing: 20) {
                recordButton("Resume recording")
                Button("Complete") { completing = true }.buttonStyle(Pill(height: 96, size: 26, grow: true))
                    .confirmationDialog("Complete this call?", isPresented: $completing, titleVisibility: .visible) {
                        Button("Complete and write reports", role: .destructive) { model.complete() }
                        Button("Keep recording", role: .cancel) {}
                    } message: {
                        Text("This cannot be undone. The recording ends for good and the nurse handoff and PCR are written from it. The reports wait on the AI Drafts tab for you to check and sign, and you can start a new call straight away.")
                    }
            }
        }
    }

    private var cutShort: some View {
        column {
            counter("Recording stopped at", stopwatch(current.seconds), labelColor: .red, valueColor: .mid)
        } middle: {
            if !phone { ClipModel(ghost: true, scale: 0.55).frame(width: 145, height: 185) }
        } bottom: {
            VStack(spacing: 20) {
                Button { model.record() } label: {
                    Circle().fill(Color.red).frame(width: 14, height: 14)
                    Text("Keep recording on \(deviceName)")
                }
                .buttonStyle(Pill(height: 72, grow: true))
                Button("Reconnect clip") { model.tab = .clip }.buttonStyle(Pill(fill: nil, height: 72, grow: true))
            }
        }
    }

    // Right panel: the transcript.

    @ViewBuilder private var transcript: some View {
        switch model.live {
        case .none:
            empty("Start a call and what is said will appear here.")
        case .ready:
            empty(model.problem ?? "What is said will appear here as you record.", color: model.problem == nil ? .dim : .red)
        case .listening:
            if current.items.isEmpty {
                empty("What is said will appear here as you record.")
            } else {
                feed { TranscriptRows(recording: current, liveLine: model.liveLine) }
            }
        case .between, .cutShort:
            feed {
                ForEach(Array(model.call.recordings.enumerated()), id: \.offset) { n, recording in
                    RecordingHeading(number: n + 1, recording: recording)
                    TranscriptRows(recording: recording, color: n == number - 1 ? .ink : .dim)
                }
                if let problem = model.problem { alert("Problem", problem) }
                if model.live == .cutShort {
                    alert("Clip disconnected at \(clock(current.end ?? Date()))", "The recording is saved up to that point, with its marks.")
                }
            }
        }
    }

    private func empty(_ text: String, color: Color = .dim) -> some View {
        VStack(spacing: 20) {
            Dots(cols: 13, rows: 1, pitch: 12, r: 4.32) { x, _ in x % 2 == 0 ? .mid : .off }
            Text(text).font(geist(20)).lineSpacing(5).foregroundStyle(color).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
    }

    /// Rows sit at the bottom of the panel and scroll back; new rows keep the view pinned to the latest.
    private func feed(@ViewBuilder _ rows: () -> some View) -> some View {
        let rows = rows()
        return GeometryReader { box in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { rows }
                    .frame(maxWidth: .infinity, minHeight: box.size.height, alignment: .bottomLeading)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.hidden)
        }
    }

    private func alert(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(geist(22, 600)).foregroundStyle(Color.red)
            Text(detail).font(geist(18)).lineSpacing(4)
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.red, lineWidth: 1.5))
    }
}

// MARK: AI Drafts

/// Every completed call: the ones still waiting for a person to check and sign them, then the signed ones.
struct DraftsScreen: View {
    @Environment(Model.self) private var model
    @State private var reviewing: Call?   // a call waiting for sign-off, open in its sheet
    @State private var opened: Call?      // a signed call being read

    var body: some View {
        Split {
            VStack(alignment: .leading, spacing: 28) {
                Text(headline).font(doto(fit(112, 60)))
                Text(summary).font(geist(22)).lineSpacing(6).foregroundStyle(Color.dim).frame(maxWidth: 440, alignment: .leading)
            }
            .padding(.leading, fit(24, 4))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            if model.review.isEmpty && model.past.isEmpty {
                Dots(pageArt, pitch: 16, r: 5.76, palette: ["b": .outline, ".": .off])
                    .side().frame(maxHeight: phone ? 280 : .infinity).panel()
                    .accessibilityHidden(true)
            } else {
                calls
                    .padding(.horizontal, fit(32, 20)).padding(.vertical, fit(20, 12))
                    .side().frame(minHeight: phone ? 320 : nil, maxHeight: phone ? nil : .infinity).panel()
            }
        }
        .sheet(item: $reviewing) { ReviewSheet(id: $0.id).presentationSizing(.page).presentationDragIndicator(.visible) }
        .sheet(item: $opened) { call in
            PastCallView(call: call) { model.reopen(call.id) }.presentationSizing(.page).presentationDragIndicator(.visible)
        }
    }

    private var headline: String {
        !model.review.isEmpty ? "To sign" : model.past.isEmpty ? "No drafts yet" : "All signed"
    }

    private var summary: String {
        if model.review.isEmpty && model.past.isEmpty { return "Record a call, then tap Complete." }
        if model.review.isEmpty { return "\(plural(model.past.count, "signed call")). Tap one to read its reports." }
        return "\(plural(model.review.count, "call")) waiting for you to check and sign. Nothing is final until you do."
    }

    private var calls: some View {
        List {
            if !model.review.isEmpty {
                Section {
                    ForEach(model.review) { call in CallRow(call: call, waiting: true) { reviewing = call } }
                } header: {
                    Text("Needs sign-off").font(geist(15, 600)).foregroundStyle(Color.yellow).textCase(nil)
                }
                .listSectionSeparator(.hidden)
            }
            if !model.past.isEmpty {
                Section {
                    ForEach(model.past) { call in CallRow(call: call, waiting: false) { opened = call } }
                        .onDelete { model.delete(at: $0) }
                } header: {
                    Text("Signed").font(geist(15, 600)).foregroundStyle(Color.dim).textCase(nil)
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
    }

}

/// One completed call in a list. A waiting one carries a yellow dot and says what it needs; a signed one says
/// when it was signed. Used on AI Drafts and on Home.
struct CallRow: View {
    var call: Call
    var waiting: Bool
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                if waiting { Circle().fill(Color.yellow).frame(width: 10, height: 10) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(!call.draft.patient.isEmpty ? call.draft.patient : call.drafted ? "Patient not recorded" : "Call at \(clock(call.start))")
                        .font(geist(19, 500)).foregroundStyle(Color.ink).lineLimit(1)
                    Text("\(day(call.start)), \(span(call.seconds))").font(geist(15)).foregroundStyle(Color.dim).lineLimit(1)
                }
                Spacer()
                if waiting {
                    Text(call.drafted ? "Check and sign" : "Writing reports").font(geist(15, 600)).foregroundStyle(Color.yellow)
                } else {
                    Text("Signed \(clock(call.signedAt ?? call.start))").font(geist(15, 500).monospacedDigit()).foregroundStyle(Color.green)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Color.line)
        .accessibilityElement(children: .combine)
    }
}

/// A completed call waiting for sign-off, opened from AI Drafts. It shows everything a signed call shows, and
/// here the handoff lines can still be corrected and the call signed.
struct ReviewSheet: View {
    let id: Call.ID
    @Environment(Model.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var signing = false

    var body: some View {
        @Bindable var model = model
        // Looked up afresh on every draw: the list shifts when another call is completed or this one is signed.
        if let i = model.review.firstIndex(where: { $0.id == id }) {
            let call = model.review[i]
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(day(call.start)).font(doto(fit(40, 28))).lineLimit(1).minimumScaleFactor(0.6)
                        Text(call.drafted ? call.draftNote ?? "AI draft, not signed. Tap any line to correct it. Yellow lines need you." : "Writing the reports on this \(deviceName).")
                            .font(geist(15, 500)).foregroundStyle(call.drafted && call.draftNote == nil ? Color.dim : .yellow)
                    }
                    Spacer()
                    Button("Close") { dismiss() }.buttonStyle(Pill(fill: nil, height: 44, size: 16))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 36) {
                        if call.drafted {
                            part("Nurse handoff") {
                                field("Patient", $model.review[i].draft.patient)
                                field("Latest vitals", $model.review[i].draft.latestVitals)
                                field("Given", $model.review[i].draft.given)
                                field("Allergies", $model.review[i].draft.allergies)
                                ForEach(call.silentMarks) { mark in
                                    let n = mark.mark ?? 0
                                    field("\(clock(mark.time)), nothing heard", Binding { call.markNotes[n] ?? "" } set: { model.review[i].markNotes[n] = $0 },
                                          mark: "Mark \(n)", prompt: "What happened here?")
                                }
                            }
                            part("PCR") {
                                formatChoice(call)
                                PCRView(call: call)
                            }
                        }
                        part("Transcript") {
                            if call.transcript.isEmpty { Text("Nothing was heard on this call.").font(geist(fit(22, 19))).foregroundStyle(Color.dim) }
                            ForEach(Array(call.recordings.enumerated()), id: \.offset) { n, recording in
                                RecordingHeading(number: n + 1, recording: recording)
                                TranscriptRows(recording: recording, color: .ink)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                // Nothing is signed while its narrative is still being rewritten.
                let rewriting = model.rewriting[id] != nil
                Button(!call.drafted ? "Writing reports" : rewriting ? "Writing the narrative" : "Sign off") { signing = true }
                    .buttonStyle(Pill(grow: true))
                    .disabled(!call.drafted || rewriting)
            }
            .padding(.horizontal, fit(40, 20)).padding(.top, fit(36, 28)).padding(.bottom, fit(32, 12))
            .font(geist(17))
            .foregroundStyle(Color.ink)
            .background(Color.bg.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .sheet(isPresented: $signing) {
                SignatureSheet { signature in
                    model.signOff(id, signature)
                    dismiss()
                }
                .presentationSizing(.form).presentationDragIndicator(.visible)
            }
        } else {
            // The call was signed or removed while this was open, so there is nothing left to review.
            Color.bg.ignoresSafeArea().onAppear { dismiss() }
        }
    }

    private func part(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(doto(fit(26, 22)))
            content()
        }
    }

    /// The layout of the PCR narrative, chosen here before signing. Picking one rewrites the narrative in it from
    /// the transcript; one already written for this call comes back at once. The line underneath says what the
    /// format is, that it is being written, or why it could not be.
    private func formatChoice(_ call: Call) -> some View {
        let busy = model.rewriting[call.id]
        let shown = busy ?? call.narrativeFormat
        let trouble = model.narrativeTrouble[call.id]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Narrative format").font(geist(15, 600)).foregroundStyle(Color.dim)
            HStack(spacing: 4) {
                ForEach(NarrativeFormat.allCases) { format in
                    let on = format == shown
                    Button { model.setNarrativeFormat(format, for: call.id) } label: {
                        Text(format.name).font(geist(fit(16, 15), 600)).lineLimit(1)
                            .foregroundStyle(on ? Color.bg : .dim)
                            .padding(.horizontal, fit(24, 6))
                            .frame(maxWidth: phone ? .infinity : nil)
                            .frame(height: 44)
                            .background(on ? Color.ink : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .accessibilityLabel("\(format.name) narrative: \(format.detail)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .buttonStyle(.plain)
            .padding(4)
            .background(Color.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.line))
            .disabled(busy != nil)
            Text(busy.map { "Writing the narrative as \($0.name) on this \(deviceName). The rest of the report is unchanged." } ?? trouble ?? shown.detail)
                .font(geist(15, 500)).foregroundStyle(busy == nil && trouble == nil ? Color.dim : .yellow)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A handoff line. While it is empty it is drawn in yellow: the AI could not fill it, so it needs the medic.
    private func field(_ label: String, _ text: Binding<String>, mark: String? = nil, prompt: String = "Add it, or leave blank and ask") -> some View {
        let missing = text.wrappedValue.isEmpty
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text(missing && mark == nil ? "\(label): not heard" : label).font(geist(15, 600)).foregroundStyle(missing ? Color.yellow : .dim)
                if let mark {
                    HStack(spacing: 6) {
                        Flag(size: 14)
                        Text(mark).font(doto(15)).foregroundStyle(Color.yellow)
                    }
                }
            }
            TextField(label, text: text, prompt: Text(prompt).foregroundColor(.dim))
                .font(geist(fit(23, 19), 500)).tint(.yellow).frame(height: 49)
            if missing { DottedRule(color: .yellow) } else { Color.ghost.frame(height: 1) }
        }
    }
}

// MARK: Pieces shared by the live screens and a past call

/// The rows of one recording: what was said and the marks, each with its clock time.
struct TranscriptRows: View {
    var recording: Recording
    var color: Color = .dim
    var liveLine: UUID? = nil   // the line still being spoken, if any

    var body: some View {
        ForEach(recording.items) { item in
            if let mark = item.mark {
                HStack(spacing: fit(16, 10)) {
                    stamp(item.time)
                    HStack(spacing: 8) {
                        Flag()
                        Text("Mark \(mark)").font(doto(18)).foregroundStyle(Color.yellow)
                    }
                    DottedRule(color: .yellow.opacity(0.45))
                }
                .accessibilityElement(children: .combine)
            } else if item.id == liveLine {
                // The line being spoken: bright, with its newest word in red and a blinking dot.
                let words = item.text.split(separator: " ")
                Ticker(fps: 4) { t in
                    said(item.time, Text(words.dropLast().joined(separator: " ") + (words.count > 1 ? " " : ""))
                        + Text(words.last.map(String.init) ?? "").foregroundColor(.red)
                        + Text(" ●").font(geist(14)).foregroundColor(.red.opacity(blink(t))), size: fit(26, 21))
                }
            } else if !item.text.isEmpty {
                said(item.time, Text(item.text).foregroundColor(color))
            }
        }
    }

    private func stamp(_ time: Date) -> some View {
        Text(clock(time)).font(geist(fit(17, 15), 500).monospacedDigit()).foregroundStyle(Color.dim).frame(width: fit(64, 50), alignment: .leading)
    }

    private func said(_ time: Date, _ text: Text, size: CGFloat = fit(22, 18)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: fit(16, 10)) {
            stamp(time)
            text.font(geist(size, 500)).lineSpacing(size * 0.35).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Recording 2, 3 min, 3 marks", with a rule running to the edge.
struct RecordingHeading: View {
    var number: Int
    var recording: Recording

    var body: some View {
        HStack(spacing: 14) {
            Text("Recording \(number), \(span(recording.seconds))" + (recording.marks > 0 ? ", \(plural(recording.marks, "mark"))" : ""))
                .font(geist(15, 600))
            Color.line.frame(height: 1)
        }
    }
}

/// The four parts of the PCR: two columns on iPad, one on iPhone.
struct PCRView: View {
    var call: Call

    var body: some View {
        let parts = call.pcr
        if phone {
            VStack(alignment: .leading, spacing: 28) { ForEach(0..<4, id: \.self) { part(parts[$0]) } }
        } else {
            Grid(alignment: .topLeading, horizontalSpacing: 48, verticalSpacing: 36) {
                ForEach([0, 2], id: \.self) { row in
                    GridRow { ForEach(row..<row + 2, id: \.self) { part(parts[$0]) } }
                }
            }
        }
    }

    private func part(_ part: (title: String, body: String)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(part.title).font(geist(15, 600)).foregroundStyle(Color.dim)
            if part.body.isEmpty {
                Text("Not heard").font(geist(fit(22, 19))).foregroundStyle(Color.yellow)
            } else {
                timed(part.body).font(geist(fit(22, 19))).lineSpacing(9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Dims the leading clock time ("14:05 ...") on each line, so the reading stands out. In a narrative laid out
    /// in a format, section headings are set apart and a section that was not heard is yellow, like any empty line.
    private func timed(_ body: String) -> Text {
        body.split(separator: "\n", omittingEmptySubsequences: false).enumerated().reduce(Text("")) { text, line in
            let isTimed = line.element.count > 6 && line.element.prefix(5).contains(":")
            let newline = Text(line.offset == 0 ? "" : "\n")
            if NarrativeFormat.isHeading(line.element) {
                return text + newline + Text(line.element).font(geist(15, 600)).foregroundColor(.dim)
            }
            if line.element == NarrativeFormat.notHeard { return text + newline + Text(line.element).foregroundColor(.yellow) }
            return isTimed
                ? text + newline + Text(line.element.prefix(6)).foregroundColor(.dim) + Text(line.element.dropFirst(6))
                : text + newline + Text(line.element)
        }
    }
}

// MARK: A past call

/// A signed call, opened from Home, read only: transcript, PCR, nurse handoff, then the signature.
struct PastCallView: View {
    var call: Call
    var edit: (() -> Void)? = nil   // when given, an Edit button sends the call back to be corrected and signed again
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(day(call.start)).font(doto(fit(40, 28))).lineLimit(1).minimumScaleFactor(0.6)
                    Text("\(plural(call.recordings.count, "recording")), \(span(call.seconds))")
                        .font(geist(15, 500)).foregroundStyle(Color.dim)
                }
                Spacer()
                if let edit {
                    Button("Edit") {
                        edit()
                        dismiss()
                    }
                    .buttonStyle(Pill(fill: nil, height: 44, size: 16))
                }
                Button("Done") { dismiss() }.buttonStyle(Pill(fill: nil, height: 44, size: 16))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    part("Transcript") {
                        if call.transcript.isEmpty { Text("Nothing was heard on this call.").font(geist(fit(22, 19))).foregroundStyle(Color.dim) }
                        ForEach(Array(call.recordings.enumerated()), id: \.offset) { n, recording in
                            RecordingHeading(number: n + 1, recording: recording)
                            TranscriptRows(recording: recording, color: .ink)
                        }
                    }
                    part("PCR") { PCRView(call: call) }
                    part("Nurse handoff") {
                        line("Patient", call.draft.patient)
                        line("Latest vitals", call.draft.latestVitals)
                        line("Given", call.draft.given)
                        line("Allergies", call.draft.allergies)
                        ForEach(call.silentMarks) { mark in
                            line("\(clock(mark.time)), Mark \(mark.mark ?? 0)", call.markNotes[mark.mark ?? 0] ?? "")
                        }
                    }
                    part("Signature") {
                        if call.signature != nil {
                            SignatureView(signature: call.signature).frame(width: 240, height: 64, alignment: .leading)
                        }
                        Text(call.signature == nil ? "Signed \(clock(call.signedAt ?? call.start)), before signatures were required" : "Signed \(clock(call.signedAt ?? call.start))")
                            .font(geist(15, 500).monospacedDigit()).foregroundStyle(Color.green)
                    }
                }
            }
            .scrollIndicators(.hidden)
            Button(copied ? "Copied" : "Copy PCR") {
                UIPasteboard.general.string = call.pcrText
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.8))
                    copied = false
                }
            }
            .buttonStyle(Pill(grow: true))
        }
        .padding(.horizontal, fit(40, 20)).padding(.top, fit(36, 28)).padding(.bottom, fit(32, 12))
        .font(geist(17))
        .foregroundStyle(Color.ink)
        .background(Color.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func part(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(doto(fit(26, 22)))
            content()
        }
    }

    /// A handoff line as it was signed. One the medic left empty says so.
    private func line(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(geist(15, 600)).foregroundStyle(Color.dim)
            Text(value.isEmpty ? "Left blank" : value).font(geist(fit(22, 19))).foregroundStyle(value.isEmpty ? Color.dim : .ink)
        }
    }
}
