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

/// Runs one call through the pipeline (core/, EarshotCore):
///
///   clip (ClipLink) or microphone
///     ├─► live recogniser (Apple, optional) ─► words on screen + second opinion
///     └─► LiveSession: Whisper ─► rules ─► events ─► chart, SOAP, NEMSIS
///                                    ▲ cross-check: where the two recognisers disagree on a drug,
///                                      dose or vital, the event is "please confirm"
///   finish ─► Draft from the events, plus an optional NoteWriter for prose, held to the transcript
///
/// The clip drives captures with its button; the app can also start, stop and mark through it.
/// Without a clip the microphone stands in, using the same messages.
final class CallEngine {
    // Callbacks, always on the main queue.
    var onLevel: (Int) -> Void = { _ in }
    var onLiveText: (UUID, String) -> Void = { _, _ in }
    var onCut: () -> Void = {}
    var onRecord: ([RecordLine]) -> Void = { _ in }
    var onCapture: (Bool) -> Void = { _ in }        // a capture started (true) or ended (false), from the clip or the app
    var onMarker: () -> Void = {}
    var onClipConnected: (Bool) -> Void = { _ in }
    var onProblem: (String) -> Void = { _ in }

    /// The clip connection, once the Bluetooth module exists. Nil: the microphone is used.
    var link: ClipLink? { didSet { attach() } }
    var clipConnected: Bool { link?.isConnected ?? false }
    /// Set when Whisper could not load: the record cannot be written, only live words.
    private(set) var recordProblem: String?

    private let dict: EMSDictionary?
    private var transcriber: Transcriber?
    private var session: LiveSession?
    private var callStart = Date()
    private let live = LiveRecognizer()
    private let mic = MicInput()
    private var usingMic = false
    private let clipQueue = DispatchQueue(label: "earshot.clip")   // decoding and ordering of clip messages
    private var clipDecoder: ClipFrameDecoder = PCMFrameDecoder()
    private let pcmDecoder = PCMFrameDecoder()
    private var micSeq: UInt32 = 0
    private let boot = Date()

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
        mic.onFrame = { [weak self] pcm in
            guard let self else { return }
            self.clipQueue.async {
                self.session?.handleDecodedAudio(seq: self.micSeq, clipMs: self.micClock(), pcm: pcm)
                self.micSeq &+= 1
            }
        }
        mic.onLevel = { [weak self] l in self?.onLevel(l) }
    }

    // MARK: The call

    /// Starts a new call. Whisper loads once and is kept for later calls.
    func beginCall(at start: Date) {
        session?.wipe()
        callStart = start
        guard let dict else { return }
        if transcriber == nil { transcriber = Self.loadWhisper(&recordProblem) }
        let s = LiveSession(dict: dict, config: PipelineConfig(), callId: "c\(Int(start.timeIntervalSince1970))",
                            startEpochMs: Int64(start.timeIntervalSince1970 * 1000), tzOffsetSeconds: TimeZone.current.secondsFromGMT(),
                            transcriber: transcriber)
        s.callbackQueue = .main
        s.onSegments = { [weak self] segs in
            guard let self else { return }
            self.onRecord(segs.map { RecordLine(start: self.date($0.startMs), end: self.date($0.endMs), text: $0.text) })
        }
        session = s
    }

    /// Starts a call's pipeline only if none is running (after a signed call is reopened, say).
    func ensureCall(at start: Date) {
        if session == nil { beginCall(at: start) }
    }

    /// Start listening: through the clip when connected (it answers with consent, which starts the
    /// capture), else through the microphone.
    @MainActor func startCapture() async throws {
        await LiveRecognizer.requestAuthorization()
        if clipConnected {
            link?.send(ClipProtocol.command(.start))
            return
        }
        if let why = await MicInput.authorize() { throw Problem(why) }
        try mic.start()
        usingMic = true
        let t = micClock()
        clipQueue.async { self.session?.handle(.consent(granted: true, source: "tablet", clipMs: Int64(t)), decoder: self.pcmDecoder) }
        live.start()
        onCapture(true)
    }

    func stopCapture() {
        if usingMic {
            mic.stop()
            usingMic = false
            let t = micClock()
            clipQueue.async { self.session?.handle(.consent(granted: false, source: "tablet", clipMs: Int64(t)), decoder: self.pcmDecoder) }
            live.stop()
            onCapture(false)
        } else if clipConnected {
            link?.send(ClipProtocol.command(.stop))
        }
    }

    func mark() {
        live.cut()
        if usingMic {
            let t = micClock()
            clipQueue.async { self.session?.handle(.marker(id: 0, source: "tablet", clipMs: Int64(t), audioSeq: -1), decoder: self.pcmDecoder) }
            onMarker()
        } else if clipConnected {
            link?.send(ClipProtocol.command(.marker))   // the clip answers with a marker event
        }
    }

    /// Ends listening, waits for Whisper to catch up, then drafts the paperwork from the record.
    @MainActor func finish() async -> CallOutput {
        stopCapture()
        guard let s = session else { return CallOutput(draft: .blank, docs: [:], notes: [recordProblem ?? "Nothing was recorded."]) }
        s.endCapture()
        await Task.detached { s.drain() }.value
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

    /// Signed or discarded: everything held for the call is wiped.
    func endCall() {
        stopCapture()
        session?.wipe()
        session = nil
    }

    // MARK: The clip

    private func attach() {
        guard let link else { return }
        link.onConnected = { [weak self] up in
            DispatchQueue.main.async {
                guard let self else { return }
                if !up && !self.usingMic { self.session?.endCapture(); self.live.stop(); self.onCapture(false) }
                self.onClipConnected(up)
            }
        }
        link.onText = { [weak self] text in self?.clipQueue.async { self?.clipText(text) } }
        link.onAudio = { [weak self] bytes in self?.clipQueue.async { self?.clipAudio(bytes) } }
    }

    private func clipText(_ text: String) {
        guard let m = ClipProtocol.parseText(text) else { return }
        if case .hello(let h) = m {
            if h.codec == "opus" {
                if let d = try? OpusFrameDecoder() { clipDecoder = d }
                else { DispatchQueue.main.async { self.onProblem("This device cannot decode the clip's audio.") } }
            } else {
                clipDecoder = PCMFrameDecoder()
            }
        }
        session?.handle(m, decoder: clipDecoder)
        switch m {
        case .consent(let granted, _, _):
            if granted { clipDecoder.reset() }
            DispatchQueue.main.async {
                if granted { self.live.start() } else { self.live.stop() }
                self.onCapture(granted)
            }
        case .state(let listening, _):
            DispatchQueue.main.async {
                if listening && !self.live.running { self.live.start(); self.onCapture(true) }
            }
        case .marker:
            DispatchQueue.main.async { self.live.cut(); self.onMarker() }
        default:
            break
        }
    }

    private func clipAudio(_ bytes: [UInt8]) {
        guard case .audio(let f)? = ClipProtocol.parseAudio(bytes), let pcm = try? clipDecoder.decode(f.payload) else { return }
        session?.handleDecodedAudio(seq: f.seq, clipMs: f.clipMs, pcm: pcm)
        if let b = Audio.buffer(pcm) { live.append(b) }
        let level = Audio.level(pcm)
        DispatchQueue.main.async { self.onLevel(level) }
    }

    // MARK: Helpers

    private func micClock() -> UInt32 { UInt32(max(0, Date().timeIntervalSince(boot) * 1000)) }
    private func date(_ tMs: Int64) -> Date { callStart.addingTimeInterval(Double(tMs) / 1000) }

    private static func loadWhisper(_ problem: inout String?) -> Transcriber? {
        for name in ["whisper-ems-small.en-q5", "ggml-small.en", "ggml-base.en", "ggml-tiny.en"] {
            if let url = ModelFiles.find(name, ext: "bin"),
               let t = try? WhisperTranscriber(modelPath: url.path, threads: ProcessInfo.processInfo.activeProcessorCount > 4 ? 4 : 2) {
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
