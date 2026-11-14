import AVFoundation
import FoundationModels
import Speech

struct Problem: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: Live words (optional)

/// Apple's on-device speech recogniser, fed audio buffers from whichever input is live (the clip or
/// the microphone). Its words show on screen while the medic talks, and the pipeline uses them as a
/// second opinion on drugs, doses and vitals. The record itself comes from Whisper, so this is
/// optional: when the device cannot recognise speech on the device, recording carries on without
/// live words. Speech is cut into lines at pauses; each line reports its words under one id as
/// they firm up.
final class LiveRecognizer {
    var onText: (UUID, String, Date) -> Void = { _, _, _ in }   // id, words so far, when the line started
    var onCut: () -> Void = {}
    /// Words to listen for (drug names, EMS terms).
    var vocabulary: [String] = []

    private(set) var segment = UUID()
    private(set) var running = false
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let lock = NSLock()   // the audio thread reads `request` while the main thread swaps it
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var heard = false, lastHeard = Date(), segmentStart = Date(), quickFailures = 0
    private var pauseTimer: Timer?

    /// Call audio is patient information: live words are only shown when recognised on the device.
    /// The simulator, which has no on-device recogniser and no real patients, may use Apple's servers.
    #if targetEnvironment(simulator)
    private static let mayUseServers = true
    #else
    private static let mayUseServers = false
    #endif

    /// Why live words are off on this device, or nil when they can run.
    var unavailableReason: String? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return "speech recognition is not allowed" }
        guard let r = recognizer, r.isAvailable else { return "speech recognition is not available" }
        guard r.supportsOnDeviceRecognition || Self.mayUseServers else { return "this device cannot recognise speech on the device" }
        return nil
    }

    static func requestAuthorization() async {
        let _: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
        }
    }

    /// Starts live words if this device can; returns false (and stays off) if it cannot.
    @discardableResult
    func start() -> Bool {
        guard !running, unavailableReason == nil else { return false }
        running = true
        quickFailures = 0
        newSegment()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.heard, Date().timeIntervalSince(self.lastHeard) > 1.5 else { return }
            self.newSegment()   // a pause ends the line
        }
        return true
    }

    /// Audio from any thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request }?.append(buffer)
    }

    func stop() {
        guard running else { return }
        running = false
        pauseTimer?.invalidate()
        lock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in
            defer { request = nil }
            return request
        }?.endAudio()   // the last words still arrive, under the segment's id
        onCut()
    }

    /// Closes the line being spoken, so that what comes next (a mark, say) lands after it.
    func cut() {
        if running && heard { newSegment() }
    }

    private func newSegment() {
        guard let recognizer else { return }
        let id = UUID()
        let started = Date()
        segment = id
        heard = false
        segmentStart = started

        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.addsPunctuation = true
        next.contextualStrings = vocabulary
        // The simulator claims on-device support but fails to start it, so there it always uses the servers.
        next.requiresOnDeviceRecognition = !Self.mayUseServers
        let previous = lock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in
            defer { request = next }
            return request
        }
        previous?.endAudio()
        onCut()

        recognizer.recognitionTask(with: next) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                    self.onText(id, text, started)
                    if id == self.segment {
                        self.heard = true
                        self.lastHeard = Date()
                        // ponytail: a long unbroken run is cut by length, which can split a word. Cut at a sentence end if it shows.
                        if text.count > 220 { self.newSegment() }
                    }
                }
                // The recogniser gave up on the segment we are still filling (silence, or its time limit): open a fresh one.
                guard id == self.segment, self.running, error != nil || result?.isFinal == true else { return }
                self.quickFailures = error != nil && Date().timeIntervalSince(self.segmentStart) < 1 ? self.quickFailures + 1 : 0
                if self.quickFailures >= 3 {
                    self.stop()   // live words stop; the record (Whisper) keeps going
                } else {
                    self.newSegment()
                }
            }
        }
    }
}

// MARK: Microphone (used when no clip is connected)

/// The device microphone as a stand-in for the clip. Gives the live recogniser its native buffers,
/// and the pipeline 20 ms frames of 16 kHz mono int16, the same shape the clip sends.
final class MicInput {
    var onBuffer: (AVAudioPCMBuffer) -> Void = { _ in }
    var onFrame: ([Int16]) -> Void = { _ in }
    var onLevel: (Int) -> Void = { _ in }
    var onResumed: () -> Void = {}              // the mic came back after an interruption; the next words start a new line
    var onProblem: (String) -> Void = { _ in }  // listening cannot continue

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var carry: [Int16] = []
    private var running = false
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    init() {
        // A phone call or Siri takes the microphone away for a while. When it is given back, carry on.
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.running,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                try self.engine.start()
                self.onResumed()
            } catch {
                self.onProblem("The microphone could not be taken back after an interruption. \(error.localizedDescription)")
            }
        }
    }

    static func authorize() async -> String? {
        guard await AVAudioApplication.requestRecordPermission() else { return "The microphone is off for Earshot. Turn it on in Settings." }
        return nil
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw Problem("No microphone was found.") }
        converter = AVAudioConverter(from: format, to: target)
        carry.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.onBuffer(buffer)
            let pcm = self.convert(buffer)
            self.carry += pcm
            while self.carry.count >= 320 {
                self.onFrame(Array(self.carry.prefix(320)))
                self.carry.removeFirst(320)
            }
            let level = Audio.level(pcm)
            DispatchQueue.main.async { self.onLevel(level) }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        carry.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let converter else { return [] }
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}

enum Audio {
    /// How loud audio is on the meter's scale, 0 to 6 rows. Takes 16 kHz samples, the shape both the
    /// microphone and the clip give the pipeline.
    ///
    /// Three things make it follow quiet speech closely. It takes the loudest few milliseconds, not the
    /// average of all of it, so a single word shows even when the audio is mostly the pause around it. The scale tops out
    /// at ordinary speech, not at shouting, so speech fills most of the meter. And the curve lifts the low end, so a
    /// whisper or a person across the room still moves it.
    static let meterFloor: Float = -55   // dB: a quiet room sits near here, and shows nothing
    static let meterCeiling: Float = -22 // dB: ordinary close speech reaches here and fills the meter
    static let meterCurve: Float = 0.75  // under 1 lifts quiet sounds; 1 would be a straight line
    static func level(_ pcm: [Int16]) -> Int {
        guard !pcm.isEmpty else { return 0 }
        let piece = 80   // five milliseconds at 16 kHz
        var loudest: Float = 0
        var start = 0
        while start < pcm.count {
            let end = min(pcm.count, start + piece)
            var sum: Float = 0
            for i in start..<end { let v = Float(pcm[i]) / 32768; sum += v * v }
            loudest = max(loudest, sum / Float(end - start))
            start = end
        }
        let decibels = 10 * log10(max(loudest, 1e-10))
        let position = min(1, max(0, (decibels - meterFloor) / (meterCeiling - meterFloor)))
        return Int((pow(position, meterCurve) * 6).rounded())
    }

    private static let float16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    /// 16 kHz int16 samples (decoded clip audio) as a buffer the live recogniser accepts.
    static func buffer(_ pcm: [Int16]) -> AVAudioPCMBuffer? {
        guard let b = AVAudioPCMBuffer(pcmFormat: float16k, frameCapacity: AVAudioFrameCount(pcm.count)), let ch = b.floatChannelData else { return nil }
        for i in pcm.indices { ch[0][i] = Float(pcm[i]) / 32768 }
        b.frameLength = AVAudioFrameCount(pcm.count)
        return b
    }
}

// MARK: Narrative formats (optional: the medic may ask for the narrative in another layout)

/// How the PCR narrative is laid out. The first draft is always plain, written from the record by the
/// pipeline. The medic may pick another layout before signing off; that one is written by the on-device model.
/// ponytail: four built-in formats. A department's own template would be another case here, with its own sections.
enum NarrativeFormat: String, Codable, CaseIterable, Identifiable {
    case plain, soap, chart, draatt

    var id: String { rawValue }

    var name: String {
        switch self {
        case .plain: "Plain"
        case .soap: "SOAP"
        case .chart: "CHART"
        case .draatt: "DRAATT"
        }
    }

    /// The headings of the format's sections, in order. Each heading's first letter spells the format's name.
    var sections: [String] {
        switch self {
        case .plain: []
        case .soap: ["Subjective", "Objective", "Assessment", "Plan"]
        case .chart: ["Chief complaint", "History", "Assessment", "Rx (treatment)", "Transport"]
        case .draatt: ["Dispatch", "Response", "Arrival", "Assessment", "Treatment", "Transport"]
        }
    }

    /// One line saying what the format is, for the place it is chosen.
    var detail: String { self == .plain ? "A short account in plain sentences" : sections.joined(separator: ", ") }

    /// The narrative as text: each section under its heading, like "S - SUBJECTIVE:". A section the call said
    /// nothing about reads "Not heard.", so it is seen and not passed over.
    func layOut(_ texts: [String]) -> String {
        guard self != .plain else { return texts.first ?? "" }
        return zip(sections, texts).map { heading, text in
            let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(heading.prefix(1)) - \(heading.uppercased()):\n\(said.isEmpty ? Self.notHeard : said)"
        }
        .joined(separator: "\n\n")
    }

    static let notHeard = "Not heard."

    /// True for a line that `layOut` wrote as a section heading.
    static func isHeading(_ line: some StringProtocol) -> Bool {
        line.count > 5 && line.hasSuffix(":") && line.dropFirst().hasPrefix(" - ") && line == line.uppercased()
    }

    /// The format the crew last chose. New calls are first drafted in it.
    static var preferred: NarrativeFormat {
        get { UserDefaults.standard.string(forKey: "narrativeFormat").flatMap(NarrativeFormat.init) ?? .plain }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "narrativeFormat") }
    }
}

// The narrative in each format. One struct per format, so every section carries its own instruction.

@available(iOS 26.0, *)
@Generable
struct ModelPlain {
    @Guide(description: "A short factual account of the call in plain sentences.")
    var narrative: String
}

@available(iOS 26.0, *)
@Generable
struct ModelSOAP {
    @Guide(description: "Subjective: what the patient or bystanders said about the complaint, how it began, and the patient's history. Empty if not said.")
    var subjective: String
    @Guide(description: "Objective: what the crew saw and measured, including exam findings and vital signs. Empty if not said.")
    var objective: String
    @Guide(description: "Assessment: the crew's own stated impression of what is wrong. Empty if the crew did not say one.")
    var assessment: String
    @Guide(description: "Plan: treatments given, with dose and route, and where the patient is being taken. Empty if not said.")
    var plan: String
}

@available(iOS 26.0, *)
@Generable
struct ModelCHART {
    @Guide(description: "Chief complaint: the main problem, in the patient's words where they were said. Empty if not said.")
    var chiefComplaint: String
    @Guide(description: "History: how the problem began, past medical history, medications and allergies. Empty if not said.")
    var history: String
    @Guide(description: "Assessment: exam findings and vital signs. Empty if not said.")
    var assessment: String
    @Guide(description: "Treatment: medications and treatments given, with dose and route. Empty if none were said.")
    var treatment: String
    @Guide(description: "Transport: where the patient is being taken, how, and any change on the way. Empty if not said.")
    var transport: String
}

@available(iOS 26.0, *)
@Generable
struct ModelDRAATT {
    @Guide(description: "Dispatch: what the crew was sent to, and for whom. Empty if not said.")
    var dispatch: String
    @Guide(description: "Response: how the crew travelled to the call, and anything that delayed them. Empty if not said.")
    var response: String
    @Guide(description: "Arrival: what the crew found on arriving, and where the patient was. Empty if not said.")
    var arrival: String
    @Guide(description: "Assessment: the complaint, history, exam findings and vital signs. Empty if not said.")
    var assessment: String
    @Guide(description: "Treatment: medications and treatments given, with dose and route. Empty if none were said.")
    var treatment: String
    @Guide(description: "Transport: where the patient is being taken, how, and any change on the way. Empty if not said.")
    var transport: String
}

/// A session with the on-device model, set up for drafting. Throws a message for the medic if the model cannot run.
@available(iOS 26.0, *)
private func draftingSession() throws -> LanguageModelSession {
    switch SystemLanguageModel.default.availability {
    case .available: break
    case .unavailable(.appleIntelligenceNotEnabled): throw Problem("Apple Intelligence is turned off. Turn it on in Settings to get drafts.")
    case .unavailable(.modelNotReady): throw Problem("The on-device model is still downloading. Try again in a few minutes.")
    case .unavailable: throw Problem("This device cannot run Apple Intelligence.")
    }
    return LanguageModelSession(instructions: """
        You draft paperwork for an ambulance crew from the transcript of what was said on a call. \
        Each line starts with its clock time in brackets. MARK lines are moments the medic flagged as important. \
        Use only facts that were said. Never guess, and never fill in typical values. \
        Leave a field empty when the transcript does not contain it. \
        Write spoken numbers as digits: "one forty-two over eighty-eight" becomes 142/88. Keep every field short.
        """)
}

/// Writes the PCR narrative alone, laid out in the given format, from the same transcript and under the same rules.
func writeNarrative(from transcript: String, as format: NarrativeFormat) async throws -> String {
    guard !transcript.isEmpty else { throw Problem("Nothing was heard on this call.") }
    guard #available(iOS 26.0, *) else { throw Problem("AI drafts need iOS 26 or later. Update this \(deviceName) to get them.") }
    let session = try draftingSession()
    let ask = format == .plain ? transcript : """
        Write the narrative of this call in \(format.name) format (\(format.detail)). \
        Write each section as short complete sentences that start with a capital letter, with every number as digits, \
        like "68-year-old male" and "BP 150/90". Put each fact in the one section it belongs to.

        \(transcript)
        """
    switch format {
    case .plain:
        return format.layOut([try await session.respond(to: ask, generating: ModelPlain.self).content.narrative])
    case .soap:
        let n = try await session.respond(to: ask, generating: ModelSOAP.self).content
        return format.layOut([n.subjective, n.objective, n.assessment, n.plan])
    case .chart:
        let n = try await session.respond(to: ask, generating: ModelCHART.self).content
        return format.layOut([n.chiefComplaint, n.history, n.assessment, n.treatment, n.transport])
    case .draatt:
        let n = try await session.respond(to: ask, generating: ModelDRAATT.self).content
        return format.layOut([n.dispatch, n.response, n.arrival, n.assessment, n.treatment, n.transport])
    }
}
