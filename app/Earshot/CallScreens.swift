import SwiftUI
import Fill

// MARK: Live Call

struct LiveScreen: View {
    @Environment(Model.self) private var model

    @State private var completing = false

    private var number: Int { model.call.recordings.count }
    private var current: Recording { model.call.recordings.last ?? Recording() }

    var body: some View {
        // Each state fades in over the last, so starting, pausing and ending a call do not jump.
        Group {
            switch model.live {
            case .none: idle.transition(.opacity)
            case .ready: ready.transition(.opacity)
            case .listening: Ticker(fps: 4) { _ in listening }.transition(.opacity)   // redraws the clock
            case .between: between.transition(.opacity)
            case .cutShort: cutShort.transition(.opacity)
            }
        }
        .smooth(model.live, 0.25)
    }

    /// iPad: headline, meter and controls in a left column, transcript on the right.
    /// iPhone: one column, with the controls at the bottom where a thumb reaches them.
    @ViewBuilder private func column(@ViewBuilder top: () -> some View, @ViewBuilder middle: () -> some View, @ViewBuilder bottom: () -> some View) -> some View {
        let panel = transcript
            .padding(.horizontal, fit(40, 20)).padding(.vertical, fit(36, 20))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panel()
        // With a clip connected, the key says what its button does at this point in the call.
        if phone {
            VStack(alignment: .leading, spacing: 16) {
                top()
                middle()
                panel
                if model.clip { ClipKey(live: model.live, oneLine: true) }
                bottom()
            }
        } else {
            HStack(spacing: 32) {
                VStack(alignment: .leading, spacing: 0) {
                    top()
                    Spacer()
                    middle()
                    Spacer()
                    if model.clip {
                        ClipKey(live: model.live)
                            .padding(.horizontal, 20).padding(.vertical, 14)
                            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.line))
                            .padding(.bottom, 24)
                    }
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
                        Button("Complete call", role: .destructive) { model.complete() }
                        Button("Keep recording", role: .cancel) {}
                    } message: {
                        Text("This cannot be undone. The recording ends for good. Its report waits on the Reports tab for you to check and sign, and you can start a new call straight away.")
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
                feed { TranscriptRows(recording: current, liveLine: model.liveLine, listening: true) }.smooth(current.items.count)
            }
        case .between, .cutShort:
            feed {
                ForEach(Array(model.call.recordings.enumerated()), id: \.offset) { n, recording in
                    RecordingHeading(number: n + 1, recording: recording)
                    TranscriptRows(recording: recording, color: n == number - 1 ? .ink : .dim,
                                   play: model.call.audio == nil ? nil : { model.listen(to: $0, in: model.call) }, playing: model.playing)
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

// MARK: Reports

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
        !model.review.isEmpty ? "To sign" : model.past.isEmpty ? "No reports yet" : "All signed"
    }

    private var summary: String {
        if model.review.isEmpty && model.past.isEmpty { return "Record a call, then tap Complete." }
        if model.review.isEmpty { return "\(plural(model.past.count, "signed call")). Tap one to read its report." }
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
/// when it was signed. Used on Reports and on Home.
struct CallRow: View {
    @Environment(Model.self) private var model
    var call: Call
    var waiting: Bool
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                if waiting { Circle().fill(Color.yellow).frame(width: 10, height: 10) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(Nemsis.title(of: call.report ?? [:]) ?? "Call at \(clock(call.start))")
                        .font(geist(19, 500)).foregroundStyle(Color.ink).lineLimit(1)
                    Text("\(day(call.start)), \(span(call.seconds))").font(geist(15)).foregroundStyle(Color.dim).lineLimit(1)
                }
                Spacer()
                if waiting {
                    Text(call.drafted ? "Check and sign" : model.filling[call.id] != nil ? "Filling report" : "Finishing transcript").font(geist(15, 600)).foregroundStyle(Color.yellow)
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

/// A completed call waiting for sign-off, opened from Reports. Summary is its NEMSIS record, where any answer can
/// be typed over; Transcript is what was said. From here the call is signed.
struct ReviewSheet: View {
    let id: Call.ID
    @Environment(Model.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var signing = false
    @State private var tab = ReportTab.summary

    var body: some View {
        // Looked up afresh on every draw: the list shifts when another call is completed or this one is signed.
        if let call = model.review.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(day(call.start)).font(doto(fit(40, 28))).lineLimit(1).minimumScaleFactor(0.6)
                        Text(call.drafted ? "Not signed. Check the report, correct anything, then sign." : model.filling[id] != nil ? "Filling the report from the transcript on this \(deviceName)." : "Finishing the transcript on this \(deviceName).")
                            .font(geist(15, 500)).foregroundStyle(call.drafted ? Color.dim : .yellow)
                    }
                    Spacer()
                    Button("Close") { dismiss() }.buttonStyle(Pill(fill: nil, height: 44, size: 16))
                }
                ReportTabs(tab: $tab)
                ScrollView {
                    switch tab {
                    case .summary:
                        SummaryView(call: call, status: model.filling[id], edit: { model.answer($0, $1, in: id) }, hear: { model.listen(to: $0, in: call) }, playing: model.playing)
                    case .transcript:
                        CallTranscript(call: call, deleteMark: { model.deleteMark($0, in: id) }).smooth(call.markCount)
                    }
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                Button(model.filling[id] != nil ? "Filling the report" : call.drafted ? "Sign off" : "Finishing the transcript") { signing = true }
                    .buttonStyle(Pill(grow: true))
                    .disabled(!call.drafted || model.filling[id] != nil)
            }
            .padding(.horizontal, fit(40, 20)).padding(.top, fit(36, 28)).padding(.bottom, fit(32, 12))
            .font(geist(17))
            .foregroundStyle(Color.ink)
            .background(Color.bg.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .onDisappear {
                model.hush()   // a line being played stops when the screen closes
                model.save()   // answers typed into the report
            }
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
}

/// What was said on a completed call, recording by recording. A tap on a line plays it from the call's audio.
struct CallTranscript: View {
    var call: Call
    var deleteMark: ((Item.ID) -> Void)? = nil   // when given, a mark slides left to be deleted
    @Environment(Model.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if call.transcript.isEmpty { Text("Nothing was heard on this call.").font(geist(fit(22, 19))).foregroundStyle(Color.dim) }
            if call.audio != nil {
                Text("Tap a line to hear it again.").font(geist(15, 500)).foregroundStyle(Color.dim)
            }
            if deleteMark != nil, call.markCount > 0 {
                Text("Dropped a mark by accident? Swipe it left to delete it.").font(geist(15, 500)).foregroundStyle(Color.dim)
            }
            ForEach(Array(call.recordings.enumerated()), id: \.offset) { n, recording in
                RecordingHeading(number: n + 1, recording: recording)
                TranscriptRows(recording: recording, color: .ink, deleteMark: deleteMark,
                               play: call.audio == nil ? nil : { model.listen(to: $0, in: call) }, playing: model.playing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Pieces shared by the live screens and a past call

/// The rows of one recording: what was said and the marks, each with its clock time.
struct TranscriptRows: View {
    var recording: Recording
    var color: Color = .dim
    var liveLine: UUID? = nil   // the line still being spoken, if any
    var listening = false       // a recording is running: live words are lighter until Whisper's line takes their place
    var deleteMark: ((Item.ID) -> Void)? = nil   // when given, a mark row slides left to be deleted
    var play: ((Item) -> Void)? = nil            // when given, a tap on a spoken line plays it from the call's audio
    var playing: Item.ID? = nil                  // the line being played

    var body: some View {
        ForEach(recording.items) { item in
            Group {
            if let mark = item.mark {
                let row = HStack(spacing: fit(16, 10)) {
                    stamp(item.time)
                    HStack(spacing: 8) {
                        Flag()
                        Text("Mark \(mark)").font(doto(18)).foregroundStyle(Color.yellow)
                    }
                    DottedRule(color: .yellow.opacity(0.45))
                }
                .accessibilityElement(children: .combine)
                if let deleteMark { SwipeToDelete { deleteMark(item.id) } content: { row } } else { row }
            } else if let place = item.place {
                HStack(alignment: .firstTextBaseline, spacing: fit(16, 10)) {
                    stamp(item.time)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "location.fill").font(.system(size: 13, weight: .semibold))
                        Text(place.line).font(geist(fit(17, 15), 500)).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Color.place)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Location at \(clock(item.time)): \(place.line)")
            } else if item.id == liveLine {
                // The line being spoken: bright, with its newest word in red and a blinking dot.
                let words = item.text.split(separator: " ")
                Ticker(fps: 4) { t in
                    said(item.time, Text(words.dropLast().joined(separator: " ") + (words.count > 1 ? " " : ""))
                        + Text(words.last.map(String.init) ?? "").foregroundColor(.red)
                        + Text(" ●").font(geist(14)).foregroundColor(.red.opacity(blink(t))), size: fit(26, 21))
                }
            } else if !item.text.isEmpty {
                let row = said(item.time, Text(item.text).foregroundColor(tone(of: item)), playing: item.id == playing)
                    .accessibilityHint(item.unsure ? "Read with care: this line may not be right." : "")
                if let play {
                    Button { play(item) } label: { row.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .accessibilityHint(item.id == playing ? "Playing. Tap to stop." : "Tap to hear this line.")
                } else {
                    row
                }
            }
            }
            // A new line or mark rises into place; a deleted mark slides away and fades.
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity.combined(with: .offset(x: -24))))
        }
    }

    private func stamp(_ time: Date) -> some View {
        Text(clock(time)).font(geist(fit(17, 15), 500).monospacedDigit()).foregroundStyle(Color.dim).frame(width: fit(64, 50), alignment: .leading)
    }

    /// How strongly a spoken line is drawn. A line to read with care (only the live recogniser heard it, or Whisper
    /// was not sure of it) is a step lighter than the rest. During a recording, a line Whisper is sure of stands out
    /// at full strength from the live words still waiting for it.
    private func tone(of item: Item) -> Color {
        if item.unsure { return color == .ink ? .dim : .mid }
        return listening && item.source == .whisper ? .ink : color
    }

    private func said(_ time: Date, _ text: Text, size: CGFloat = fit(22, 18), playing: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: fit(16, 10)) {
            if playing {
                // The line being played back shows a speaker where its time was.
                Image(systemName: "speaker.wave.2.fill").font(.system(size: fit(16, 14), weight: .semibold)).foregroundStyle(Color.ink)
                    .frame(width: fit(64, 50), alignment: .leading)
            } else {
                stamp(time)
            }
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

// MARK: A past call

/// A signed call, opened from Home or Reports, read only: its NEMSIS record and signature, and what was said.
struct PastCallView: View {
    var call: Call
    var edit: (() -> Void)? = nil   // when given, an Edit button sends the call back to be corrected and signed again
    @Environment(Model.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tab = ReportTab.summary
    @State private var xml: URL?   // the report as a NEMSIS file, written when the screen opens

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(day(call.start)).font(doto(fit(40, 28))).lineLimit(1).minimumScaleFactor(0.6)
                    Text("\(plural(call.recordings.count, "recording")), \(span(call.seconds))")
                        .font(geist(15, 500)).foregroundStyle(Color.dim)
                }
                Spacer()
                if let xml {
                    ShareLink(item: xml) { Text(phone ? "XML" : "Export XML") }.buttonStyle(Pill(fill: nil, height: 44, size: 16))
                        .accessibilityLabel("Export the report as NEMSIS XML")
                }
                if let edit {
                    Button("Edit") {
                        edit()
                        dismiss()
                    }
                    .buttonStyle(Pill(fill: nil, height: 44, size: 16))
                }
                Button("Done") { dismiss() }.buttonStyle(Pill(fill: nil, height: 44, size: 16))
            }
            ReportTabs(tab: $tab)
            ScrollView {
                switch tab {
                case .summary:
                    VStack(alignment: .leading, spacing: 36) {
                        SummaryView(call: call, hear: { model.listen(to: $0, in: call) }, playing: model.playing)
                        VStack(alignment: .leading, spacing: 18) {
                            Text("Signature").font(doto(fit(26, 22)))
                            if call.signature != nil {
                                SignatureView(signature: call.signature).frame(width: 240, height: 64, alignment: .leading)
                            }
                            Text(call.signature == nil ? "Signed \(clock(call.signedAt ?? call.start)), before signatures were required" : "Signed \(clock(call.signedAt ?? call.start))")
                                .font(geist(15, 500).monospacedDigit()).foregroundStyle(Color.green)
                        }
                    }
                case .transcript:
                    CallTranscript(call: call)
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, fit(40, 20)).padding(.top, fit(36, 28)).padding(.bottom, fit(32, 12))
        .font(geist(17))
        .foregroundStyle(Color.ink)
        .background(Color.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { xml = call.xml(model.standing) }
        .onDisappear {
            model.hush()   // a line being played stops when the screen closes
            if let xml { try? FileManager.default.removeItem(at: xml) }   // the exported copy is not left lying about
        }
    }
}
