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
    /// Set when Whisper could not load: the record cannot be written, only live words.
    private(set) var recordProblem: String?

    private let dict: EMSDictionary?
    private var whisper: Transcriber?            // loaded once, shared by every call's session
    private var sessions: [UUID: (session: LiveSession, start: Date)] = [:]
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
            self.session?.liveLine(id: id.uuidString, text: text, start: started, end: Date())
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

    /// Opens a call's session. Whisper loads once and is kept for later calls.
    func beginCall(_ id: UUID, at start: Date) {
        current = id
        guard sessions[id] == nil, let dict else { return }
        if whisper == nil { whisper = Self.loadWhisper(&recordProblem, dict: dict).map { SerialTranscriber($0) } }
        let s = LiveSession(dict: dict, config: PipelineConfig(), callId: "c\(Int(start.timeIntervalSince1970))",
                            startEpochMs: Int64(start.timeIntervalSince1970 * 1000), tzOffsetSeconds: TimeZone.current.secondsFromGMT(),
                            transcriber: whisper)
        s.callbackQueue = .main
        s.onSegments = { [weak self] segs in
            self?.onRecord(id, segs.map {
                RecordLine(start: start.addingTimeInterval(Double($0.startMs) / 1000), end: start.addingTimeInterval(Double($0.endMs) / 1000), text: $0.text)
            })
        }
        sessions[id] = (s, start)
    }

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
        guard let s = sessions.removeValue(forKey: id)?.session else {
            return CallOutput(draft: .blank, docs: [:], notes: [recordProblem
                ?? "The record for this call was not kept when the app closed, so nothing was drafted. Fill in the lines yourself."])
        }
        await withCheckedContinuation { done in audioQueue.async { done.resume() } }   // audio already queued reaches the session
        s.endCapture()
        await Task.detached { s.drain() }.value
        defer { s.wipe() }
        var notes: [String] = []
        if let p = recordProblem { notes.append(p) }

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
        sessions.removeValue(forKey: id)?.session.wipe()
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

    private static func loadWhisper(_ problem: inout String?, dict: EMSDictionary) -> WhisperTranscriber? {
        let asr = PipelineConfig().asr
        for name in ["whisper-ems-small.en-q5", "ggml-small.en", "ggml-base.en", "ggml-tiny.en"] {
            if let url = ModelFiles.find(name, ext: "bin"),
               let t = try? WhisperTranscriber(modelPath: url.path, threads: ProcessInfo.processInfo.activeProcessorCount > 4 ? 4 : 2) {
                // lean toward the formulary's drug names while decoding (BiasTrie)
                if asr.bias { t.setBias(phrases: dict.biasPhrases(), firstBonus: asr.biasFirst, nextBonus: asr.biasNext) }
                problem = nil
                return t
            }
        }
        problem = "No Whisper model is installed, so nothing said is written to the record. Run app/scripts/fetch_deps.sh, or copy ggml-small.en.bin into the app's Documents folder."
        return nil
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

/// Whisper shared by every call's session. A completed call can still be transcribing while the next
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
