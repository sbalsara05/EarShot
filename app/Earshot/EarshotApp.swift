import AVFoundation
import CoreLocation
import SwiftUI

enum Tab: String {
    case home = "Home", live = "Live Call", drafts = "AI Drafts", clip = "Clip", settings = "Settings"
    /// The four in the tab bar. Settings sits apart from them, behind its own button.
    static let main: [Tab] = [.home, .live, .drafts, .clip]
}
enum Live { case none, ready, listening, between, cutShort }

/// One row of the transcript: something said, a mark the medic dropped, or a place the device moved to.
struct Item: Identifiable, Codable {
    var id = UUID()
    var time = Date()
    var text = ""
    var mark: Int? = nil     // set on a mark row, which has no text
    var place: Place? = nil  // set on a location row, which has no text either
    /// true: a line of the record (Whisper). nil: live words, shown while the medic talks and
    /// replaced by the record once Whisper catches up.
    var record: Bool? = nil
    /// true: live words the record went past without writing anything for that stretch. They stay
    /// in the transcript, marked, and are not in the report.
    var unrecorded: Bool? = nil
}

/// One stretch of a call's audio as text. Pausing and resuming carries on in the same recording.
struct Recording: Codable {
    var start = Date()
    var end: Date? = nil            // set while paused or finished, nil while audio is being taken
    var items: [Item] = []
    var paused: TimeInterval? = nil   // time spent paused so far, left out of the length
    var seconds: Int { Int((end ?? Date()).timeIntervalSince(start) - (paused ?? 0)) }
    var marks: Int { items.filter { $0.mark != nil }.count }
}

/// One call, from New call to sign-off: its recordings and its paperwork.
struct Call: Identifiable, Codable {
    var id = UUID()
    var start = Date()
    var recordings: [Recording] = []
    var draft = Draft.blank
    var drafted = false               // the call was completed, so the paperwork exists
    var draftNote: String?            // why nothing was drafted, when that happens
    var markNotes: [Int: String] = [:]
    var signedAt: Date?
    var signature: Signature?
    var docs: [String: String]?       // chart.md, soap.md, imist_ambo.md, nemsis.xml, rendered from the record
    var reviewNotes: [String]?        // items to confirm, sentences left out of the narrative
    var format: NarrativeFormat?        // how the narrative is laid out. Nil on calls saved before formats existed: plain
    var narratives: [String: String]?   // the narrative as written in each format so far, by format, so going back to one is instant

    var narrativeFormat: NarrativeFormat { format ?? .plain }

    /// What was said, for the drafting model. Empty when nothing but marks is on the call.
    var spoken: String { recordings.flatMap(\.items).contains { $0.mark == nil && !$0.text.isEmpty } ? transcript : "" }

    var markCount: Int { recordings.reduce(0) { $0 + $1.marks } }
    var seconds: Int { recordings.reduce(0) { $0 + $1.seconds } }

    /// What the drafting model reads: one line per thing said or marked, each with its clock time.
    var transcript: String {
        recordings.flatMap(\.items).filter { $0.mark != nil || $0.place != nil || !$0.text.isEmpty }
            .map { "[\(clock($0.time))] " + ($0.mark.map { "MARK \($0)" } ?? $0.place.map { "LOCATION \($0.line) (\($0.coordinates))" } ?? $0.text) }
            .joined(separator: "\n")
    }

    /// The PCR as titled parts, in the order they are shown.
    var pcr: [(title: String, body: String)] {
        [
            ("Dispatch and scene", draft.dispatchAndScene), ("Vitals by time", draft.vitalsByTime.joined(separator: "\n")),
            (narrativeFormat == .plain ? "Narrative" : "Narrative, \(narrativeFormat.name)", draft.narrative),
            ("Treatment by time", draft.treatmentByTime.joined(separator: "\n")),
        ]
    }

    var pcrText: String { pcr.map { "\($0.title)\n\($0.body.isEmpty ? "Not heard" : $0.body)" }.joined(separator: "\n\n") }

    /// Takes a mark off the call, for one dropped by accident. The marks after it move up a number, so the call
    /// still reads Mark 1, Mark 2, Mark 3 with no gap, and the notes the medic wrote on later marks go with them.
    /// The note on the deleted mark goes too. Returns false when there is no such mark.
    @discardableResult mutating func removeMark(_ id: Item.ID) -> Bool {
        guard let removed = recordings.flatMap(\.items).first(where: { $0.id == id && $0.mark != nil })?.mark else { return false }
        var notes: [Int: String] = [:]
        for r in recordings.indices {
            recordings[r].items.removeAll { $0.id == id }
            for i in recordings[r].items.indices {
                guard let n = recordings[r].items[i].mark else { continue }
                let now = n > removed ? n - 1 : n
                if let note = markNotes[n] { notes[now] = note }
                recordings[r].items[i].mark = now
            }
        }
        markNotes = notes
        return true
    }

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
    var clip = false                       // a clip is connected and ready
    /// FEATURE GATE. While true, a connected clip only controls the recording (start, stop, marks) and the audio
    /// comes from this device's own microphone. It is on because the stand-in board has no microphone and plays
    /// a stored voice. Turn it off, on the Clip tab, once a clip with a real microphone is in use.
    /// Follows the device's location during a recording. `location` is how far the person has allowed it.
    @ObservationIgnored let locator = Locator()
    var location = Locator.Level.unasked

    /// The values that are the same on every call for this crew and truck. Set once in Settings, stamped on every report.
    var standing = Standing.load() { didSet { standing.save() } }
    var micStandIn = UserDefaults.standard.object(forKey: "micStandIn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(micStandIn, forKey: "micStandIn") }
    }
    /// Whether Whisper writes the record. Off, this device's own recogniser does, so a call can be
    /// tried with and without Whisper. Takes effect on the next call (core: RecognizerPolicy).
    var whisperEnabled = UserDefaults.standard.object(forKey: "whisperEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(whisperEnabled, forKey: "whisperEnabled"); engine.whisperEnabled = whisperEnabled }
    }
    var recordedBy: String?                // the recogniser that wrote the latest call's record, like "whisper-small.en-ems-ft-f16"
    var clipName: String?                  // the last clip that said hello, like "Earshot-A3F2"
    var clipState = ClipLink.State.idle
    var clipsNearby: [ClipLink.Found] = []   // clips heard while searching, for the medic to pick from
    var clipSignal: ClipLink.Signal?       // how strongly the connected clip is heard, refreshed every two seconds
    var clipReconnecting = false           // the link dropped mid-recording; the recording is held open while the clip comes back
    var clipSilent = false                 // recording from the clip, but no audio has arrived for a few seconds
    var live = Live.none

    var call = Call()                              // the call being worked on
    var review: [Call] = []                        // completed calls waiting for sign-off, newest first; their reports are drafted or being drafted
    var past: [Call] = []                          // signed calls, newest first
    var liveLine: UUID?                            // the line still being spoken
    var levels = [Int](repeating: 0, count: 30)    // recent loudness, oldest first
    var problem: String?
    var rewriting: [Call.ID: NarrativeFormat] = [:]   // calls whose narrative is being written in a newly chosen format
    var narrativeTrouble: [Call.ID: String] = [:]     // why a call's narrative could not be written in the format last chosen

    @ObservationIgnored private let engine = CallEngine()
    @ObservationIgnored private var retired = Set<UUID>()             // live lines already replaced by the record
    @ObservationIgnored private var liveEnds: [UUID: Date] = [:]      // when each live line last changed, so the record replaces it only once it is past that
    @ObservationIgnored private let link = ClipLink()
    @ObservationIgnored private var source = CallEngine.Source.mic   // where the current recording's audio comes from
    @ObservationIgnored private var viaClip = false                   // the current recording runs on the clip too, so stop and marks go to it
    @ObservationIgnored private var lastClipAudio = Date()
    @ObservationIgnored private var silenceTimer: Timer?
    @ObservationIgnored private var droppedAt = Date()                // when the link was lost, while clipReconnecting
    @ObservationIgnored private var dropTimer: Timer?
    @ObservationIgnored private var stopOwed = false                  // a stop could not reach the clip; send it when the clip is back
    @ObservationIgnored private var startAsked: Date?                 // when the clip was last told to start, until it answers

    init() {
        engine.whisperEnabled = whisperEnabled
        link.onState = { [weak self] state in self?.clipChanged(to: state) }
        link.onFound = { [weak self] clips in self?.clipsNearby = clips }
        link.onEvent = { [weak self] event in self?.clipSaid(event) }
        link.onProblem = { [weak self] message in self?.problem = message }
        link.onSignal = { [weak self] signal in self?.clipSignal = signal }
        link.onAudio = { [weak self] buffer in
            self?.lastClipAudio = Date()
            self?.engine.push(buffer)
        }
        engine.onLevel = { [weak self] level in
            self?.levels.removeFirst()
            self?.levels.append(level)
        }
        engine.onLiveText = { [weak self] id, text in self?.heard(id, text) }
        engine.onRecord = { [weak self] id, lines in self?.recorded(id, lines) }
        engine.onCut = { [weak self] in
            self?.liveLine = nil
            self?.save()   // each finished line is on disk before the next one starts
        }
        engine.onProblem = { [weak self] message in
            self?.problem = "Transcription stopped. \(message)"
            self?.stop()
        }
        locator.onPlace = { [weak self] place, at in self?.addPlace(place, at: at) }
        locator.onLevel = { [weak self] level in self?.location = level }
        location = locator.level
        load()
        link.resume()
        locator.ask()   // asked at first launch, before any call, so a recording never stops for the question
    }

    private func heard(_ id: UUID, _ text: String) {
        guard !retired.contains(id) else { return }
        liveEnds[id] = Date()
        if id == engine.segment { liveLine = id }
        for r in call.recordings.indices {
            if let i = call.recordings[r].items.firstIndex(where: { $0.id == id }) {
                call.recordings[r].items[i].text = text
                return
            }
        }
        if !call.recordings.isEmpty { call.recordings[call.recordings.count - 1].items.append(Item(id: id, text: text)) }
    }

    /// Whisper caught up on a call (the open one, or one waiting for sign-off): its lines replace the
    /// live words they cover. Marks stay where they are.
    private func recorded(_ id: Call.ID, _ lines: [RecordLine]) {
        if call.id == id {
            Self.place(lines, in: &call, retiring: &retired, speaking: live == .listening ? engine.segment : nil, ends: liveEnds)
        } else if let i = review.firstIndex(where: { $0.id == id }) {
            Self.place(lines, in: &review[i], retiring: &retired, speaking: nil, ends: liveEnds)
        } else {
            return
        }
        if let l = liveLine, retired.contains(l) { liveLine = nil }
        save()
    }

    /// How long after words are spoken the live recogniser shows them. A live line's last update is
    /// that much later than its audio, so the record is allowed that much less to have covered it.
    static let liveLag: TimeInterval = 1.5

    /// Puts the record's lines into the call and takes out the live words they replace.
    ///
    /// A live line is looked at only once the record has reached the end of it: the line being spoken
    /// stays, and so does one that ran on past where the record has got to. Then, if the record wrote
    /// something for that stretch of time, the live line is replaced by it. If the record wrote nothing
    /// there (the recogniser did not hear it as speech), the live line stays and is marked `unrecorded`,
    /// so words that were heard never just disappear. `ends` is when each live line last changed; a line
    /// with no entry (read back from disk) ended when it began.
    static func place(_ lines: [RecordLine], in call: inout Call, retiring retired: inout Set<UUID>,
                      speaking: UUID?, ends: [UUID: Date]) {
        guard let covered = lines.map(\.end).max(), !call.recordings.isEmpty else { return }
        // Each line belongs to one recording: the last one that had begun by the time the line ended.
        func owner(_ line: RecordLine) -> Int { call.recordings.lastIndex { $0.start <= line.end } ?? 0 }
        for r in call.recordings.indices {
            let mine = lines.filter { owner($0) == r }
            var items: [Item] = []
            for var item in call.recordings[r].items {
                if item.mark != nil || item.place != nil { items.append(item); continue }
                if item.record == true { continue }                                   // rebuilt below
                let end = ends[item.id] ?? item.time
                if item.id == speaking || end > covered.addingTimeInterval(liveLag) { items.append(item); continue }   // not reached yet
                // Live words show up to `liveLag` after their audio, so the audio began that much before `item.time`.
                if lines.contains(where: { $0.start <= end && $0.end >= item.time.addingTimeInterval(-liveLag) }) {
                    retired.insert(item.id)                                          // the record has this stretch
                } else {
                    if item.unrecorded != true {
                        LevelProbe.shared.lineMarked(from: item.time.addingTimeInterval(-liveLag), to: end, chars: item.text.count, by: "place")
                    }
                    item.unrecorded = true
                    items.append(item)
                }
            }
            // The record's rows: a row for each sentence with the time it was said, cut where a mark or a
            // place was logged so those stay between the words they came between. A row that is the same
            // as before keeps its identity, so only new rows appear and nothing else moves.
            let before = Dictionary(call.recordings[r].items.filter { $0.record == true }.map { (RowKey(time: $0.time, text: $0.text), $0.id) }, uniquingKeysWith: { a, _ in a })
            let cuts = items.filter { $0.mark != nil || $0.place != nil }.map(\.time)
            for row in mine.flatMap({ rows(of: $0, cutAt: cuts) }) {
                var item = Item(time: row.time, text: row.text, record: true)
                if let id = before[RowKey(time: row.time, text: row.text)] { item.id = id }
                items.append(item)
            }
            // In time order; rows at the same instant keep the order they were in.
            call.recordings[r].items = items.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        }
    }

    private struct RowKey: Hashable { var time: Date; var text: String }

    /// The shortest stretch of text given a row of its own, in characters. Shorter sentences ("Okay.") join the next.
    static let shortestRow = 24

    /// One line of the record as transcript rows. The recogniser writes a long stretch of speech as one
    /// line with one start time; shown like that, a paragraph carries the time of its first word and
    /// swallows the marks made during it. So the line is divided at the end of each sentence, and at
    /// each time in `cuts` (a mark or a logged place), and each row gets the time its first word was said.
    static func rows(of line: RecordLine, cutAt cuts: [Date]) -> [(time: Date, text: String)] {
        let chars = Array(line.text)
        guard !chars.isEmpty else { return [] }
        let words = line.words.filter { $0.offset >= 0 && $0.offset < chars.count }.sorted { $0.offset < $1.offset }
        let span = line.end.timeIntervalSince(line.start)
        /// When the text at a character offset was said.
        func time(at offset: Int) -> Date {
            if words.isEmpty { return line.start.addingTimeInterval(span * Double(offset) / Double(chars.count)) }
            let said = words.last { $0.offset <= offset }?.time ?? line.start
            return min(max(said, line.start), line.end)
        }
        /// The start of the word at or after an offset, so a row never begins inside a word.
        func wordStart(_ offset: Int) -> Int {
            var o = min(max(offset, 0), chars.count)
            while o < chars.count, chars[o] == " " { o += 1 }
            while o > 0, o < chars.count, chars[o - 1] != " " { o -= 1 }
            return o
        }
        var starts: [Int: Date?] = [0: nil]   // where each row begins, and the time it may not come before
        // the end of a sentence, when the row so far is long enough to stand alone
        var last = 0
        for i in chars.indices where ".?!".contains(chars[i]) && i + 2 < chars.count && chars[i + 1] == " " {
            if i + 2 - last >= shortestRow { starts[i + 2] = nil as Date?; last = i + 2 }
        }
        // a mark or a place logged while the line was being said
        for cut in cuts where cut > line.start && cut < line.end {
            let offset = words.isEmpty ? Int(Double(chars.count) * cut.timeIntervalSince(line.start) / max(span, 0.001))
                                       : (words.first { $0.time >= cut }?.offset ?? chars.count)
            let o = wordStart(offset)
            if o > 0, o < chars.count { starts[o] = max(cut, (starts[o] ?? nil) ?? cut) }
        }
        let order = starts.keys.sorted()
        var out: [(time: Date, text: String)] = []
        var floor = line.start
        for (n, from) in order.enumerated() {
            let to = n + 1 < order.count ? order[n + 1] : chars.count
            let text = String(chars[from..<to]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            var at = from == 0 ? line.start : time(at: from)
            if let notBefore = starts[from] ?? nil { at = max(at, notBefore.addingTimeInterval(0.001)) }   // after the mark it follows
            at = max(at, floor)   // rows of one line never go back in time
            floor = at
            out.append((at, text))
        }
        return out
    }

    /// The call is drafted, so the record is complete: any live words still not in it are marked
    /// `unrecorded`. Returns how many lines that is. If nothing at all was written to the record (no
    /// recogniser could run), the live words are all there is and are left as they are.
    @discardableResult static func settle(_ call: inout Call, ends: [UUID: Date] = [:]) -> Int {
        guard call.recordings.contains(where: { $0.items.contains { $0.record == true } }) else { return 0 }
        var count = 0
        for r in call.recordings.indices {
            for i in call.recordings[r].items.indices {
                let item = call.recordings[r].items[i]
                guard item.mark == nil, item.place == nil, item.record != true, !item.text.isEmpty else { continue }
                if item.unrecorded != true {
                    LevelProbe.shared.lineMarked(from: item.time.addingTimeInterval(-liveLag), to: ends[item.id] ?? item.time, chars: item.text.count, by: "settle")
                }
                call.recordings[r].items[i].unrecorded = true
                count += 1
            }
        }
        return count
    }

    // MARK: The call

    func newCall() {
        locator.reset()
        call = Call()
        engine.beginCall(call.id, at: call.start)
        recordedBy = engine.recordName
        problem = nil
        live = .ready
        tab = .live
        save()
    }

    func record() {
        Task { @MainActor in
            problem = await CallEngine.authorize(microphone: audioSource == .mic)
            guard problem == nil, live != .listening else { return }
            if clip {
                // Nothing is shown as recording until the clip confirms, in clipSaid. If it never does, say so.
                guard link.send("start") else {
                    problem = "The clip is not connected, so the recording did not start."
                    return
                }
                let asked = Date()
                startAsked = asked
                try? await Task.sleep(for: .seconds(3))
                if startAsked == asked && live != .listening {
                    startAsked = nil
                    problem = "The clip did not start recording. Check that it is on and close by, then try again."
                }
            } else {
                begin(from: .mic, viaClip: false)
            }
        }
    }

    /// Pause and play: pauses the recording if it is running, otherwise carries it on (or begins it).
    /// With no call open it does nothing.
    func toggleRecording() {
        switch live {
        case .listening: stop()
        case .ready, .between, .cutShort: record()
        case .none: break
        }
    }

    /// Where the next recording's audio will come from: the clip, unless there is none or the gate holds it to the microphone.
    var audioSource: CallEngine.Source { clip && !micStandIn ? .clip : .mic }

    /// The audio source in words, for the screen: the running recording's, or the next one's.
    var audioLabel: String { (live == .listening ? source : audioSource) == .clip ? "Clip audio" : "\(deviceName) mic" }

    private func begin(from source: CallEngine.Source, viaClip: Bool) {
        guard live != .listening, live != .none else { return }
        do {
            engine.beginCall(call.id, at: call.start)   // a call reopened after the app closed carries on from its saved record
            recordedBy = engine.recordName
            try engine.start(from: source)
            self.source = source
            self.viaClip = viaClip
            if let last = call.recordings.indices.last, let pausedAt = call.recordings[last].end {
                // Play after pause: carry on in the same recording, so the call reads as one transcript.
                call.recordings[last].paused = (call.recordings[last].paused ?? 0) + Date().timeIntervalSince(pausedAt)
                call.recordings[last].end = nil
            } else {
                call.recordings.append(Recording())
            }
            live = .listening
            startAsked = nil
            locator.start()
            if source == .clip { watchForSilence() }
        } catch {
            problem = error.localizedDescription
            if viaClip { link.send("stop") }
        }
    }

    func stop(as next: Live = .between) {
        guard live == .listening else { return }
        if viaClip && !link.send("stop") { stopOwed = true }   // the clip is away and may still be capturing
        finish(as: next)
    }

    private func finish(as next: Live) {
        guard live == .listening else { return }
        engine.stop()
        locator.stop()
        // A recording that ends while the clip is away ended when the clip was last heard, not now.
        call.recordings[call.recordings.count - 1].end = clipReconnecting ? droppedAt : Date()
        clipReconnecting = false
        dropTimer?.invalidate()
        live = next
        silenceTimer?.invalidate()
        clipSilent = false
        save()
    }

    /// While recording from the clip, checks that audio keeps arriving. A link can stay up with nothing coming through it.
    private func watchForSilence() {
        lastClipAudio = Date()
        clipSilent = false
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let silent = Date().timeIntervalSince(self.lastClipAudio) > 2.5
            if silent != self.clipSilent { self.clipSilent = silent }
        }
    }

    func mark() {
        guard live == .listening else { return }
        if viaClip { link.send("marker") }   // so the clip logs it too; its echo never becomes an intent
        addMark(fromClip: false)
    }

    /// Logs a place the device has moved to. It goes above the line still being spoken, so that line is not broken in two.
    private func addPlace(_ place: Place, at time: Date) {
        guard live == .listening, let r = call.recordings.indices.last else { return }
        let row = Item(time: time, place: place)
        if let speaking = liveLine, let i = call.recordings[r].items.firstIndex(where: { $0.id == speaking }) {
            call.recordings[r].items.insert(row, at: i)
        } else {
            call.recordings[r].items.append(row)
        }
        save()
    }

    private func addMark(fromClip: Bool) {
        engine.mark(fromClip: fromClip)
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
        case .trouble: "Clip not working"
        case .searching: "Searching"
        case .idle: "Not connected"
        case .off: "Bluetooth unavailable"
        }
    }

    /// Starts looking for clips. The ones in range show up in `clipsNearby`.
    func connect() {
        link.connect()
    }

    /// Connects to the clip the medic picked from `clipsNearby`.
    func connect(to clip: ClipLink.Found) {
        link.connect(to: clip.id)
    }

    /// Makes the clip blink (and beep, if it has a speaker) for about three seconds.
    func findClip() {
        link.send("find")
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
            if live == .listening && source == .clip && !clipReconnecting { holdForReconnect() }   // the link dropped mid-recording
        }
    }

    /// How long a recording waits for a dropped clip before it is ended as cut short.
    private static let grace: TimeInterval = 30

    /// The link dropped mid-recording. Most drops last a second or two, so the recording stays open and the
    /// header says the clip is reconnecting. If the clip is not back within the grace period, it ends as cut short.
    private func holdForReconnect() {
        engine.stop()   // the line being spoken closes; the next words start a new one
        silenceTimer?.invalidate()
        clipSilent = false
        droppedAt = Date()
        clipReconnecting = true
        dropTimer?.invalidate()
        dropTimer = Timer.scheduledTimer(withTimeInterval: Self.grace, repeats: false) { [weak self] _ in
            guard let self, self.clipReconnecting else { return }
            self.finish(as: .cutShort)
        }
    }

    /// The clip is back and still capturing: carry on in the same recording.
    private func resumeAfterDrop() {
        do {
            try engine.start(from: .clip)
            clipReconnecting = false
            dropTimer?.invalidate()
            watchForSilence()
        } catch {
            problem = error.localizedDescription
            finish(as: .cutShort)
        }
    }

    private func clipSaid(_ event: ClipEvent) {
        guard let intent = ClipIntent(event) else {
            #if DEBUG
            print("clip link: no action for a \"\(event.type)\" event")
            #endif
            return
        }
        switch intent {
        case .hello(let codec):
            if let codec, codec != "opus" { problem = "This clip sends \(codec) audio, which Earshot cannot read yet." }
        case .started:
            clipStarted()
        case .listening(true):
            // Said after every connect. The clip kept capturing through a drop: carry on, or pick it up afresh.
            if stopOwed {
                stopOwed = false
                link.send("stop")   // the medic stopped this recording while the clip was away
            } else if clipReconnecting {
                resumeAfterDrop()
            } else {
                clipStarted()
            }
        case .listening(false):
            stopOwed = false   // nothing left to stop
            // The clip says it is not capturing, so the app must not go on showing a recording that runs on it.
            if live == .listening && viaClip { finish(as: .between) }
        case .stopped:
            if viaClip { finish(as: .between) }
        case .mark:
            if live == .listening { addMark(fromClip: true) }
        case .toggleRecording:
            toggleRecording()
        case .toggleCall:
            toggleCall()
        }
    }

    /// The clip began capturing, from its button or because the app asked.
    private func clipStarted() {
        guard live != .listening else { return }
        guard live != .none else {
            link.send("stop")   // no call is open to record on, so nothing is recorded and the clip's light goes dark again
            return
        }
        Task { @MainActor in
            let source = audioSource
            problem = await CallEngine.authorize(microphone: source == .mic)
            if problem == nil { begin(from: source, viaClip: true) } else { link.send("stop") }
        }
    }

    // MARK: The paperwork

    /// The clip's click and hold. With a call open it completes it. With none open it begins one and starts recording.
    func toggleCall() {
        if live == .none {
            newCall()
            record()
        } else {
            complete(show: false)   // the medic's hands are on the patient, so the screen stays where it is
        }
    }

    /// Completes the open call: its recording is closed for good and it joins the calls waiting for sign-off, where
    /// its nurse handoff and PCR are drafted. The Live Call tab is free for a new call straight away.
    func complete(show: Bool = true) {
        stop()
        guard live != .none else { return }
        guard !call.recordings.isEmpty else {   // nothing was recorded, so there is nothing to report on
            discard()
            return
        }
        var done = call
        done.draft = .blank
        done.draftNote = nil
        done.markNotes = [:]
        done.drafted = false
        done.format = nil
        done.narratives = nil
        review.insert(done, at: 0)
        call = Call()
        live = .none
        problem = nil   // any recording trouble belonged to the call that just ended
        if show { tab = .drafts }
        save()
        draft(done.id)
    }

    /// Writes the reports for a call waiting for sign-off. Until it finishes, the call shows as "Writing reports".
    private func draft(_ id: Call.ID) {
        guard review.contains(where: { $0.id == id }) else { return }
        Task { @MainActor in
            let out = await engine.finish(id)   // waits for Whisper to finish the call, then drafts from the record
            guard let i = review.firstIndex(where: { $0.id == id }) else { return }   // signed or removed meanwhile
            var notes = out.notes
            let missed = Self.settle(&review[i], ends: liveEnds)   // the record is complete: what it never took up is marked
            if missed > 0 {
                notes.append("\(plural(missed, "line")) heard live \(missed == 1 ? "is" : "are") not in the record, so not in the report. \(missed == 1 ? "It is" : "They are") marked in the transcript.")
            }
            review[i].draft = out.draft
            review[i].docs = out.docs
            review[i].reviewNotes = notes
            review[i].draftNote = notes.isEmpty ? nil : notes.joined(separator: " ")
            // The record's narrative is the plain one. Another format is written only when the medic picks it.
            review[i].format = .plain
            review[i].narratives = out.draft.narrative.isEmpty ? [:] : [NarrativeFormat.plain.rawValue: out.draft.narrative]
            review[i].drafted = true
            save()
        }
    }

    /// The medic chose a narrative format for a call waiting for sign-off. A format already written for this call is
    /// shown at once; a new one is written from the transcript first. The choice becomes the crew's format for the
    /// next calls. If it cannot be written, the call keeps the narrative it had and `narrativeTrouble` says why.
    func setNarrativeFormat(_ format: NarrativeFormat, for id: Call.ID) {
        guard let i = review.firstIndex(where: { $0.id == id }), review[i].drafted, rewriting[id] == nil else { return }
        narrativeTrouble[id] = nil
        guard format != review[i].narrativeFormat else { return }
        // Keep the narrative being left, so coming back to its format brings back the same words.
        var narratives = review[i].narratives ?? [:]
        if !review[i].draft.narrative.isEmpty { narratives[review[i].narrativeFormat.rawValue] = review[i].draft.narrative }
        review[i].narratives = narratives
        if let written = narratives[format.rawValue] {
            show(written, as: format, for: id)
            return
        }
        rewriting[id] = format
        let transcript = review[i].spoken
        Task { @MainActor in
            defer { rewriting[id] = nil }
            do {
                show(try await writeNarrative(from: transcript, as: format), as: format, for: id)
            } catch {
                narrativeTrouble[id] = "The narrative could not be written as \(format.name), so it is unchanged. \(error.localizedDescription)"
            }
        }
    }

    private func show(_ narrative: String, as format: NarrativeFormat, for id: Call.ID) {
        guard let i = review.firstIndex(where: { $0.id == id }) else { return }   // signed or removed meanwhile
        review[i].narratives = (review[i].narratives ?? [:]).merging([format.rawValue: narrative]) { _, new in new }
        review[i].draft.narrative = narrative
        review[i].format = format
        NarrativeFormat.preferred = format
        save()
    }

    /// Signing off moves a call from the ones waiting to the signed ones.
    func signOff(_ id: Call.ID, _ signature: Signature) {
        guard let i = review.firstIndex(where: { $0.id == id }) else { return }
        var signed = review.remove(at: i)
        signed.signature = signature
        signed.signedAt = Date()
        past.insert(signed, at: 0)
        save()
    }

    /// Deletes a mark from a call waiting for sign-off. It was dropped by accident, for example by a click on the clip
    /// that was not meant. The handoff line that asked what happened at that mark goes with it.
    func deleteMark(_ id: Item.ID, in call: Call.ID) {
        guard let i = review.firstIndex(where: { $0.id == call }), review[i].removeMark(id) else { return }
        save()
    }

    /// Edit, after signing: the call goes back to waiting until it is signed again.
    func reopen(_ id: Call.ID) {
        guard let i = past.firstIndex(where: { $0.id == id }) else { return }
        var edited = past.remove(at: i)
        edited.signedAt = nil
        edited.signature = nil   // an edited call has to be signed again
        review.insert(edited, at: 0)
        save()
    }

    /// Throws away the call being recorded, with its recording.
    func discard() {
        stop()
        engine.discard(call.id)
        call = Call()
        problem = nil
        live = .none
        save()
    }

    func delete(at offsets: IndexSet) {
        past.remove(atOffsets: offsets)
        save()
    }

    // MARK: On disk

    private struct Saved: Codable {
        var open: Call?       // the call being recorded
        var past: [Call]
        var review: [Call]?   // completed, not signed. Optional so files written before it existed still load
    }

    private static let file = URL.applicationSupportDirectory.appending(path: "calls.json")

    /// Writes the open call and the past calls. Called whenever either changes, and when the app leaves the screen.
    /// ponytail: one file rewritten whole. Move to a file per call, or SwiftData, when the history grows past a few hundred calls.
    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Calls hold patient information: encrypted on disk and kept out of iCloud backups. The file has to stay
            // writable while the device is locked, since a recording carries on then, so it is protected until the
            // device is first unlocked after a restart, not every time it locks.
            try JSONEncoder().encode(Saved(open: live != .none ? call : nil, past: past, review: review)).write(to: Self.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var file = Self.file, values = URLResourceValues()
            values.isExcludedFromBackup = true
            try file.setResourceValues(values)
        } catch {
            problem = "This call could not be saved. \(error.localizedDescription)"
        }
    }

    /// Writes the pipeline's record of every open call. Called when the app leaves the screen.
    func saveRecords() { engine.saveRecords() }

    private func load() {
        guard let data = try? Data(contentsOf: Self.file) else { return }   // nothing saved yet
        do {
            let saved = try JSONDecoder().decode(Saved.self, from: data)
            past = saved.past
            review = saved.review ?? []
            if var open = saved.open {
                // A recording that was still running when the app closed ends at its last line.
                for i in open.recordings.indices where open.recordings[i].end == nil {
                    open.recordings[i].end = open.recordings[i].items.last?.time ?? open.recordings[i].start
                }
                if open.drafted {
                    review.insert(open, at: 0)   // saved by an older build, which kept a completed call open until it was signed
                } else {
                    call = open
                    live = open.recordings.isEmpty ? .ready : .between
                }
            }
            // Records are kept only for calls that can still use one: the open call and those not yet drafted.
            engine.forgetRecords(except: Set(review.filter { !$0.drafted }.map(\.id) + (live != .none ? [call.id] : [])))
            // Drafting that was cut off when the app closed is started again, from the record that was saved.
            for waiting in review where !waiting.drafted { draft(waiting.id) }
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
        // A narrative format lays its sections out under lettered headings, and says so when one was not heard.
        let soap = NarrativeFormat.soap.layOut(["Chest pain for 30 minutes.", "BP 150/90.", "", "Aspirin given."])
        assert(soap.hasPrefix("S - SUBJECTIVE:\nChest pain for 30 minutes.\n\nO - OBJECTIVE:") && soap.contains("A - ASSESSMENT:\nNot heard.\n\nP - PLAN:"))
        assert(NarrativeFormat.isHeading("R - RX (TREATMENT):") && !NarrativeFormat.isHeading("BP 150/90.") && !NarrativeFormat.isHeading("Not heard."))
        assert(NarrativeFormat.allCases.allSatisfy { $0 == .plain || $0.sections.map { $0.prefix(1) }.joined() == $0.name })
        // A call saved before formats existed has none, and reads as plain. A chosen format survives being saved.
        assert(copy?.narrativeFormat == .plain && call.pcr[2].title == "Narrative")
        call.format = .draatt
        let formatted = try? JSONDecoder().decode(Call.self, from: JSONEncoder().encode(call))
        assert(formatted?.narrativeFormat == .draatt && formatted?.pcr[2].title == "Narrative, DRAATT")
        // The clip's messages must be readable exactly as firmware/BLUETOOTH.md gives them.
        // The level meter: silence and a quiet room show nothing, quiet speech still moves it, and louder never reads lower.
        func tone(_ amplitude: Float) -> [Int16] {   // a quarter second at 16 kHz, the shape the pipeline's audio has
            (0..<4000).map { Int16(amplitude * 32767 * sin(Float($0) * 0.3)) }
        }
        let heard = [0, 0.0005, 0.002, 0.01, 0.03, 0.1, 0.4].map { Audio.level(tone($0)) }
        assert(heard[2] == 0 && heard[3] >= 3 && heard[5] == 6 && heard == heard.sorted(), "the level meter is off: \(heard)")
        // The record replaces live words only once it has reached the end of them, and only where it wrote
        // something for that stretch. Live words it went past with nothing written stay, marked.
        let t0 = Date(timeIntervalSince1970: 1000)
        let spoken = Item(time: t0.addingTimeInterval(1), text: "covered"), running = Item(time: t0.addingTimeInterval(4), text: "runs on"),
            now = Item(time: t0.addingTimeInterval(5), text: "speaking"), flag = Item(time: t0.addingTimeInterval(0.2), mark: 1)   // a mark before the first word
        var talk = Call()
        talk.recordings = [Recording(start: t0, items: [spoken, flag, running, now])]
        var gone = Set<UUID>()
        let line = RecordLine(start: t0, end: t0.addingTimeInterval(6), text: "the record")
        place([line], in: &talk, retiring: &gone, speaking: now.id,
              ends: [spoken.id: t0.addingTimeInterval(5), running.id: t0.addingTimeInterval(20), now.id: t0.addingTimeInterval(5.5)])
        assert(talk.recordings[0].items.map(\.text) == ["the record", "", "runs on", "speaking"] && gone == [spoken.id], "live words were replaced too early: \(talk.recordings[0].items.map(\.text))")
        // Whisper heard nothing between 21 and 40 seconds, then wrote a line: the live words from that gap stay.
        let quiet = Item(time: t0.addingTimeInterval(28), text: "missed by the record")
        talk.recordings[0].items.append(quiet)
        let later = [line, RecordLine(start: t0.addingTimeInterval(6), end: t0.addingTimeInterval(21), text: "more"),
                     RecordLine(start: t0.addingTimeInterval(40), end: t0.addingTimeInterval(45), text: "after the gap")]
        place(later, in: &talk, retiring: &gone, speaking: nil,
              ends: [running.id: t0.addingTimeInterval(20), now.id: t0.addingTimeInterval(5.5), quiet.id: t0.addingTimeInterval(31)])
        assert(talk.recordings[0].items.map(\.text) == ["the record", "", "more", "missed by the record", "after the gap"], "\(talk.recordings[0].items.map(\.text))")
        assert(talk.recordings[0].items.filter { $0.unrecorded == true }.map(\.text) == ["missed by the record"] && !gone.contains(quiet.id))
        // A long line of the record becomes a row for each sentence, each with the time it was said, and a mark
        // made in the middle of it stays between the words it came between. Rows that have not changed keep their identity.
        let long = RecordLine(start: t0, end: t0.addingTimeInterval(90), text: "BP 150 over 90, heart rate 104. Okay. Gave 324 of aspirin chewed and the pain is easing now.",
                              words: [(0, 0), (15, 20), (32, 40), (38, 70), (56, 76), (60, 80)].map { RecordLine.Word(offset: $0.0, time: t0.addingTimeInterval($0.1)) })
        let split = rows(of: long, cutAt: [])
        assert(split.map(\.text) == ["BP 150 over 90, heart rate 104.", "Okay. Gave 324 of aspirin chewed and the pain is easing now."], "\(split.map(\.text))")
        assert(split.map { Int($0.time.timeIntervalSince(t0)) } == [0, 40], "\(split.map { $0.time.timeIntervalSince(t0) })")
        let cut = rows(of: long, cutAt: [t0.addingTimeInterval(78)])
        assert(cut.map(\.text) == ["BP 150 over 90, heart rate 104.", "Okay. Gave 324 of aspirin", "chewed and the pain is easing now."], "\(cut.map(\.text))")
        assert(cut[2].time > t0.addingTimeInterval(78) && rows(of: RecordLine(start: t0, end: t0.addingTimeInterval(4), text: "No word times here."), cutAt: []).count == 1)
        var sorted = Call()
        sorted.recordings = [Recording(start: t0, items: [Item(time: t0.addingTimeInterval(78), mark: 1)])]
        place([long], in: &sorted, retiring: &gone, speaking: nil, ends: [:])
        assert(sorted.recordings[0].items.map { $0.mark == nil ? $0.text : "MARK" } == ["BP 150 over 90, heart rate 104.", "Okay. Gave 324 of aspirin", "MARK", "chewed and the pain is easing now."])
        let ids = sorted.recordings[0].items.map(\.id)
        place([long, RecordLine(start: t0.addingTimeInterval(95), end: t0.addingTimeInterval(99), text: "Transporting now.")], in: &sorted, retiring: &gone, speaking: nil, ends: [:])
        assert(Array(sorted.recordings[0].items.map(\.id).prefix(4)) == ids && sorted.recordings[0].items.count == 5, "rows that did not change were rebuilt")
        talk.recordings[0].items.append(Item(time: t0.addingTimeInterval(60), text: "after the record ended"))
        assert(settle(&talk) == 2 && talk.recordings[0].items.count == 6 && talk.markCount == 1, "drafting must keep live words and mark them")
        // A mark dropped by accident can be deleted: the ones after it move up, and their notes with them.
        var marked = Call()
        marked.recordings = [Recording(items: [Item(mark: 1), Item(text: "x"), Item(mark: 2)]), Recording(items: [Item(mark: 3)])]
        marked.markNotes = [2: "two", 3: "three"]
        let second = marked.recordings[0].items[2].id
        assert(marked.removeMark(second) && marked.markCount == 2 && marked.markNotes == [2: "three"])
        assert(marked.recordings.flatMap(\.items).compactMap(\.mark) == [1, 2] && !marked.removeMark(second) && !marked.removeMark(marked.recordings[0].items[1].id))
        let hello = try? JSONDecoder().decode(ClipEvent.self, from: Data(#"{"type":"hello","device":"Earshot-A3F2","fw":"0.6.0","audio":{"codec":"opus","rate":16000,"channels":1,"frame_ms":20,"bitrate":32000}}"#.utf8))
        assert(hello?.device == "Earshot-A3F2" && hello?.audio?.codec == "opus")
        let marker = try? JSONDecoder().decode(ClipEvent.self, from: Data(#"{"type":"marker","id":1,"source":"button","t_ms":47781,"audio_seq":327}"#.utf8))
        assert(marker?.type == "marker" && marker?.source == "button")
        assert(hello.flatMap(ClipIntent.init) == .hello(codec: "opus") && marker.flatMap(ClipIntent.init) == .mark)

        // Location: under 50 metres from the last reported place is the same place; a location row reaches the drafting model.
        let here = CLLocation(latitude: 42.3398, longitude: -71.0892)
        assert(Locator.isNew(here, since: nil) && !Locator.isNew(CLLocation(latitude: 42.3400, longitude: -71.0892), since: here))
        assert(Locator.isNew(CLLocation(latitude: 42.3410, longitude: -71.0892), since: here))
        var located = Call()
        located.recordings = [Recording(items: [Item(place: Place(latitude: 42.3398, longitude: -71.0892, accuracy: 8, street: "360 Huntington Ave", city: "Boston", state: "MA", zip: "02115"))])]
        assert(located.transcript.contains("LOCATION 360 Huntington Ave, Boston, MA 02115 (42.33980, -71.08920)") && located.spoken.isEmpty)
        let toggle = { (target: String) in
            (try? JSONDecoder().decode(ClipEvent.self, from: Data(#"{"type":"toggle","target":"\#(target)","source":"button","t_ms":204759}"#.utf8))).flatMap(ClipIntent.init)
        }
        assert(toggle("recording") == .toggleRecording && toggle("call") == .toggleCall)   // as firmware 0.11.0 sends them
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
                    case .home: HomeScreen().screenTransition()
                    case .live: LiveScreen().screenTransition()
                    case .drafts: DraftsScreen().screenTransition()
                    case .clip: ClipScreen().screenTransition()
                    case .settings: SettingsScreen().screenTransition()
                    }
                }
                .smooth(model.tab)
                .padding(.top, 8).padding(.horizontal, fit(32, 20)).padding(.bottom, fit(32, 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if phone { HStack(spacing: 8) { Tabs(); SettingsPill() }.padding(.horizontal, 20).padding(.bottom, 4) }
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
                // A recording carries on when the app leaves the screen or the device locks: the app is allowed to
                // keep the microphone and the clip link in the background. Only its state is saved here.
                if phase != .active { model.save(); model.saveRecords() }
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
                HStack(spacing: 10) { Tabs(); SettingsPill() }
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
        } else if model.live == .listening && model.clipReconnecting {
            Text("Reconnecting to the clip").font(geist(15, 600)).foregroundStyle(Color.yellow)
        } else if model.live == .listening && model.clipSilent {
            Text("No audio from the clip").font(geist(15, 600)).foregroundStyle(Color.yellow)
        } else if model.live == .listening {
            HStack(spacing: 10) {
                BlinkDot(size: 10)
                Text("Recording").font(geist(15, 600)).foregroundStyle(Color.red)
                Text(model.audioLabel)   // which microphone this recording is using
            }
        } else {
            Text(model.live == .between ? "Paused, \(model.audioLabel)" : "Call started \(clock(model.call.start)), \(model.audioLabel)")
        }
    }
}

/// The four tabs. In the header on iPad, along the bottom on iPhone.
struct Tabs: View {
    @Environment(Model.self) private var model
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Tab.main, id: \.self) { tab in
                let on = model.tab == tab
                Button { model.tab = tab } label: {
                    HStack(spacing: fit(8, 6)) {
                        if tab == .clip { clipDot(selected: on) }
                        Text(tab.rawValue).lineLimit(1)
                        if tab == .drafts && !model.review.isEmpty {
                            // How many completed calls still need a person to check and sign them.
                            Text("\(model.review.count)").font(geist(13, 700)).foregroundStyle(Color.bg)
                                .frame(minWidth: 20, minHeight: 20).background(Color.yellow, in: Capsule())
                                .accessibilityLabel("\(model.review.count) waiting for sign-off")
                        }
                    }
                    .font(geist(15, 600))
                    .foregroundStyle(on ? Color.bg : .dim)
                    .padding(.horizontal, fit(22, 6))
                    .frame(maxWidth: phone ? .infinity : nil)
                    .frame(height: 44)
                    .background { if on { Capsule().fill(Color.ink).matchedGeometryEffect(id: "tab", in: pill) } }   // slides to the new tab
                    .contentShape(Capsule())
                }
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .buttonStyle(.plain)
        .smooth(model.tab, 0.28)
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

/// The settings button. It stands beside the tab bar, not in it.
struct SettingsPill: View {
    @Environment(Model.self) private var model

    var body: some View {
        let on = model.tab == .settings
        Button { model.tab = .settings } label: {
            Image(systemName: "gearshape.fill").font(.system(size: 18, weight: .semibold))
                .foregroundStyle(on ? Color.bg : .dim)
                .frame(width: 52, height: 52)
                .background(on ? Color.ink : .panel, in: Circle())
                .overlay(Circle().strokeBorder(Color.line))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: Home

struct HomeScreen: View {
    @Environment(Model.self) var model
    @State var opened: Call?      // the signed call being read
    @State var reviewing: Call?   // the call waiting for sign-off that is open in its sheet
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
                        Button(model.live == .listening ? "Live call →" : "Resume call") {
                            model.tab = .live
                            if model.live != .listening { model.record() }   // resuming means recording again, not only showing the call
                        }.buttonStyle(Pill(height: fit(76, 68), size: 22, minWidth: fit(260, nil), grow: phone))
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
                if hasCalls { recentCalls }
            }
            .padding(.leading, fit(24, 4)).padding(.top, hasCalls ? fit(12, 0) : 0)
            // With no past calls the headline sits centred, as designed. With some, it moves up and the list fills the rest.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: hasCalls ? .topLeading : .leading)

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
        .sheet(item: $reviewing) { ReviewSheet(id: $0.id).presentationSizing(.page).presentationDragIndicator(.visible) }
    }
}

extension HomeScreen {
    /// Whether there is any completed call to list.
    var hasCalls: Bool { !model.review.isEmpty || !model.past.isEmpty }

    /// The big word shrinks on iPhone once there are calls to make room for.
    var headline: CGFloat { fit(176, hasCalls ? 72 : 104) }

    /// Three calls at most. The ones still waiting for sign-off come first, since they need the medic; any room
    /// left goes to the most recent signed calls. The rest are on the AI Drafts tab.
    var recentCalls: some View {
        let waiting = Array(model.review.prefix(3))
        let signed = Array(model.past.prefix(3 - waiting.count))
        let total = model.review.count + model.past.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(waiting.isEmpty ? "Past calls" : "\(plural(model.review.count, "call")) to sign off")
                    .font(geist(15, 600)).foregroundStyle(waiting.isEmpty ? Color.dim : .yellow)
                Spacer()
                if total > 3 {
                    Button("All \(total) calls") { model.tab = .drafts }
                        .font(geist(15, 600)).foregroundStyle(Color.ink).buttonStyle(.plain).frame(minHeight: 44)
                }
            }
            List {
                ForEach(waiting) { call in CallRow(call: call, waiting: true) { reviewing = call } }
                // The signed calls shown are the first rows of `model.past`, so a swiped row's position is its position there too.
                ForEach(signed) { call in CallRow(call: call, waiting: false) { opened = call } }
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
            Text(model.clipTitle).font(doto(fit(46, 34))).lineLimit(1).minimumScaleFactor(0.5)   // the key below leaves no room for a second line
            HStack(spacing: 10) {
                Circle().frame(width: 10, height: 10)
                Text("Connected")
            }
            .font(geist(19, 500)).foregroundStyle(Color.green).padding(.top, 6).padding(.bottom, 18)
            // ponytail: the clip reports no battery or signal yet. Add those rows when the firmware sends them.
            row("Signal") {
                if let signal = model.clipSignal {
                    LevelDots(lit: signal.bars, of: 4)
                    Text(["Weak", "Fair", "Good", "Strong"][signal.bars - 1])
                    Text("\(signal.dBm) dBm").font(geist(15)).foregroundStyle(Color.dim)
                } else {
                    Text("Measuring").foregroundStyle(Color.dim)
                }
            }
            row("Link") { Text("Bluetooth") }
            row("Audio from") {
                Button(model.micStandIn ? "\(deviceName) mic" : "Clip") { model.tab = .settings }
                    .buttonStyle(.plain).underline()
                    .accessibilityHint("Opens Settings, where the microphone is chosen")
            }
            Color.line.frame(height: 1)
            ClipKey().padding(.top, 16)
            Spacer(minLength: 16)
            VStack(spacing: 14) {
                Button(finding ? "Blinking" : "Find clip") {
                    model.findClip()
                    finding = true
                    Task {
                        try? await Task.sleep(for: .seconds(3.2))   // how long the clip blinks
                        finding = false
                    }
                }
                .buttonStyle(Pill(grow: true))
                .disabled(finding)
                Button("Disconnect") { model.disconnect() }.buttonStyle(Pill(fill: nil, grow: true))
            }
        }
        .padding(.top, fit(36, 24)).padding(.horizontal, fit(32, 20)).padding(.bottom, fit(32, 20))
        .side()
        .panel()
    }

    /// The headline while no clip is usable. It names the real state, never a hoped-for one.
    private var heading: String {
        switch model.clipState {
        case .searching: "Looking for clips"
        case .connecting: "Connecting"
        case .trouble: "Clip not working"
        case .off: "Bluetooth unavailable"
        case .idle, .ready: "No clip connected"
        }
    }

    /// What to tell the medic while no clip is connected.
    private var waiting: String {
        switch model.clipState {
        case .off(let why), .trouble(let why): why
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
            Text(heading).font(doto(fit(46, 34)))
            Text(waiting)
                .font(geist(19)).lineSpacing(5).foregroundStyle(Color.dim).padding(.top, 10).padding(.bottom, 22)
            if model.clipState == .searching {
                Text(model.clipsNearby.isEmpty ? "Nearby: none yet" : "Nearby: tap a clip to connect").font(geist(15, 600)).foregroundStyle(Color.dim)
                ForEach(model.clipsNearby) { clip in
                    Button { model.connect(to: clip) } label: {
                        VStack(spacing: 0) {
                            Color.line.frame(height: 1)
                            HStack(spacing: 16) {
                                Dots(clipArt, pitch: 3, r: 1.08, palette: ["w": .ink, "m": .mid, "g": .green])
                                Text(clip.name).font(doto(24)).lineLimit(1)
                                Spacer()
                                LevelDots(lit: clip.bars, of: 4)
                            }
                            .frame(height: 86)
                            .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Connect \(clip.name), signal \(clip.bars) of 4")
                }
                Color.line.frame(height: 1)
            }
            Spacer(minLength: 16)
            switch model.clipState {
            case .idle: Button("Find my clip") { model.connect() }.buttonStyle(Pill(grow: true))
            case .searching: Button("Stop looking") { model.disconnect() }.buttonStyle(Pill(fill: nil, grow: true))
            case .connecting, .trouble: Button("Forget this clip") { model.disconnect() }.buttonStyle(Pill(fill: nil, grow: true))
            case .ready, .off: EmptyView()
            }
        }
        .padding(.top, fit(36, 24)).padding(.horizontal, fit(32, 20)).padding(.bottom, fit(32, 20))
        .side()
        .panel()
    }
}
