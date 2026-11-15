import AVFoundation
import CoreLocation
import Opus
import SwiftUI
import Fill

enum Tab: String {
    case home = "Home", live = "Live Call", drafts = "Reports", clip = "Clip", settings = "Settings"
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

    // What follows is on spoken lines only, and is left out of calls recorded before Whisper wrote the record.
    var end: Date? = nil              // when its last word was said. `time` is when its first was
    /// Who wrote the line. Nil: the live recogniser's words, not yet looked at by Whisper.
    /// `whisper`: Whisper's line, which took the live words' place. `apple`: the live recogniser heard it and Whisper
    /// wrote nothing for that stretch, so it is kept, with a confidence of 0.
    var source: Source? = nil
    var confidence: Double? = nil     // 0 to 1: the average of the words' confidences
    var words: [Word]? = nil          // Whisper's lines only

    enum Source: String, Codable { case whisper, apple }
    /// One word of a line: where it starts in the text, when it was said, and how sure Whisper was of it.
    struct Word: Codable { var offset: Int; var time: Date; var confidence: Double }
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
    var drafted = false               // the call was completed and its transcript is finished, so it can be signed
    var report: [String: String]?     // its NEMSIS record: answers by element, like "ePatient.15": "68" (see `Nemsis`)
    var evidence: [String: Evidence]? // where each answer the transcript gave came from, by element. A typed answer has none
    var filledBy: String?             // the model that filled the report from the transcript. Nil: it was not filled
    var fillNote: String?             // why the report was not filled, in words for the medic
    var markNotes: [Int: String] = [:]
    var signedAt: Date?
    var signature: Signature?
    var whisper: Bool?                  // Whisper wrote this call's record. Nil on calls with live words only
    var audio: [Take]?                  // the call's audio on disk, oldest first. Nil on calls recorded before audio was kept

    /// Where a line is in the call's audio: the take it was said in, and how many seconds into it.
    func place(of item: Item) -> (take: Take, from: TimeInterval, to: TimeInterval)? {
        // Whisper's lines carry the times of their first and last words. A live line only has when its words
        // first showed, a moment after they were said, so more is played either side of it.
        let sure = item.source == .whisper
        guard !item.text.isEmpty, let take = audio?.last(where: { $0.start <= item.time.addingTimeInterval(0.1) }) else { return nil }
        let from = item.time.timeIntervalSince(take.start) - (sure ? 0.3 : 2)
        return (take, max(0, from), (sure ? item.end ?? item.time : item.time.addingTimeInterval(6)).timeIntervalSince(take.start) + 0.4)
    }

    var markCount: Int { recordings.reduce(0) { $0 + $1.marks } }
    var seconds: Int { recordings.reduce(0) { $0 + $1.seconds } }

    /// The call as text: one line per thing said or marked, each with its clock time.
    var transcript: String {
        recordings.flatMap(\.items).filter { $0.mark != nil || $0.place != nil || !$0.text.isEmpty }
            .map { "[\(clock($0.time))] " + ($0.mark.map { "MARK \($0)" } ?? $0.place.map { "LOCATION \($0.line) (\($0.coordinates))" } ?? $0.text) }
            .joined(separator: "\n")
    }

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
    var clipName: String?                  // the last clip that said hello, like "Earshot-A3F2"
    var clipState = ClipLink.State.idle
    var clipsNearby: [ClipLink.Found] = []   // clips heard while searching, for the medic to pick from
    var clipSignal: ClipLink.Signal?       // how strongly the connected clip is heard, refreshed every two seconds
    var clipReconnecting = false           // the link dropped mid-recording; the recording is held open while the clip comes back
    var clipSilent = false                 // recording from the clip, but no audio has arrived for a few seconds
    var live = Live.none

    var call = Call()                              // the call being worked on
    var review: [Call] = []                        // completed calls waiting for sign-off, newest first
    var past: [Call] = []                          // signed calls, newest first
    var liveLine: UUID?                            // the line still being spoken
    var levels = [Int](repeating: 0, count: 30)    // recent loudness, oldest first
    var problem: String?

    var recordLoading = true                       // the Whisper model is still being loaded, just after launch
    var recordBy: String?                          // the Whisper model writing the record, like "ems-small.en-ft-q5_0". Nil: live words only
    var playing: Item.ID?                          // the line being played back from the call's audio
    var filling: [Call.ID: Filling] = [:]          // calls whose report is being filled right now, and how far along
    @ObservationIgnored private let reporter = Reporter()
    /// The model that fills reports on this device. Nil: there is none.
    var reportBy: String? { reporter.name }
    @ObservationIgnored private let tape = Tape()
    @ObservationIgnored private let speaker = Speaker()
    @ObservationIgnored private let transcriber = Transcriber()
    @ObservationIgnored private let scribe = Record()
    @ObservationIgnored private var retired = Set<UUID>()             // live lines Whisper's have replaced; late words for them are dropped
    @ObservationIgnored private let link = ClipLink()
    @ObservationIgnored private var source = Transcriber.Source.mic   // where the current recording's audio comes from
    @ObservationIgnored private var viaClip = false                   // the current recording runs on the clip too, so stop and marks go to it
    @ObservationIgnored private var lastClipAudio = Date()
    @ObservationIgnored private var silenceTimer: Timer?
    @ObservationIgnored private var droppedAt = Date()                // when the link was lost, while clipReconnecting
    @ObservationIgnored private var dropTimer: Timer?
    @ObservationIgnored private var stopOwed = false                  // a stop could not reach the clip; send it when the clip is back
    @ObservationIgnored private var startAsked: Date?                 // when the clip was last told to start, until it answers

    init() {
        link.onState = { [weak self] state in self?.clipChanged(to: state) }
        link.onFound = { [weak self] clips in self?.clipsNearby = clips }
        link.onEvent = { [weak self] event in self?.clipSaid(event) }
        link.onProblem = { [weak self] message in self?.problem = message }
        link.onSignal = { [weak self] signal in self?.clipSignal = signal }
        link.onAudio = { [weak self] buffer in
            self?.lastClipAudio = Date()
            self?.transcriber.push(buffer)
        }
        link.onPacket = { [tape] opus, lost in tape.packet(opus, lost: lost) }
        tape.onTake = { [weak self] id, take in self?.taped(id, take) }
        speaker.onDone = { [weak self] in self?.playing = nil }
        transcriber.onLevel = { [weak self] level in
            self?.levels.removeFirst()
            self?.levels.append(level)
        }
        transcriber.onText = { [weak self] id, text in self?.heard(id, text) }
        transcriber.onCut = { [weak self] in
            self?.liveLine = nil
            self?.save()   // each finished line is on disk before the next one starts
        }
        transcriber.onAudio = { [scribe, tape] pcm in
            scribe.feed(pcm)
            tape.feed(pcm)
        }
        scribe.onLines = { [weak self] id, lines, heard in self?.recorded(id, lines, upTo: heard) }
        scribe.load { [weak self] in
            guard let self else { return }
            self.recordBy = self.scribe.name
            self.recordLoading = false
            self.transcriber.liveOptional = self.scribe.name != nil
        }
        transcriber.onProblem = { [weak self] message in
            self?.problem = "Transcription stopped. \(message)"
            self?.stop()
        }
        locator.onPlace = { [weak self] place, at in self?.addPlace(place, at: at) }
        locator.onLevel = { [weak self] level in self?.location = level }
        location = locator.level
        load()
        #if DEBUG
        seedSample()   // one made-up call with a full transcript, to try the report on (see Sample.swift)
        #endif
        link.resume()
        locator.ask()   // asked at first launch, before any call, so a recording never stops for the question
    }

    private func heard(_ id: UUID, _ text: String) {
        guard !retired.contains(id) else { return }   // Whisper has already written this stretch
        if id == transcriber.segment { liveLine = id }
        for r in call.recordings.indices {
            if let i = call.recordings[r].items.firstIndex(where: { $0.id == id }) {
                call.recordings[r].items[i].text = text
                call.recordings[r].items[i].end = Date()
                return
            }
        }
        if !call.recordings.isEmpty { call.recordings[call.recordings.count - 1].items.append(Item(id: id, text: text, end: Date())) }
    }

    /// A stretch of a call's audio has begun to be saved.
    private func taped(_ id: Call.ID, _ take: Take) {
        if id == call.id, live != .none {
            call.audio = (call.audio ?? []) + [take]
        } else if let i = review.firstIndex(where: { $0.id == id }) {
            review[i].audio = (review[i].audio ?? []) + [take]
        } else {
            return
        }
        save()
    }

    /// Plays a line of a call back from its audio. A second tap on the line stops it.
    func listen(to item: Item, in call: Call) {
        let again = playing == item.id
        hush()
        guard !again, let place = call.place(of: item) else { return }
        guard live != .listening else {
            problem = "Pause the recording to listen back."
            return
        }
        let samples = Tape.samples(of: Tape.url(of: place.take, in: call.id), from: place.from, to: place.to)
        guard !samples.isEmpty else {
            problem = "This line's audio could not be found."
            return
        }
        do {
            try speaker.play(samples)
            playing = item.id
        } catch {
            problem = "The audio could not be played. \(error.localizedDescription)"
        }
    }

    /// Stops any line being played back.
    func hush() {
        speaker.stop()
        playing = nil
    }

    /// Whisper has read more of a call: the open one, or one waiting for sign-off that it is still catching up on.
    private func recorded(_ id: Call.ID, _ lines: [Item], upTo heard: Date) {
        if id == call.id, live != .none {
            var open = call
            if Self.place(lines, upTo: heard, in: &open, speaking: live == .listening ? liveLine : nil, retiring: &retired) { call = open }
        } else if let i = review.firstIndex(where: { $0.id == id }) {
            var waiting = review[i]
            if Self.place(lines, upTo: heard, in: &waiting, speaking: nil, retiring: &retired) { review[i] = waiting }
        }
        if !lines.isEmpty { save() }
    }

    /// How long after a word is said the live recogniser shows it. A live line's times run that much late, so it is
    /// matched against Whisper's lines that much earlier.
    static let liveLag: TimeInterval = 1.5

    /// Puts Whisper's new lines into a call, and settles the live lines Whisper has now got past.
    ///
    /// A live line is left alone until Whisper has read the audio up to its end. Then, if Whisper wrote something
    /// for that stretch of time, the live line goes and Whisper's stands. If Whisper wrote nothing there, the live
    /// line stays, marked as heard by the live recogniser only, with a confidence of 0: nothing heard is dropped.
    /// One of Whisper's lines is cut in two where a mark or a place was logged in the middle of it, so those stay
    /// between the words they came between. Returns whether the call changed.
    static func place(_ lines: [Item], upTo heard: Date, in call: inout Call, speaking: UUID?, retiring retired: inout Set<UUID>) -> Bool {
        guard let r = call.recordings.lastIndex(where: { $0.start <= (lines.first?.time ?? heard) }) ?? call.recordings.indices.last else { return false }
        var items = call.recordings[r].items, changed = !lines.isEmpty
        let cuts = items.filter { $0.mark != nil || $0.place != nil }.map(\.time)
        items += lines.flatMap { cut($0, at: cuts) }
        let written = items.filter { $0.source == .whisper }
        items.removeAll { item in
            guard item.mark == nil, item.place == nil, item.source != .whisper, !item.text.isEmpty, item.id != speaking else { return false }
            let end = item.end ?? item.time
            guard item.source == .apple || end.addingTimeInterval(-liveLag) <= heard else { return false }   // not reached yet
            guard written.contains(where: { $0.time <= end && ($0.end ?? $0.time) >= item.time.addingTimeInterval(-liveLag) }) else { return false }
            retired.insert(item.id)
            changed = true
            return true
        }
        for i in items.indices where items[i].source == nil && items[i].mark == nil && items[i].place == nil && !items[i].text.isEmpty && items[i].id != speaking {
            guard (items[i].end ?? items[i].time).addingTimeInterval(-liveLag) <= heard else { continue }
            items[i].source = .apple
            items[i].confidence = 0
            changed = true
        }
        guard changed else { return false }
        call.recordings[r].items = items.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        return true
    }

    /// One of Whisper's lines, cut wherever one of `times` falls between two of its words.
    static func cut(_ line: Item, at times: [Date]) -> [Item] {
        guard let words = line.words, words.count > 1 else { return [line] }
        let starts = [0] + words.indices.dropFirst().filter { i in times.contains { $0 > words[i - 1].time && $0 <= words[i].time } }
        guard starts.count > 1 else { return [line] }
        let text = Array(line.text)
        return starts.enumerated().map { n, from in
            let to = n + 1 < starts.count ? starts[n + 1] : words.count
            let part = words[from..<to], offset = words[from].offset
            let until = to < words.count ? words[to].offset : text.count
            return Item(time: words[from].time, text: String(text[offset..<until]).trimmingCharacters(in: .whitespaces),
                        end: to < words.count ? words[to].time : line.end, source: .whisper,
                        confidence: (part.map(\.confidence).reduce(0, +) / Double(part.count) * 1000).rounded() / 1000,
                        words: part.map { Item.Word(offset: $0.offset - offset, time: $0.time, confidence: $0.confidence) })
        }
    }

    /// Whisper has read the whole call: any live line it never took up is marked as heard by the live recogniser only.
    static func settle(_ call: inout Call) {
        guard call.whisper == true else { return }
        for r in call.recordings.indices {
            for i in call.recordings[r].items.indices where call.recordings[r].items[i].source == nil
                && call.recordings[r].items[i].mark == nil && call.recordings[r].items[i].place == nil && !call.recordings[r].items[i].text.isEmpty {
                call.recordings[r].items[i].source = .apple
                call.recordings[r].items[i].confidence = 0
            }
        }
    }

    // MARK: The call

    func newCall() {
        locator.reset()
        call = Call()
        problem = nil
        live = .ready
        tab = .live
        save()
    }

    func record() {
        Task { @MainActor in
            problem = await Transcriber.authorize(microphone: audioSource == .mic, liveOptional: recordBy != nil)
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
    var audioSource: Transcriber.Source { clip && !micStandIn ? .clip : .mic }

    /// The audio source in words, for the screen: the running recording's, or the next one's.
    var audioLabel: String { (live == .listening ? source : audioSource) == .clip ? "Clip audio" : "\(deviceName) mic" }

    private func begin(from source: Transcriber.Source, viaClip: Bool) {
        guard live != .listening, live != .none else { return }
        do {
            hush()
            try transcriber.start(from: source)
            scribe.begin(for: call.id)
            tape.begin(for: call.id, from: source)
            if recordBy != nil { call.whisper = true }
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
        transcriber.stop()
        scribe.end()
        tape.end()
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
        addMark()
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
        transcriber.stop()   // the line being spoken closes; the next words start a new one
        scribe.end()
        tape.end()
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
            try transcriber.start(from: .clip)
            scribe.begin(for: call.id)
            tape.begin(for: call.id, from: .clip)
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
            if live == .listening { addMark() }
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
            problem = await Transcriber.authorize(microphone: source == .mic)
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
    /// it is checked and signed once Whisper has read it to the end. The Live Call tab is free for a new call straight away.
    func complete(show: Bool = true) {
        stop()
        guard live != .none else { return }
        guard !call.recordings.isEmpty else {   // nothing was recorded, so there is nothing to report on
            discard()
            return
        }
        var done = call
        done.drafted = false
        review.insert(done, at: 0)
        call = Call()
        live = .none
        problem = nil   // any recording trouble belonged to the call that just ended
        if show { tab = .drafts }
        save()
        finishUp(done.id)
    }

    /// Waits for Whisper to read a completed call to its end, fills its report from the transcript, then marks it
    /// ready to sign. Until then the call says what it is waiting for.
    func finishUp(_ id: Call.ID) {
        Task { @MainActor in
            await scribe.finished(id)
            guard let i = review.firstIndex(where: { $0.id == id }) else { return }   // removed meanwhile
            Self.settle(&review[i])
            save()
            await fill(id)
            guard let i = review.firstIndex(where: { $0.id == id }) else { return }
            review[i].drafted = true
            save()
        }
    }

    /// Fills a waiting call's report from its transcript. Takes a minute or two. If it cannot be done the call
    /// says why, and the report is left for the medic to fill in.
    @MainActor func fill(_ id: Call.ID) async {
        guard filling[id] == nil, let call = review.first(where: { $0.id == id }) else { return }
        let lines = call.spoken
        func note(_ why: String) { if let i = review.firstIndex(where: { $0.id == id }) { review[i].fillNote = why } }
        guard !lines.isEmpty else { return note("Nothing was said on this call, so there was nothing to fill the report from.") }
        filling[id] = Filling()
        defer { filling[id] = nil }
        do {
            let heard = lines.map { Heard($0.text, clock: stamp($0.time), seconds: $0.time.timeIntervalSinceReferenceDate, unsure: $0.unsure) }
            let filled = try await reporter.fill(heard) { [weak self] step, of in self?.filling[id] = Filling(step: step, of: of) }
            guard let i = review.firstIndex(where: { $0.id == id }) else { return }
            review[i].take(filled, from: lines, by: reporter.name)
        } catch {
            note(error.localizedDescription)
        }
        save()
    }

    /// The medic typed an answer into a call's report. An emptied answer is forgotten. Saved when the report closes.
    func answer(_ element: String, _ value: String, in id: Call.ID) {
        guard let i = review.firstIndex(where: { $0.id == id }) else { return }
        var report = review[i].report ?? [:]
        report[element] = value.isEmpty ? nil : value
        review[i].report = report
        review[i].evidence?[element] = nil   // it is the medic's answer now
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
    /// that was not meant.
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
        hush()
        Tape.erase(call.id)
        call = Call()
        problem = nil
        live = .none
        save()
    }

    func delete(at offsets: IndexSet) {
        hush()
        for i in offsets { Tape.erase(past[i].id) }
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
            Tape.keep(only: Set((past + review).map(\.id) + [call.id]))
            // A call whose transcript was still being finished when the app closed is taken up again.
            for waiting in review where !waiting.drafted { finishUp(waiting.id) }
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
        // Call audio: two seconds of a tone, saved as an .opus file with a lost packet in it, comes back packet for
        // packet, and half a second asked for from the middle is half a second of samples.
        let pcm = AVAudioFormat(opusPCMFormat: .int16, sampleRate: 16000, channels: 1)!
        let scratch = URL.temporaryDirectory.appending(path: "selfcheck.opus")
        FileManager.default.createFile(atPath: scratch.path, contents: nil)
        if let encoder = try? Opus.Encoder(format: pcm, application: .voip), let handle = try? FileHandle(forWritingTo: scratch),
           let writer = try? OggOpus.Writer(handle), let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 320) {
            buffer.frameLength = 320
            var wrote: [Data] = []
            for n in 0..<100 {
                for i in 0..<320 { buffer.int16ChannelData?[0][i] = Int16(8000 * sin(Double(n * 320 + i) * 0.17)) }
                var bytes = [UInt8](repeating: 0, count: 1275)
                let size = (try? encoder.encode(buffer, to: &bytes)) ?? 0
                wrote.append(n == 40 ? OggOpus.gap(like: Data(bytes[0..<size])) : Data(bytes[0..<size]))
                try? writer.add(wrote[n])
            }
            try? writer.close()
            assert((try? Data(contentsOf: scratch)).map(OggOpus.packets) == wrote)
            assert(wrote.allSatisfy { OggOpus.length(of: $0) == 960 } && wrote[40].count == 1)
            assert(Tape.samples(of: scratch, from: 0.5, to: 1).count == 8000 && Tape.samples(of: scratch, from: 1.9, to: 5).count == 1600)
            assert(Tape.samples(of: scratch, from: 3, to: 4).isEmpty)
        } else {
            assertionFailure("the call audio check could not start")
        }
        try? FileManager.default.removeItem(at: scratch)
        var taped = Call()
        taped.audio = [Take(file: "a.opus", start: t), Take(file: "b.opus", start: t.addingTimeInterval(60))]
        let late = taped.place(of: Item(time: t.addingTimeInterval(70), text: "x", end: t.addingTimeInterval(72), source: .whisper))
        assert(late?.take.file == "b.opus" && abs((late?.from ?? 0) - 9.7) < 0.001 && abs((late?.to ?? 0) - 12.4) < 0.001)
        assert(taped.place(of: Item(time: t.addingTimeInterval(1), text: "x"))?.from == 0 && taped.place(of: Item(time: t, mark: 1)) == nil)
        assert(Call().place(of: Item(time: t, text: "x")) == nil)
        var call = Call()
        call.markNotes = [2: "Moved to stretcher"]
        call.signature = .typed("A. Medic")
        call.recordings = [Recording(items: [
            Item(time: t, text: "BP 120 over 80"), Item(time: t.addingTimeInterval(5), mark: 1), Item(time: t.addingTimeInterval(90), mark: 2),
        ])]
        assert(call.markCount == 2 && call.transcript.contains("] BP 120 over 80\n[") && call.transcript.hasSuffix("MARK 2"))
        assert(span(59) == "59 sec" && span(125) == "2 min" && plural(1, "mark") == "1 mark" && plural(2, "mark") == "2 marks")
        // A call must survive being written to disk and read back.
        let copy = try? JSONDecoder().decode(Call.self, from: JSONEncoder().encode(call))
        assert(copy?.id == call.id && copy?.transcript == call.transcript && copy?.markNotes[2] == "Moved to stretcher")
        if case .typed("A. Medic")? = copy?.signature {} else { assertionFailure("the signature was lost on disk") }
        // The NEMSIS record: every element is listed once, an answer survives being saved, and a call is named from it.
        assert(Set(Nemsis.sections.flatMap(\.fields).map(\.id)).count == Nemsis.fieldCount && Nemsis.sections.allSatisfy { s in s.fields.allSatisfy { $0.id.hasPrefix(s.id + ".") } })
        call.report = ["ePatient.15": "68", "ePatient.25": "Male", "eVitals.06": " ", "eVitals.10#2": "96"]
        call.evidence = ["ePatient.15": Evidence(line: UUID(), check: true, other: "86")]
        let reported = try? JSONDecoder().decode(Call.self, from: JSONEncoder().encode(call))
        assert(reported?.report?["ePatient.15"] == "68" && copy?.report == nil)
        assert(call.xml(Standing()).flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.contains("<ePatient.15>68</ePatient.15>") == true)
        assert(reported?.evidence?["ePatient.15"]?.other == "86" && Nemsis.sets(of: Nemsis.sections[5], in: call.report ?? [:]) == 2)
        assert(Nemsis.filled(call.report ?? [:]) == 3 && Nemsis.title(of: call.report ?? [:]) == "68 years, Male" && Nemsis.title(of: [:]) == nil)
        // A call saved by a build that wrote nurse and PCR drafts still opens.
        if var old = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(call)) as? [String: Any] {
            old["draft"] = ["patient": "x", "narrative": "y"]
            old["format"] = "soap"
            assert((try? JSONDecoder().decode(Call.self, from: JSONSerialization.data(withJSONObject: old)))?.id == call.id)
        }
        // The clip's messages must be readable exactly as firmware/BLUETOOTH.md gives them.
        // The level meter: silence and a quiet room show nothing, quiet speech still moves it, and louder never reads lower.
        func tone(_ amplitude: Float) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!, frameCapacity: 4096)!
            buffer.frameLength = 4096
            for i in 0..<4096 { buffer.floatChannelData![0][i] = amplitude * sin(Float(i) * 0.3) }
            return buffer
        }
        let heard = [0, 0.0005, 0.002, 0.01, 0.03, 0.1, 0.4].map { Transcriber.level(of: tone($0)) }
        assert(heard[2] == 0 && heard[3] >= 3 && heard[5] == 6 && heard == heard.sorted(), "the level meter is off: \(heard)")
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

        // Location: under 50 metres from the last reported place is the same place; a location row is part of the call's text.
        let here = CLLocation(latitude: 42.3398, longitude: -71.0892)
        assert(Locator.isNew(here, since: nil) && !Locator.isNew(CLLocation(latitude: 42.3400, longitude: -71.0892), since: here))
        assert(Locator.isNew(CLLocation(latitude: 42.3410, longitude: -71.0892), since: here))
        var located = Call()
        located.recordings = [Recording(items: [Item(place: Place(latitude: 42.3398, longitude: -71.0892, accuracy: 8, street: "360 Huntington Ave", city: "Boston", state: "MA", zip: "02115"))])]
        assert(located.transcript.contains("LOCATION 360 Huntington Ave, Boston, MA 02115 (42.33980, -71.08920)"))
        // Whisper's lines take the place of live words once it has read past them. Live words it wrote nothing for stay,
        // marked; the line being spoken and lines it has not reached are left alone; a mark stays between its words.
        func line(_ from: Double, _ to: Double, _ text: String) -> Item {
            var at = 0
            let words = text.split(separator: " ").enumerated().map { n, w -> Item.Word in
                defer { at += w.count + 1 }
                return Item.Word(offset: at, time: t.addingTimeInterval(from + Double(n)), confidence: n == 0 ? 0.4 : 0.8)
            }
            return Item(time: t.addingTimeInterval(from), text: text, end: t.addingTimeInterval(to), source: .whisper, confidence: 0.7, words: words)
        }
        let early = Item(time: t.addingTimeInterval(1), text: "bp one twenty", end: t.addingTimeInterval(3))
        let missed = Item(time: t.addingTimeInterval(8), text: "no allergies", end: t.addingTimeInterval(9))
        let ahead = Item(time: t.addingTimeInterval(20), text: "not yet read", end: t.addingTimeInterval(22))
        let speaking = Item(time: t.addingTimeInterval(5), text: "still talking", end: t.addingTimeInterval(6))
        var talk = Call()
        talk.whisper = true
        talk.recordings = [Recording(start: t, items: [early, Item(time: t.addingTimeInterval(1.5), mark: 1), speaking, missed, ahead])]
        var gone = Set<UUID>()
        assert(place([line(0, 3, "BP 120 over 80.")], upTo: t.addingTimeInterval(12), in: &talk, speaking: speaking.id, retiring: &gone))
        let rows = talk.recordings[0].items
        assert(rows.map(\.text) == ["BP 120", "", "over 80.", "still talking", "no allergies", "not yet read"], "the record was placed wrongly: \(rows.map(\.text))")
        assert(gone == [early.id] && rows[0].words?.count == 2 && rows[2].words?.first?.offset == 0 && rows[0].confidence == 0.6)
        assert(rows[4].source == .apple && rows[4].confidence == 0 && rows[4].unsure && rows[5].source == nil && rows[3].source == nil)
        assert(!rows[2].unsure && line(0, 1, "x").unsure == false && Item(text: "old call").unsure == false)
        // A line Whisper writes later for a stretch first thought missed takes the live line's place after all.
        assert(place([line(7.5, 9, "No known allergies.")], upTo: t.addingTimeInterval(13), in: &talk, speaking: nil, retiring: &gone))
        assert(talk.recordings[0].items.map(\.text) == ["BP 120", "", "over 80.", "still talking", "No known allergies.", "not yet read"] && gone.contains(missed.id))
        assert(!place([], upTo: t.addingTimeInterval(13), in: &talk, speaking: nil, retiring: &gone))   // nothing new: the call is not touched
        settle(&talk)
        assert(talk.recordings[0].items.filter { $0.source == .apple }.map(\.text) == ["still talking", "not yet read"])
        let kept = try? JSONDecoder().decode(Call.self, from: JSONEncoder().encode(talk))
        assert(kept?.recordings[0].items[0].source == .whisper && kept?.recordings[0].items[0].words?.count == 2 && kept?.whisper == true)
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
                                Text("Its recordings will be deleted. This cannot be undone.")
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
                                HStack(spacing: 10) {
                                    Text(model.clipStatus).font(geist(17, 500)).foregroundStyle(Color.dim)
                                    if model.clipState == .searching || model.clipState == .connecting { Working(color: .dim) }
                                }
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
    /// left goes to the most recent signed calls. The rest are on the Reports tab.
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
            HStack(spacing: 10) {
                Text(model.clipState == .searching ? "Looking for clips nearby" : model.clipStatus).font(geist(18, 500)).foregroundStyle(Color.dim)
                if model.clipState == .searching || model.clipState == .connecting { Working(color: .dim) }
            }
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
