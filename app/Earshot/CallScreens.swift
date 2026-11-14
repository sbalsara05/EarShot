import SwiftUI

// MARK: Live Call

struct LiveScreen: View {
    @Environment(Model.self) private var model

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
                Button("Analyze") { model.analyze() }.buttonStyle(Pill(height: 96, size: 26, grow: true))
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

struct DraftsScreen: View {
    @Environment(Model.self) private var model
    @State private var showPCR = false
    @State private var copied = false
    @State private var settled = false
    @State private var signing = false

    var body: some View {
        switch model.drafts {
        case .none: none
        case .analyzing: analyzing
        case .ready, .signed: drafts
        }
    }

    private var none: some View {
        Split {
            VStack(alignment: .leading, spacing: 28) {
                Text("No drafts yet").font(doto(fit(112, 60)))
                Text("Record a call, then tap Analyze.").font(geist(22)).foregroundStyle(Color.dim)
            }
            .padding(.leading, fit(24, 4))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            Dots(pageArt, pitch: 16, r: 5.76, palette: ["b": .outline, ".": .off])
                .side().frame(maxHeight: phone ? 280 : .infinity).panel()
                .accessibilityHidden(true)
        }
    }

    private var analyzing: some View {
        Split {
            VStack(alignment: .leading, spacing: 28) {
                Text("Writing your drafts").font(doto(fit(88, 50)))
                VStack(alignment: .leading, spacing: 18) {
                    step("Transcript", done: true)
                    step("\(plural(model.call.markCount, "mark")) placed", done: true)
                    step("Nurse handoff and PCR", done: false)
                }
            }
            .padding(.leading, fit(24, 4))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            VStack(spacing: 24) {
                Ticker(fps: 10) { t in
                    let lit = Int(t.truncatingRemainder(dividingBy: 3.2) / 3.2 * 24)
                    Dots(cols: 24, rows: 6, pitch: 12, r: 3.6) { x, _ in x < lit ? .yellow : .off }
                }
                Text("Drafting on this \(deviceName)").font(geist(17, 500)).foregroundStyle(Color.dim)
            }
            .side().frame(maxHeight: phone ? 200 : .infinity).panel()
        }
    }

    private func step(_ text: String, done: Bool) -> some View {
        HStack(spacing: 16) {
            if done {
                Check()
            } else {
                HStack(spacing: 4) { ForEach(0..<3, id: \.self) { BlinkDot(size: 6, color: .yellow, delay: Double($0) * 0.25) } }.frame(width: 26, height: 26)
            }
            Text(text).font(geist(fit(24, 20), 500)).foregroundStyle(done ? Color.dim : .ink)
        }
    }

    private var signed: Bool { model.drafts == .signed }

    private var drafts: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 20) {
                // The draft picker and its note sit on one row on iPad, and stack on iPhone.
                let top = phone ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 24))
                top {
                    Choice(first: "Nurse handoff", second: "PCR", isSecond: $showPCR)
                    if !phone { Spacer() }
                    if signed {
                        HStack(spacing: 10) {
                            Check()
                            Text("Signed \(clock(model.call.signedAt ?? Date()))").font(doto(fit(24, 20))).foregroundStyle(Color.green).fixedSize()
                            SignatureView(signature: model.call.signature).frame(width: fit(130, 100), height: 40)
                        }
                        .scaleEffect(settled ? 1 : 1.25).opacity(settled ? 1 : 0)
                        .onAppear { withAnimation(.easeOut(duration: 0.4).delay(0.25)) { settled = true } }
                        .onDisappear { settled = false }
                    } else {
                        Text(model.call.draftNote ?? "AI draft. Tap any line to edit. Yellow lines need you.")
                            .font(geist(16)).foregroundStyle(model.call.draftNote == nil ? Color.dim : .yellow)
                            .multilineTextAlignment(phone ? .leading : .trailing).lineLimit(3)
                    }
                }
                ScrollView {
                    if showPCR { PCRView(call: model.call) } else { nurseHandoff }
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .padding(.horizontal, fit(40, 20)).padding(.vertical, fit(28, 20))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .panel()

            HStack(spacing: fit(16, 8)) {
                if !phone { Spacer() }
                if signed {
                    Button("Edit") {
                        model.reopen()
                        showPCR = false
                    }
                    .buttonStyle(Pill(fill: nil, grow: phone))
                    Button(copied ? "Copied" : "Copy PCR") {
                        UIPasteboard.general.string = model.call.pcrText
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.8))
                            copied = false
                        }
                    }
                    .buttonStyle(Pill(fill: nil, minWidth: fit(170, nil), grow: phone))
                    Button("Close call") { model.closeCall() }.buttonStyle(Pill(minWidth: fit(220, nil), grow: phone))
                } else {
                    Button("Sign off") { signing = true }.buttonStyle(Pill(minWidth: fit(240, nil), grow: phone))
                }
            }
        }
        .sheet(isPresented: $signing) {
            SignatureSheet { signature in
                model.signOff(signature)
                showPCR = true
            }
            .presentationSizing(.form).presentationDragIndicator(.visible)
        }
    }

    private var nurseHandoff: some View {
        @Bindable var model = model
        return VStack(spacing: 20) {
            field("Patient", $model.call.draft.patient)
            field("Latest vitals", $model.call.draft.latestVitals)
            field("Given", $model.call.draft.given)
            field("Allergies", $model.call.draft.allergies)
            ForEach(model.call.silentMarks) { mark in
                let n = mark.mark ?? 0
                field("\(clock(mark.time)), nothing heard", Binding { model.call.markNotes[n] ?? "" } set: { model.call.markNotes[n] = $0 },
                      mark: "Mark \(n)", prompt: "What happened here?")
            }
        }
        .disabled(signed)
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

    /// Dims the leading clock time ("14:05 ...") on each line, so the reading stands out.
    private func timed(_ body: String) -> Text {
        body.split(separator: "\n").enumerated().reduce(Text("")) { text, line in
            let isTimed = line.element.count > 6 && line.element.prefix(5).contains(":")
            let newline = Text(line.offset == 0 ? "" : "\n")
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
