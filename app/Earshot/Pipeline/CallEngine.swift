import AVFoundation
import EarshotCore

/// The paperwork the medic reviews. Filled from the pipeline's record; the narrative and scene lines
/// come from a language model only when one is available. Empty means "not heard".
struct Draft: Codable {
    var patient = ""
    var latestVitals = ""
    var given = ""
    var allergies = ""
    var dispatchAndScene = ""
    var vitalsByTime: [String] = []
    var narrative = ""
    var treatmentByTime: [String] = []

    static let blank = Draft()
}

/// A line of the record (Whisper), for the screen.
struct RecordLine {
    var start: Date
    var end: Date
    var text: String
    /// When each word was said: its place in `text` (a character offset) and the time. Empty when the
    /// recogniser gave no word times; times inside the line are then spread evenly along it.
    var words: [Word] = []
    struct Word { var offset: Int; var time: Date }
}

/// What finishing a call produces.
struct CallOutput {
    var draft: Draft
    /// Rendered documents by file name: soap.md, chart.md, imist_ambo.md, nemsis.xml.
    var docs: [String: String]
    /// Things the medic should look at: items to confirm, sentences the writer was not allowed to keep.
    var notes: [String]
}

/// Runs calls through the pipeline (core/, EarshotCore):
///
///   clip audio (ClipLink, decoded there) or the microphone
///     ├─► live recogniser (Apple, optional) ─► words on screen + second opinion
///     └─► LiveSession: Whisper ─► rules ─► events ─► chart, SOAP, NEMSIS
///                                    ▲ cross-check: where the two recognisers disagree on a drug,
///                                      dose or vital, the event is "please confirm"
///   finish ─► Draft from the events, plus an optional NoteWriter for prose, held to the transcript
///
/// The app (Model) decides when a recording starts, pauses, resumes and is marked, and talks to the
/// clip; this only transcribes. Each call has its own session, so a completed call can finish
/// drafting while the next one records.
final class CallEngine {
    enum Source { case mic, clip }

    // Callbacks, always on the main queue.
    var onLevel: (Int) -> Void = { _ in }
    var onLiveText: (UUID, String) -> Void = { _, _ in }
    var onCut: () -> Void = {}
    var onRecord: (UUID, [RecordLine]) -> Void = { _, _ in }   // a call's record so far, by call id
    var onProblem: (String) -> Void = { _ in }                 // listening cannot continue

    /// The live line being spoken.
    var segment: UUID { live.segment }
    /// Set when no recogniser could load: the record cannot be written, only live words.
    private(set) var recordProblem: String?
    /// Which recogniser writes the record, once chosen (see RecognizerSelector).
    private(set) var recordKind: RecognizerKind?
    /// Its name, for the Clip tab: "ggml-small.en", "apple-speech". Nil until a call has begun.
    private(set) var recordName: String?
    /// Whether Whisper may write the record. Off, the iPad's own recogniser does, so the two can be
    /// compared on the same build. Takes effect on the next call; a call in progress keeps its recogniser.
    var whisperEnabled = true

    private let dict: EMSDictionary?
    private var recorder: Transcriber?           // the record's recogniser: chosen and loaded once, shared by every call's session
    private var recorderUsesWhisperSetting: Bool? // the `whisperEnabled` it was chosen under; a change means choosing again
    private var sessions: [UUID: (session: LiveSession, start: Date)] = [:]
    private var broughtBack: Set<UUID> = []      // calls whose record was read back from disk after the app closed
    private var closed: Set<UUID> = []           // calls drafted or thrown away: their record is no longer written
    private var saveWaiting: Set<UUID> = []      // calls with a record write due within the second
    private var current: UUID?                   // the call being recorded
    private var source: Source?                  // set while audio is being taken
    private let live = LiveRecognizer()
    private let mic = MicInput()
    private let pcmDecoder = PCMFrameDecoder()

    // The pipeline's clock for this device's audio. Touched only on `audioQueue`.
    private let audioQueue = DispatchQueue(label: "earshot.audio")
    private var seq: UInt32 = 0
    private var clipMs: UInt32 = 0               // where the next 20 ms frame starts
    private var carry: [Int16] = []
    private let boot = Date()
    private var levelFrames = 0, levelPeak = 0   // clip audio: loudness about twelve times a second, as the mic does

    init() {
        dict = EMSDictionary.bundled()
        if dict == nil { recordProblem = "The EMS dictionary is missing from the app." }
        live.vocabulary = dict?.liveVocabulary() ?? []
        live.onText = { [weak self] id, text, started in
            guard let self else { return }
            self.onLiveText(id, text)
            // Live words are a second opinion only when a different recogniser writes the record;
            // Apple's recogniser checking itself would agree with its own mistakes.
            if self.recordKind != .appleOnDevice {
                self.session?.liveLine(id: id.uuidString, text: text, start: started, end: Date())
            }
        }
        live.onCut = { [weak self] in self?.onCut() }
        mic.onBuffer = { [weak self] b in self?.live.append(b) }
        mic.onFrame = { [weak self] pcm in self?.audioQueue.async { self?.frame(pcm) } }
        mic.onLevel = { [weak self] l in self?.onLevel(l) }
        mic.onResumed = { [weak self] in self?.live.cut() }
        mic.onProblem = { [weak self] message in self?.onProblem(message) }
    }

    private var session: LiveSession? { current.flatMap { sessions[$0]?.session } }

    /// Asks for speech access, and for the microphone unless the audio comes from the clip.
    /// Live words are optional, so refusing speech recognition only turns them off. Returns what to
    /// tell the user if the microphone is refused.
    static func authorize(microphone: Bool) async -> String? {
        await LiveRecognizer.requestAuthorization()
        return microphone ? await MicInput.authorize() : nil
    }

    // MARK: The call

    /// Opens a call's session. The record's recogniser is chosen and loaded once, and kept for later calls
    /// until the Whisper setting changes. Sessions of earlier calls keep the recogniser they began with.
    func beginCall(_ id: UUID, at start: Date) {
        current = id
        guard sessions[id] == nil, let dict else { return }
        if recorder == nil || recorderUsesWhisperSetting != whisperEnabled {
            let choice = Self.chooseRecognizer(&recordProblem, dict: dict, whisper: whisperEnabled)
            recorder = choice.map { SerialTranscriber($0.transcriber) }
            recordKind = choice?.kind
            recordName = choice?.name
            recorderUsesWhisperSetting = whisperEnabled
        }
        let s = LiveSession(dict: dict, config: PipelineConfig(), callId: "c\(Int(start.timeIntervalSince1970))",
                            startEpochMs: Int64(start.timeIntervalSince1970 * 1000), tzOffsetSeconds: TimeZone.current.secondsFromGMT(),
                            transcriber: recorder)
        s.callbackQueue = .main
        s.onSegments = { [weak self] segs in
            self?.onRecord(id, segs.map { seg in
                RecordLine(start: start.addingTimeInterval(Double(seg.startMs) / 1000), end: start.addingTimeInterval(Double(seg.endMs) / 1000), text: seg.text,
                           words: (seg.wordTimes ?? []).filter { $0.count == 2 }
                               .map { RecordLine.Word(offset: Int($0[0]), time: start.addingTimeInterval(Double($0[1]) / 1000)) })
            })
        }
        // The record is written to disk as it changes, so it is still there if the app closes.
        s.onEvents = { [weak self] _ in self?.saveSoon(id) }
        // A call that was open when the app last closed carries on from the record it had.
        if let kept = RecordStore.load(id) {
            s.restore(kept)
            broughtBack.insert(id)
        }
        sessions[id] = (s, start)
    }

    /// The session of a call that was waiting to be drafted when the app closed, rebuilt from its
    /// saved record. It has no recogniser: nothing more will be said on it.
    private func sessionFromDisk(_ id: UUID) -> LiveSession? {
        guard let dict, let kept = RecordStore.load(id) else { return nil }
        let s = LiveSession(dict: dict, config: PipelineConfig(), callId: kept.callId, startEpochMs: kept.startEpochMs,
                            tzOffsetSeconds: kept.tzOffsetSeconds, transcriber: nil)
        s.callbackQueue = .main
        s.restore(kept)
        broughtBack.insert(id)
        return s
    }

    /// Writes a call's record within a second. Events change many times a second while someone is
    /// speaking (every live word), so changes are gathered into one write.
    private func saveSoon(_ id: UUID) {
        guard !closed.contains(id), saveWaiting.insert(id).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.saveWaiting.remove(id)
            self.saveNow(id)
        }
    }

    private func saveNow(_ id: UUID) {
        guard !closed.contains(id), let s = sessions[id]?.session else { return }
        RecordStore.save(s.saved(), for: id)
    }

    /// Writes every open record at once: the app is leaving the screen and may not come back.
    func saveRecords() { for id in sessions.keys { saveNow(id) } }

    /// Deletes saved records that belong to no call still open or waiting for sign-off.
    func forgetRecords(except keep: Set<UUID>) { RecordStore.prune(keeping: keep) }

    /// Starts taking audio for the current call: from the microphone here, or from the clip through `push`.
    func start(from source: Source) throws {
        guard self.source == nil else { return }
        if source == .mic { try mic.start() }
        self.source = source
        let s = session
        let t = Self.ms(since: boot)
        audioQueue.sync {
            clipMs = max(clipMs, t)   // a new capture picks up the clock where the wall is, never going back
            seq = 0
            carry = []
            s?.handle(.consent(granted: true, source: "tablet", clipMs: Int64(clipMs)), decoder: pcmDecoder)
        }
        live.start()
    }

    /// Audio from the clip (16 kHz mono float, in the order it was captured). Ignored unless taking clip audio.
    func push(_ buffer: AVAudioPCMBuffer) {
        guard source == .clip, let ch = buffer.floatChannelData else { return }
        live.append(buffer)
        let pcm = (0..<Int(buffer.frameLength)).map { Int16(max(-1, min(1, ch[0][$0])) * 32767) }
        audioQueue.async { self.frame(pcm) }
        levelFrames += pcm.count
        levelPeak = max(levelPeak, Audio.level(pcm))
        if levelFrames >= 1280 {
            onLevel(levelPeak)
            levelFrames = 0
            levelPeak = 0
        }
    }

    /// Stops taking audio. What was heard is still transcribed.
    func stop() {
        guard let was = source else { return }
        source = nil
        if was == .mic { mic.stop() }
        let s = session
        audioQueue.async { s?.handle(.consent(granted: false, source: "tablet", clipMs: Int64(self.clipMs)), decoder: self.pcmDecoder) }
        live.stop()
    }

    /// Closes the line being spoken, so that what comes next lands after it.
    func cut() { live.cut() }

    /// A mark, from the app or the clip's button, at the audio heard so far.
    func mark(fromClip: Bool) {
        live.cut()
        let s = session
        audioQueue.async {
            s?.handle(.marker(id: 0, source: fromClip ? "button" : "tablet", clipMs: Int64(self.clipMs), audioSeq: -1), decoder: self.pcmDecoder)
        }
    }

    /// Waits for Whisper to catch up on a completed call, then drafts its paperwork from the record.
    /// The call's session is let go: its audio and working record are wiped once this returns.
    @MainActor func finish(_ id: UUID) async -> CallOutput {
        if id == current { stop(); current = nil }
        guard let s = sessions.removeValue(forKey: id)?.session ?? sessionFromDisk(id) else {
            return CallOutput(draft: .blank, docs: [:], notes: [recordProblem
                ?? "No record of this call was found on this \(deviceName), so nothing was drafted. Fill in the lines yourself."])
        }
        await withCheckedContinuation { done in audioQueue.async { done.resume() } }   // audio already queued reaches the session
        s.endCapture()
        await Task.detached { s.drain() }.value
        RecordStore.save(s.saved(), for: id)   // everything said is now written down: keep it in case drafting is cut off
        // Once drafted, the paperwork is on the call itself: the working record is wiped, on disk too.
        defer { closed.insert(id); broughtBack.remove(id); s.wipe(); RecordStore.delete(id) }
        var notes: [String] = []
        if let p = recordProblem { notes.append(p) }
        if broughtBack.contains(id) {
            notes.append("The app was closed during this call. Anything said just before it closed may be missing from the record.")
        }

        let chart = s.chartModel()
        var draft = Self.draft(from: chart)

        if let writer = NoteWriters.available(), !s.rawSegments.isEmpty {
            do {
                let written = try await writer.write(transcript: s.transcriptText, record: Self.recordSummary(chart))
                let results = s.addSuggestions(written.suggestions.map { AISuggestion(field: $0.field, value: $0.value, quote: $0.quote) })
                let kept = results.filter(\.accepted).count
                if kept > 0 { notes.append("\(kept) value(s) suggested by the \(writer.name): please confirm.") }
                let n = s.checkNarrative(written.narrative)
                draft.narrative = n.kept
                if !n.dropped.isEmpty { notes.append("Left out of the narrative because the record does not support them: " + n.dropped.joined(separator: " ")) }
                let scene = s.checkNarrative(written.dispatchAndScene)
                if draft.dispatchAndScene.isEmpty { draft.dispatchAndScene = scene.kept }
            } catch {
                notes.append("The narrative was not written (\(error.localizedDescription)). Everything else is from the record.")
            }
            draft = Self.draft(from: s.chartModel(), keeping: draft)   // accepted suggestions now in the record
        }
        let confirm = s.chartModel().confirmItems.count
        if confirm > 0 { notes.insert("\(confirm) item(s) need you to confirm them.", at: 0) }
        var docs: [String: String] = [:]
        for d in s.render() { docs[d.name] = d.text }
        return CallOutput(draft: draft, docs: docs, notes: notes)
    }

    /// Throws a call away: its audio and working record are wiped.
    func discard(_ id: UUID) {
        if id == current { stop(); current = nil }
        closed.insert(id); broughtBack.remove(id)
        sessions.removeValue(forKey: id)?.session.wipe()
        RecordStore.delete(id)
    }

    // MARK: Helpers

    /// One stretch of 16 kHz int16 audio, cut into the 20 ms frames the pipeline takes. On `audioQueue`.
    private func frame(_ pcm: [Int16]) {
        carry += pcm
        let s = session
        while carry.count >= 320 {
            s?.handleDecodedAudio(seq: seq, clipMs: clipMs, pcm: Array(carry.prefix(320)))
            carry.removeFirst(320)
            seq &+= 1
            clipMs &+= 20
        }
    }

    private static func ms(since d: Date) -> UInt32 { UInt32(max(0, Date().timeIntervalSince(d) * 1000)) }

    /// Every recogniser this app can offer, in no particular order; `RecognizerPolicy.rank` orders them.
    /// The first that can run on this tablet and loads writes the record.
    private static func chooseRecognizer(_ problem: inout String?, dict: EMSDictionary, whisper: Bool) -> RecognizerChoice? {
        let asr = PipelineConfig().asr
        let threads = ProcessInfo.processInfo.activeProcessorCount > 4 ? 4 : 2
        func model(_ file: String, _ kind: RecognizerKind) -> RecognizerOption {
            RecognizerOption(kind: kind, name: file,
                             unavailableReason: { ModelFiles.find(file, ext: "bin") == nil ? "no \(file).bin installed" : nil },
                             make: {
                let t = try WhisperTranscriber(modelPath: ModelFiles.find(file, ext: "bin")!.path, threads: threads)
                // lean toward the formulary's drug names while decoding (BiasTrie)
                if asr.bias { t.setBias(phrases: dict.biasPhrases(), firstBonus: asr.biasFirst, nextBonus: asr.biasNext) }
                return t
            })
        }
        let options: [RecognizerOption] = [
            RecognizerOption(kind: .appleOnDevice, name: "apple-speech",
                             unavailableReason: { AppleTranscriber.unavailableReason() },
                             make: {
                let t = try AppleTranscriber()
                t.vocabulary = dict.liveVocabulary()
                return t
            }),
            model("whisper-ems-small.en-q5", .whisperFineTuned),
            model("ggml-small.en", .whisperStock),
            model("ggml-base.en", .whisperStock),
            model("ggml-tiny.en", .whisperStock),
        ]
        do {
            let choice = try RecognizerSelector.choose(from: options, whisper: whisper)
            problem = nil
            return choice
        } catch {
            problem = "No speech recogniser can run, so nothing said is written to the record (\(error.localizedDescription)). "
                + "Allow speech recognition, run app/scripts/fetch_deps.sh, or copy ggml-small.en.bin into the app's Documents folder."
            return nil
        }
    }

    // MARK: Draft from the record

    static func draft(from m: ChartModel, keeping old: Draft = .blank) -> Draft {
        func hhmm(_ e: EarshotEvent) -> String { String(m.clock.clock(e.tMs).prefix(5)) }
        func confirm(_ e: EarshotEvent) -> String { e.needsConfirm ? " (please confirm)" : "" }
        func med(_ e: EarshotEvent) -> String {
            let f = e.fields
            return [f["drug"], f["dose"].map { $0 + (f["unit"].map { " " + $0 } ?? "") }, f["route"]].compactMap { $0 }.joined(separator: " ") + confirm(e)
        }
        var d = old
        let patient = [m.age.map { $0.text + " y/o" }, m.sex?.text, (m.chiefComplaint ?? m.found)?.text ?? m.symptoms.first?.text].compactMap { $0 }
        d.patient = patient.joined(separator: ", ")
        if let v = m.vitals.last { d.latestVitals = ChartModel.vitalsLine(v) + confirm(v) } else { d.latestVitals = "" }
        d.given = m.meds.map(med).joined(separator: "; ")
        d.allergies = m.allergies.map { $0.text + ($0.flags.contains("confirm") ? " (please confirm)" : "") }.joined(separator: ", ")
        d.vitalsByTime = m.vitals.map { "\(hhmm($0)) \(ChartModel.vitalsLine($0))\(confirm($0))" }
        d.treatmentByTime = (m.meds.map { "\(hhmm($0)) \(med($0))" }
            + m.procedures.map { "\(hhmm($0)) \($0.fields["procedure"] ?? "procedure")\(confirm($0))" }).sorted()
        let scene = [m.dispatch.map { "Dispatched for \($0.text)." }, m.found.map { "Found: \($0.text)." }].compactMap { $0 }
        if !scene.isEmpty { d.dispatchAndScene = scene.joined(separator: " ") }
        return d
    }

    /// The record as short facts, for the writer to read (so it does not repeat or contradict it).
    static func recordSummary(_ m: ChartModel) -> String {
        var lines: [String] = []
        for v in m.vitals { lines.append("\(m.clock.clock(v.tMs)) vitals: \(ChartModel.vitalsLine(v))") }
        for e in m.meds { lines.append(ChartModel.medLine(e, clock: m.clock)) }
        for a in m.allergies { lines.append("allergy: \(a.text)") }
        return lines.isEmpty ? "(nothing yet)" : lines.joined(separator: "\n")
    }
}

/// Each open call's record on disk (Application Support/records/<call id>.json): what Whisper wrote
/// and the marks, never audio. Calls hold patient information, so the files are encrypted, kept out
/// of iCloud backups, and deleted as soon as the call is drafted or thrown away. Like calls.json they
/// stay writable while the device is locked, since a recording carries on then.
enum RecordStore {
    private static let folder = URL.applicationSupportDirectory.appending(path: "records")
    private static func file(_ id: UUID) -> URL { folder.appending(path: "\(id.uuidString).json") }

    static func save(_ record: SessionRecord, for id: UUID) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: file(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var url = file(id), values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            // The call itself is still saved in calls.json; only carrying on after a restart is lost.
        }
    }

    static func load(_ id: UUID) -> SessionRecord? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? JSONDecoder().decode(SessionRecord.self, from: data)
    }

    static func delete(_ id: UUID) { try? FileManager.default.removeItem(at: file(id)) }

    static func prune(keeping keep: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for f in files where !keep.contains(where: { $0.uuidString == f.deletingPathExtension().lastPathComponent }) {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

/// Model files: Documents/ (copied in through Finder or Files), then the app bundle.
enum ModelFiles {
    static func find(_ name: String, ext: String) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for base in [docs, docs.appendingPathComponent("models"), Bundle.main.resourceURL?.appendingPathComponent("Models")].compactMap({ $0 }) {
            let u = base.appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return Bundle.main.url(forResource: name, withExtension: ext)
    }
}

extension EMSDictionary {
    /// formulary.json and ems_terms.json from shared/, copied into the app bundle.
    static func bundled() -> EMSDictionary? {
        guard let f = Bundle.main.url(forResource: "formulary", withExtension: "json"),
              let t = Bundle.main.url(forResource: "ems_terms", withExtension: "json"),
              let fd = try? Data(contentsOf: f), let td = try? Data(contentsOf: t),
              let formulary = try? JSONDecoder().decode(FormularyFile.self, from: fd),
              let terms = try? JSONDecoder().decode(EMSTermsFile.self, from: td) else { return nil }
        return EMSDictionary(formulary: formulary, terms: terms)
    }
}

/// The record's recogniser, shared by every call's session. A completed call can still be transcribing while the next
/// one records, and whisper.cpp runs one decode at a time, so calls into it take turns.
private final class SerialTranscriber: Transcriber {
    private let inner: Transcriber
    private let lock = NSLock()
    init(_ inner: Transcriber) { self.inner = inner }
    var modelName: String { inner.modelName }
    func transcribe(_ pcm: [Float], prompt: String?) throws -> [ASRPiece] {
        try lock.withLock { try inner.transcribe(pcm, prompt: prompt) }
    }
}
