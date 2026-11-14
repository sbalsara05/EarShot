import SwiftUI

enum Tab: String, CaseIterable { case home = "Home", live = "Live Call", drafts = "AI Drafts", clip = "Clip" }
enum Live { case none, ready, listening, between, cutShort }
enum Drafts { case none, analyzing, ready, signed }

/// One row of the transcript: something said, or a mark the medic dropped.
struct Item: Identifiable, Codable {
    var id = UUID()
    var time = Date()
    var text = ""
    var mark: Int? = nil   // set on a mark row, which has no text
}

struct Recording: Codable {
    var start = Date()
    var end: Date? = nil
    var items: [Item] = []
    var seconds: Int { Int((end ?? Date()).timeIntervalSince(start)) }
    var marks: Int { items.filter { $0.mark != nil }.count }
}

/// One call, from New call to sign-off: its recordings and its paperwork.
struct Call: Identifiable, Codable {
    var id = UUID()
    var start = Date()
    var recordings: [Recording] = []
    var draft = Draft.blank
    var drafted = false               // Analyze has run, so the paperwork exists
    var draftNote: String?            // why nothing was drafted, when that happens
    var markNotes: [Int: String] = [:]
    var signedAt: Date?
    var signature: Signature?

    var markCount: Int { recordings.reduce(0) { $0 + $1.marks } }
    var seconds: Int { recordings.reduce(0) { $0 + $1.seconds } }

    /// What the drafting model reads: one line per thing said or marked, each with its clock time.
    var transcript: String {
        recordings.flatMap(\.items).filter { $0.mark != nil || !$0.text.isEmpty }
            .map { "[\(clock($0.time))] " + ($0.mark.map { "MARK \($0)" } ?? $0.text) }
            .joined(separator: "\n")
    }

    /// The PCR as titled parts, in the order they are shown.
    var pcr: [(title: String, body: String)] {
        [
            ("Dispatch and scene", draft.dispatchAndScene), ("Vitals by time", draft.vitalsByTime.joined(separator: "\n")),
            ("Narrative", draft.narrative), ("Treatment by time", draft.treatmentByTime.joined(separator: "\n")),
        ]
    }

    var pcrText: String { pcr.map { "\($0.title)\n\($0.body.isEmpty ? "Not heard" : $0.body)" }.joined(separator: "\n\n") }

    /// Marks with nothing said within 20 seconds either side. The handoff asks the medic what happened there.
    var silentMarks: [Item] {
        recordings.flatMap { recording in
            recording.items.filter { mark in
                mark.mark != nil && !recording.items.contains { $0.mark == nil && !$0.text.isEmpty && abs($0.time.timeIntervalSince(mark.time)) < 20 }
            }
        }
    }
}

@Observable final class Model {
    var tab = Tab.home
    var clip = false                       // a clip is connected and ready; recordings then use its audio, not the microphone
    var clipName: String?                  // the last clip that said hello, like "Earshot-A3F2"
    var clipState = ClipLink.State.idle
    var live = Live.none
    var drafts = Drafts.none

    var call = Call()                              // the call being worked on
    var past: [Call] = []                          // signed calls, newest first
    var liveLine: UUID?                            // the line still being spoken
    var levels = [Int](repeating: 0, count: 30)    // recent loudness, oldest first
    var problem: String?

    @ObservationIgnored private let transcriber = Transcriber()
    @ObservationIgnored private let link = ClipLink()
    @ObservationIgnored private var source = Transcriber.Source.mic   // where the current recording's audio comes from

    init() {
        link.onState = { [weak self] state in self?.clipChanged(to: state) }
        link.onEvent = { [weak self] event in self?.clipSaid(event) }
        link.onAudio = { [weak self] buffer in self?.transcriber.push(buffer) }
        transcriber.onLevel = { [weak self] level in
            self?.levels.removeFirst()
            self?.levels.append(level)
        }
        transcriber.onText = { [weak self] id, text in self?.heard(id, text) }
        transcriber.onCut = { [weak self] in
            self?.liveLine = nil
            self?.save()   // each finished line is on disk before the next one starts
        }
        transcriber.onProblem = { [weak self] message in
            self?.problem = "Transcription stopped. \(message)"
            self?.stop()
        }
        load()
        link.resume()
    }

    private func heard(_ id: UUID, _ text: String) {
        if id == transcriber.segment { liveLine = id }
        for r in call.recordings.indices {
            if let i = call.recordings[r].items.firstIndex(where: { $0.id == id }) {
                call.recordings[r].items[i].text = text
                return
            }
        }
        if !call.recordings.isEmpty { call.recordings[call.recordings.count - 1].items.append(Item(id: id, text: text)) }
    }

    // MARK: The call

    func newCall() {
        call = Call()
        problem = nil
        live = .ready
        drafts = .none
        tab = .live
        save()
    }

    func record() {
        Task { @MainActor in
            problem = await Transcriber.authorize(microphone: !clip)
            guard problem == nil, live != .listening else { return }
            if clip {
                link.send("start")   // the recording begins when the clip confirms, in clipSaid
            } else {
                begin(from: .mic)
            }
        }
    }

    private func begin(from source: Transcriber.Source) {
        guard live != .listening, live != .none else { return }
        do {
            try transcriber.start(from: source)
            self.source = source
            call.recordings.append(Recording())
            live = .listening
            UIApplication.shared.isIdleTimerDisabled = true   // a locked screen would end the recording
        } catch {
            problem = error.localizedDescription
            if source == .clip { link.send("stop") }
        }
    }

    func stop(as next: Live = .between) {
        guard live == .listening else { return }
        if source == .clip { link.send("stop") }
        finish(as: next)
    }

    private func finish(as next: Live) {
        guard live == .listening else { return }
        transcriber.stop()
        call.recordings[call.recordings.count - 1].end = Date()
        live = next
        UIApplication.shared.isIdleTimerDisabled = false
        save()
    }

    func mark() {
        guard live == .listening else { return }
        if source == .clip { link.send("marker") }   // so the clip logs it too; its echo is ignored in clipSaid
        addMark()
    }

    private func addMark() {
        transcriber.cut()
        call.recordings[call.recordings.count - 1].items.append(Item(mark: call.markCount + 1))
    }

    // MARK: The clip

    /// What the clip is called on screen: its own name once it has said hello.
    var clipTitle: String { clipName ?? "Earshot clip" }

    /// One short line on where the link stands.
    var clipStatus: String {
        switch clipState {
        case .ready: "Connected"
        case .connecting: "Connecting"
        case .searching: "Searching"
        case .idle: "Not connected"
        case .off: "Bluetooth unavailable"
        }
    }

    func connect() {
        link.connect()
    }

    /// Lets go of the clip and stops looking for it. A recording in progress ends there.
    func disconnect() {
        stop(as: .cutShort)
        link.forget()
    }

    private func clipChanged(to state: ClipLink.State) {
        clipState = state
        if case .ready(let name) = state {
            clip = true
            clipName = name
            if live == .cutShort { live = .between }
        } else {
            clip = false
            if live == .listening && source == .clip { finish(as: .cutShort) }   // the link dropped mid-recording
        }
    }

    private func clipSaid(_ event: ClipEvent) {
        switch (event.type, event.event) {
        case ("hello", _):
            if let codec = event.audio?.codec, codec != "opus" {
                problem = "This clip sends \(codec) audio, which Earshot cannot read yet."
            }
        case ("consent", "granted"):
            clipStarted()
        case ("state", _) where event.listening == true:
            clipStarted()   // said after every connect: the clip was already listening, so pick it up
        case ("consent", "stopped"):
            if source == .clip { finish(as: .between) }
        case ("marker", _) where event.source == "button":
            if live == .listening && source == .clip { addMark() }
        default:
            break   // a marker the app asked for is already in the transcript
        }
    }

    /// The clip began capturing, from its button or because the app asked.
    private func clipStarted() {
        guard live != .listening else { return }
        guard live != .none else {
            link.send("stop")   // no call is open, so nothing is recorded and the clip's light goes dark again
            return
        }
        Task { @MainActor in
            problem = await Transcriber.authorize(microphone: false)
            if problem == nil { begin(from: .clip) } else { link.send("stop") }
        }
    }

    // MARK: The paperwork

    func analyze() {
        stop()
        drafts = .analyzing
        tab = .drafts
        call.draftNote = nil
        call.markNotes = [:]
        let said = call.recordings.flatMap(\.items).contains { $0.mark == nil && !$0.text.isEmpty }
        let transcript = said ? call.transcript : ""
        Task { @MainActor in
            do {
                call.draft = try await writeDraft(from: transcript)
            } catch {
                call.draft = .blank
                call.draftNote = "Nothing was drafted. \(error.localizedDescription) Fill in the lines yourself."
            }
            guard drafts == .analyzing else { return }
            call.drafted = true
            drafts = .ready
            save()
        }
    }

    /// Signing off ends the call: it moves to the past calls and a new one can start.
    func signOff(_ signature: Signature) {
        call.signature = signature
        call.signedAt = Date()
        past.insert(call, at: 0)
        problem = nil   // any recording trouble belonged to the call that just ended
        live = .none
        drafts = .signed
        save()
    }

    /// Edit, after signing: the call comes back out of the past calls until it is signed again.
    func reopen() {
        past.removeAll { $0.id == call.id }
        call.signedAt = nil
        call.signature = nil   // an edited call has to be signed again
        live = call.recordings.isEmpty ? .ready : .between
        drafts = .ready
        save()
    }

    /// Throws away a call that has not been signed, with its recordings and drafts.
    func discard() {
        stop()
        call = Call()
        problem = nil
        live = .none
        drafts = .none
        save()
    }

    func closeCall() {
        call = Call()
        live = .none
        drafts = .none
        tab = .home
    }

    func delete(at offsets: IndexSet) {
        let showing = offsets.contains { past[$0].id == call.id }
        past.remove(atOffsets: offsets)
        if showing && drafts == .signed {   // the deleted call was still open on the drafts tab
            call = Call()
            drafts = .none
        }
        save()
    }

    // MARK: On disk

    private struct Saved: Codable {
        var open: Call?     // a call that is not signed yet
        var past: [Call]
    }

    private static let file = URL.applicationSupportDirectory.appending(path: "calls.json")

    /// Writes the open call and the past calls. Called whenever either changes, and when the app leaves the screen.
    /// ponytail: one file rewritten whole. Move to a file per call, or SwiftData, when the history grows past a few hundred calls.
    func save() {
        let unsigned = live != .none || drafts == .ready || drafts == .analyzing
        do {
            try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Calls hold patient information: encrypted while the device is locked, and kept out of iCloud backups.
            try JSONEncoder().encode(Saved(open: unsigned ? call : nil, past: past)).write(to: Self.file, options: [.atomic, .completeFileProtection])
            var file = Self.file, values = URLResourceValues()
            values.isExcludedFromBackup = true
            try file.setResourceValues(values)
        } catch {
            problem = "This call could not be saved. \(error.localizedDescription)"
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.file) else { return }   // nothing saved yet
        do {
            let saved = try JSONDecoder().decode(Saved.self, from: data)
            past = saved.past
            guard var open = saved.open else { return }
            // A recording that was still running when the app closed ends at its last line.
            for i in open.recordings.indices where open.recordings[i].end == nil {
                open.recordings[i].end = open.recordings[i].items.last?.time ?? open.recordings[i].start
            }
            call = open
            live = open.recordings.isEmpty ? .ready : .between
            drafts = open.drafted ? .ready : .none
        } catch {
            // Never overwrite a file that could not be read: set it aside so its calls can be recovered.
            let aside = Self.file.deletingLastPathComponent().appending(path: "calls-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: Self.file, to: aside)
            problem = "Saved calls could not be read. They were set aside, not deleted."
        }
    }

    #if DEBUG
    /// Runs at launch in debug builds. Fails loudly if the transcript or saving rules break.
    static func selfCheck() {
        let t = Date()
        var call = Call()
        call.markNotes = [2: "Moved to stretcher"]
        call.signature = .typed("A. Medic")
        call.recordings = [Recording(items: [
            Item(time: t, text: "BP 120 over 80"), Item(time: t.addingTimeInterval(5), mark: 1), Item(time: t.addingTimeInterval(90), mark: 2),
        ])]
        assert(call.silentMarks.map(\.mark) == [2])
        assert(call.markCount == 2 && call.transcript.contains("] BP 120 over 80\n[") && call.transcript.hasSuffix("MARK 2"))
        assert(span(59) == "59 sec" && span(125) == "2 min" && plural(1, "mark") == "1 mark" && plural(2, "mark") == "2 marks")
        // A call must survive being written to disk and read back.
        let copy = try? JSONDecoder().decode(Call.self, from: JSONEncoder().encode(call))
        assert(copy?.id == call.id && copy?.transcript == call.transcript && copy?.markNotes[2] == "Moved to stretcher")
        if case .typed("A. Medic")? = copy?.signature {} else { assertionFailure("the signature was lost on disk") }
        // The clip's messages must be readable exactly as firmware/BLUETOOTH.md gives them.
        let hello = try? JSONDecoder().decode(ClipEvent.self, from: Data(#"{"type":"hello","device":"Earshot-A3F2","fw":"0.6.0","audio":{"codec":"opus","rate":16000,"channels":1,"frame_ms":20,"bitrate":32000}}"#.utf8))
        assert(hello?.device == "Earshot-A3F2" && hello?.audio?.codec == "opus")
        let marker = try? JSONDecoder().decode(ClipEvent.self, from: Data(#"{"type":"marker","id":1,"source":"button","t_ms":47781,"audio_seq":327}"#.utf8))
        assert(marker?.type == "marker" && marker?.source == "button")
        assert(ClipLink.frameNumber(of: Data([0x47, 0x01, 0, 0, 9, 9, 9, 9])) == 327)   // 0x0147, least significant byte first
    }
    #endif
}

@main
struct EarshotApp: App {
    @State private var model = Model()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        Model.selfCheck()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            // The reader pins the layout to the screen. Without it, a screen taller than the
            // safe area stops ignoring the safe area and slides up under the top edge.
            GeometryReader { screen in
              VStack(spacing: 0) {
                Header()
                Group {
                    switch model.tab {
                    case .home: HomeScreen()
                    case .live: LiveScreen()
                    case .drafts: DraftsScreen()
                    case .clip: ClipScreen()
                    }
                }
                .padding(.top, 8).padding(.horizontal, fit(32, 20)).padding(.bottom, fit(32, 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if phone { Tabs().padding(.horizontal, 20).padding(.bottom, 4) }
              }
              .frame(width: screen.size.width, height: screen.size.height)
            }
            .font(geist(17))
            .foregroundStyle(Color.ink)
            .background(Color.bg.ignoresSafeArea())
            // The iPad design runs edge to edge. The phone keeps clear of the island and the home bar.
            .ignoresSafeArea(edges: phone ? [] : .all)
            .statusBarHidden(!phone)
            .persistentSystemOverlays(phone ? .automatic : .hidden)
            .preferredColorScheme(.dark)
            .environment(model)
            .onChange(of: scenePhase) { _, phase in
                // The microphone stops when the app leaves the screen, so the recording ends there too.
                if phase == .background { model.stop() }
                if phase != .active { model.save() }
            }
        }
    }
}

struct Header: View {
    @Environment(Model.self) private var model

    var body: some View {
        HStack {
            Button { model.tab = .home } label: {
                HStack(spacing: 12) {
                    Dots(logoArt, pitch: 3.4, r: 1.22, palette: ["w": .ink, "r": .red])
                    Text("earshot").font(doto(26))
                }
                .frame(width: fit(260, 160), height: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Earshot home")
            Spacer()
            if !phone {
                Tabs()
                Spacer()
            }
            status.font(geist(15, 500)).foregroundStyle(Color.dim).frame(width: fit(260, 170), alignment: .trailing)
        }
        .padding(.horizontal, fit(32, 20))
        .frame(height: fit(84, 52))
    }

    @ViewBuilder private var status: some View {
        if model.tab != .live || model.live == .none {
            Color.clear.frame(height: 1)
        } else if model.live == .listening {
            HStack(spacing: 10) {
                BlinkDot(size: 10)
                Text("Recording").font(geist(15, 600)).foregroundStyle(Color.red)
            }
        } else {
            Text("Call started \(clock(model.call.start))")
        }
    }
}

/// The four tabs. In the header on iPad, along the bottom on iPhone.
struct Tabs: View {
    @Environment(Model.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { tab in
                let on = model.tab == tab
                Button { model.tab = tab } label: {
                    HStack(spacing: fit(8, 6)) {
                        if tab == .clip { clipDot(selected: on) }
                        Text(tab.rawValue).lineLimit(1)
                    }
                    .font(geist(15, 600))
                    .foregroundStyle(on ? Color.bg : .dim)
                    .padding(.horizontal, fit(22, 6))
                    .frame(maxWidth: phone ? .infinity : nil)
                    .frame(height: 44)
                    .background(on ? Color.ink : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .buttonStyle(.plain)
        .padding(4)
        .background(Color.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.line))
    }

    @ViewBuilder private func clipDot(selected: Bool) -> some View {
        if model.clip {
            Circle().fill(selected ? Color(0x1F8A52) : .green).frame(width: 8, height: 8)
        } else if model.live == .cutShort && !selected {
            BlinkDot(size: 8)
        } else {
            Circle().strokeBorder(selected ? Color.bg : .dim, lineWidth: 1.5).frame(width: 9, height: 9)
        }
    }
}

// MARK: Home

struct HomeScreen: View {
    @Environment(Model.self) var model
    @State var opened: Call?   // the past call being read
    @State private var discarding = false

    var body: some View {
        Split {
            VStack(alignment: .leading, spacing: fit(28, 20)) {
                if model.live == .none {
                    Text("Ready").font(doto(headline))
                    Text(model.clip ? "Your clip is connected. Start a call when you’re on scene." : "No clip connected, so calls record on the \(deviceName) mic.")
                        .font(geist(22)).lineSpacing(6).foregroundStyle(Color.dim).frame(maxWidth: 440, alignment: .leading)
                    Button { model.newCall() } label: {
                        Circle().fill(Color.red).frame(width: 14, height: 14)
                        Text("New call")
                    }
                    .buttonStyle(Pill(height: fit(76, 68), size: 22, minWidth: fit(260, nil), grow: phone))
                } else {
                    HStack(spacing: 10) {
                        BlinkDot(size: 12)
                        Text("Call in progress since").font(geist(20, 600)).foregroundStyle(Color.red)
                    }
                    Text(clock(model.call.start)).font(doto(headline))
                    Text(model.call.recordings.isEmpty ? "No recordings yet" : "\(plural(model.call.recordings.count, "recording")), \(plural(model.call.markCount, "mark"))").font(geist(22)).foregroundStyle(Color.dim)
                    let actions = phone ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
                    actions {
                        Button("Resume call") { model.tab = .live }.buttonStyle(Pill(height: fit(76, 68), size: 22, minWidth: fit(260, nil), grow: phone))
                        Button("Discard call") { discarding = true }.buttonStyle(Pill(fill: nil, height: fit(76, 56), size: fit(22, 17), grow: phone))
                            .confirmationDialog("Discard this call?", isPresented: $discarding, titleVisibility: .visible) {
                                Button("Discard call", role: .destructive) { model.discard() }
                                Button("Keep call", role: .cancel) {}
                            } message: {
                                Text("Its recordings and drafts will be deleted. This cannot be undone.")
                            }
                    }
                }
                if let problem = model.problem { Text(problem).font(geist(17, 500)).foregroundStyle(Color.red) }
                if !model.past.isEmpty { pastCalls }
            }
            .padding(.leading, fit(24, 4)).padding(.top, model.past.isEmpty ? 0 : fit(12, 0))
            // With no past calls the headline sits centred, as designed. With some, it moves up and the list fills the rest.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.past.isEmpty ? .leading : .topLeading)

            Button {
                if model.clipState == .idle { model.connect() }
                model.tab = .clip
            } label: {
                // A tall card beside the headline on iPad, a short row under it on iPhone.
                let card = phone ? AnyLayout(HStackLayout(spacing: 20)) : AnyLayout(VStackLayout(spacing: 28))
                card {
                    ClipModel(ghost: !model.clip, scale: fit(0.95, 0.42), sway: true).frame(width: fit(215, 96), height: fit(290, 124))
                    VStack(alignment: phone ? .leading : .center, spacing: fit(28, 12)) {
                        VStack(alignment: phone ? .leading : .center, spacing: fit(10, 6)) {
                            Text(model.clipTitle).font(doto(fit(30, 24)))
                            if model.clip {
                                HStack(spacing: 8) {
                                    Circle().frame(width: 9, height: 9)
                                    Text("Connected")
                                }
                                .font(geist(17, 500)).foregroundStyle(Color.green)
                            } else {
                                Text(model.clipStatus).font(geist(17, 500)).foregroundStyle(Color.dim)
                            }
                        }
                        if model.clipState == .idle {
                            Text("Connect").font(geist(fit(19, 16), 600)).padding(.horizontal, fit(32, 22)).frame(height: fit(52, 40))
                                .overlay(Capsule().strokeBorder(Color.outline, lineWidth: 1.5))
                        }
                    }
                    if phone { Spacer(minLength: 0) }
                }
                .padding(fit(0, 20))
                .side()
                .frame(maxHeight: phone ? nil : .infinity)
                .panel()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clip \(model.clipTitle), \(model.clipStatus)")
        }
        .sheet(item: $opened) { PastCallView(call: $0).presentationSizing(.page).presentationDragIndicator(.visible) }
    }
}

extension HomeScreen {
    /// The big word shrinks on iPhone once there are past calls to make room for.
    var headline: CGFloat { fit(176, model.past.isEmpty ? 104 : 72) }

    /// Signed calls, newest first. Tap a row to read it, swipe it left to delete it.
    var pastCalls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Past calls").font(geist(15, 600)).foregroundStyle(Color.dim)
            List {
                ForEach(model.past) { call in
                    Button { opened = call } label: {
                      HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(call.draft.patient.isEmpty ? "Patient not recorded" : call.draft.patient)
                                .font(geist(19, 500)).foregroundStyle(Color.ink).lineLimit(1)
                            Text("\(day(call.start)), \(plural(call.recordings.count, "recording")), \(span(call.seconds))")
                                .font(geist(15)).foregroundStyle(Color.dim).lineLimit(1)
                        }
                        Spacer()
                        Text("Signed \(clock(call.signedAt ?? call.start))").font(geist(15, 500).monospacedDigit()).foregroundStyle(Color.green)
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
                .onDelete { model.delete(at: $0) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: Clip

struct ClipScreen: View {
    @Environment(Model.self) private var model
    @State private var finding = false
    @State private var turn: (rx: Double, ry: Double)? = nil

    var body: some View {
        // Both panels do not fit one phone screen, so there the tab scrolls.
        if phone {
            ScrollView { VStack(spacing: 16) { panels } }.scrollIndicators(.hidden)
        } else {
            HStack(spacing: 32) { panels }
        }
    }

    @ViewBuilder private var panels: some View {
        if model.clip {
            viewer
            details
        } else {
            searching
            nearby
        }
    }

    private var viewer: some View {
        GeometryReader { box in
            VStack(spacing: 8) {
                ClipModel(scale: fit(1, 0.8), rx: turn?.rx ?? -10, ry: turn?.ry ?? -32, sway: turn == nil && !finding, wiggle: finding, ledBlinks: finding)
                    .frame(height: fit(380, 250))
                // ponytail: dragging turns the clip. Add CoreMotion to make the copy literally true on a real device.
                Text("Tilt the \(deviceName) to look around the clip").font(geist(17, 500)).foregroundStyle(Color.dim)
            }
            .background {
                if finding {
                    Ticker { t in
                        ZStack {
                            ForEach(0..<3, id: \.self) { i in
                                let p = ((t + Double(i) * 0.53) / 1.6).truncatingRemainder(dividingBy: 1)
                                Circle().stroke(Color.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [0.01, 6]))
                                    .frame(width: 560, height: 560).scaleEffect(0.45 + 0.55 * p).opacity(0.9 * (1 - p))
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                turn = (rx: -(g.location.y / box.size.height - 0.5) * 44, ry: (g.location.x / box.size.width - 0.5) * 130)
            })
        }
        .frame(height: phone ? 330 : nil)
        .clipped()
        .panel()
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.clipTitle).font(doto(fit(46, 34)))
            HStack(spacing: 10) {
                Circle().frame(width: 10, height: 10)
                Text("Connected")
            }
            .font(geist(19, 500)).foregroundStyle(Color.green).padding(.top, 6).padding(.bottom, 18)
            // ponytail: the clip reports no battery or signal yet. Add those rows when the firmware sends them.
            row("Link") { Text("Bluetooth") }
            row("Records from") { Text("Clip") }
            Text("Press the clip to start a recording once a call is open. Hold it to stop. Double tap to mark.")
                .font(geist(17)).lineSpacing(4).foregroundStyle(Color.dim).padding(.top, 18)
            Spacer(minLength: 16)
            Button("Disconnect") { model.disconnect() }.buttonStyle(Pill(fill: nil, grow: true))
        }
        .padding(.top, fit(36, 24)).padding(.horizontal, fit(32, 20)).padding(.bottom, fit(32, 20))
        .side()
        .panel()
    }

    /// What to tell the medic while no clip is connected.
    private var waiting: String {
        switch model.clipState {
        case .off(let why): why
        case .searching: "Power the clip on and keep it close. Until it connects, calls record on the \(deviceName) mic."
        case .connecting: "Waiting for \(model.clipTitle) to answer. It reconnects by itself when it is on and in range."
        case .idle, .ready: "Calls record on the \(deviceName) mic until a clip connects."
        }
    }

    private func row(_ name: String, @ViewBuilder value: () -> some View) -> some View {
        VStack(spacing: 0) {
            Color.line.frame(height: 1)
            HStack(spacing: 14) {
                Text(name).font(geist(17, 500)).foregroundStyle(Color.dim)
                Spacer()
                value()
            }
            .font(doto(20))
            .frame(minHeight: 67)
        }
        .accessibilityElement(children: .combine)
    }

    private var searching: some View {
        VStack(spacing: 28) {
            ClipModel(ghost: true, scale: fit(1.2, 0.9), sway: true)
                .frame(width: 240, height: fit(356, 272))
                .overlay(alignment: .top) {
                    Ticker { t in
                        let step = Int(t.truncatingRemainder(dividingBy: 2.8) / 2.8 * fit(21, 16))
                        Dots(cols: 15, rows: 1, pitch: 16, r: 5.6) { _, _ in .ink }.offset(y: CGFloat(step) * 16)
                    }
                }
                .clipped()
            Text(model.clipState == .searching ? "Looking for clips nearby" : model.clipStatus).font(geist(18, 500)).foregroundStyle(Color.dim)
        }
        .padding(.vertical, fit(0, 24))
        .frame(maxWidth: .infinity, maxHeight: phone ? nil : .infinity)
        .panel()
    }

    private var nearby: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No clip connected").font(doto(fit(46, 34)))
            Text(waiting)
                .font(geist(19)).lineSpacing(5).foregroundStyle(Color.dim).padding(.top, 10).padding(.bottom, 22)
            Spacer(minLength: 16)
            switch model.clipState {
            case .idle: Button("Find my clip") { model.connect() }.buttonStyle(Pill(grow: true))
            case .searching: Button("Stop looking") { model.disconnect() }.buttonStyle(Pill(fill: nil, grow: true))
            case .connecting: Button("Forget this clip") { model.disconnect() }.buttonStyle(Pill(fill: nil, grow: true))
            case .ready, .off: EmptyView()
            }
        }
        .padding(.top, fit(36, 24)).padding(.horizontal, fit(32, 20)).padding(.bottom, fit(32, 20))
        .side()
        .panel()
    }
}
