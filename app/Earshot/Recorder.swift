import AVFoundation
import FoundationModels
import Speech

struct Problem: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: Microphone to text

/// Turns audio into text: the device's own microphone, or audio pushed in from the clip. Speech is cut into
/// segments at pauses. Each segment reports its words under one id as they firm up, so the caller can show
/// a line growing and then settling.
final class Transcriber {
    enum Source { case mic, clip }

    var onText: (UUID, String) -> Void = { _, _ in }
    var onCut: () -> Void = {}                  // the current segment closed; the next words start a new line
    var onLevel: (Int) -> Void = { _ in }       // loudness, 0...6, about twelve times a second
    var onProblem: (String) -> Void = { _ in }  // listening cannot continue

    private(set) var segment = UUID()
    private let engine = AVAudioEngine()
    // ponytail: English (US) only. Pass the crew's locale here when other languages matter.
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let lock = NSLock()   // the audio thread reads `request` while the main thread swaps it
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var running = false
    private var source = Source.mic
    private var heard = false, lastHeard = Date(), segmentStart = Date(), quickFailures = 0
    private var pauseTimer: Timer?

    // Call audio is patient information, so on a real iPad it must be recognised on the device or not at all.
    // Only the simulator, which has no on-device recogniser and no real patients, may send audio to Apple's servers.
    private var staysOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }
    #if targetEnvironment(simulator)
    private static let mayUseServers = true
    #else
    private static let mayUseServers = false
    #endif

    /// Asks for speech access, and for the microphone unless the audio comes from the clip.
    /// Returns what to tell the user if either is refused.
    static func authorize(microphone: Bool = true) async -> String? {
        let speech = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
        guard speech == .authorized else { return "Speech recognition is off for Earshot. Turn it on in Settings." }
        guard !microphone else {
            return await AVAudioApplication.requestRecordPermission() ? nil : "The microphone is off for Earshot. Turn it on in Settings."
        }
        return nil
    }

    /// Starts listening. From the clip, the audio arrives through `push`; the device's own microphone stays off.
    func start(from source: Source = .mic) throws {
        guard let recognizer, recognizer.isAvailable else { throw Problem("Speech recognition is not available right now.") }
        guard staysOnDevice || Self.mayUseServers else {
            throw Problem("This \(deviceName) cannot transcribe English on the device yet, so Earshot will not record. Call audio is never sent off the \(deviceName).")
        }
        if source == .mic {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw Problem("No microphone was found.") }

            engine.inputNode.removeTap(onBus: 0)
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                self.lock.withLock { self.request }?.append(buffer)
                let level = Self.level(of: buffer)
                DispatchQueue.main.async { self.onLevel(level) }
            }
        }
        self.source = source
        running = true
        quickFailures = 0
        newSegment()
        if source == .mic {
            engine.prepare()
            try engine.start()
        }
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.heard, Date().timeIntervalSince(self.lastHeard) > 1.5 else { return }
            self.newSegment()   // a pause ends the line
        }
    }

    /// Audio from the clip, in the order it was captured. Ignored unless listening to the clip.
    func push(_ buffer: AVAudioPCMBuffer) {
        guard running, source == .clip else { return }
        lock.withLock { request }?.append(buffer)
        levelFrames += Int(buffer.frameLength)
        levelPeak = max(levelPeak, Self.level(of: buffer))
        if levelFrames >= 1280 {   // the clip sends 20 ms at a time; report loudness about twelve times a second, as the mic does
            onLevel(levelPeak)
            levelFrames = 0
            levelPeak = 0
        }
    }
    private var levelFrames = 0, levelPeak = 0

    func stop() {
        guard running else { return }
        running = false
        pauseTimer?.invalidate()
        if source == .mic {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        lock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in
            defer { request = nil }
            return request
        }?.endAudio()   // the last words still arrive, under the segment's id
        onCut()
        if source == .mic { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    /// Closes the line being spoken, so that what comes next (a mark, say) lands after it.
    func cut() {
        if running && heard { newSegment() }
    }

    private func newSegment() {
        guard let recognizer else { return }
        let id = UUID()
        segment = id
        heard = false
        segmentStart = Date()

        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.addsPunctuation = true
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
                    self.onText(id, text)
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
                    self.onProblem(error?.localizedDescription ?? "Speech recognition stopped.")
                } else {
                    self.newSegment()
                }
            }
        }
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Int {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let decibels = 10 * log10(max(sum / Float(buffer.frameLength), 1e-10))
        // Calibration: a quiet room sits near -55 dB and close speech near -10 dB. Shift these if a real iPad reads low or high.
        return min(6, max(0, Int(((decibels + 55) / 45 * 6).rounded())))
    }
}

// MARK: Transcript to paperwork

/// What the on-device model fills in. Anything it leaves empty shows in the app as "not heard".
@Generable
struct Draft: Codable {
    @Guide(description: "Patient age, sex and main complaint in one short line. Empty if not said.")
    var patient: String
    @Guide(description: "The most recent vital signs said aloud, like 'BP 142/88, HR 98'. Empty if none were said.")
    var latestVitals: String
    @Guide(description: "Medications or treatments given, with dose and route. Empty if none were said.")
    var given: String
    @Guide(description: "Allergies, exactly as said. Empty if allergies were not mentioned.")
    var allergies: String
    @Guide(description: "Why the crew was called and what they found on arrival, in one or two sentences. Empty if not said.")
    var dispatchAndScene: String
    @Guide(description: "One entry per set of vital signs, each starting with its clock time, like '14:05 BP 148/92, HR 104'.")
    var vitalsByTime: [String]
    @Guide(description: "A short factual account of the call in plain sentences.")
    var narrative: String
    @Guide(description: "One entry per treatment, each starting with its clock time, like '14:08 Aspirin 324 mg, chewed'.")
    var treatmentByTime: [String]

    static let blank = Draft(patient: "", latestVitals: "", given: "", allergies: "", dispatchAndScene: "", vitalsByTime: [], narrative: "", treatmentByTime: [])
}

/// Drafts the nurse handoff and PCR on the iPad itself, so the transcript never leaves the device.
/// ponytail: the on-device model reads about 4,000 tokens, roughly a 10 to 15 minute call. Longer calls fail here
/// rather than being cut silently. Summarise in chunks, or move to a server model, when calls outgrow it.
func writeDraft(from transcript: String) async throws -> Draft {
    guard !transcript.isEmpty else { throw Problem("Nothing was heard on this call.") }
    switch SystemLanguageModel.default.availability {
    case .available: break
    case .unavailable(.appleIntelligenceNotEnabled): throw Problem("Apple Intelligence is turned off. Turn it on in Settings to get drafts.")
    case .unavailable(.modelNotReady): throw Problem("The on-device model is still downloading. Try again in a few minutes.")
    case .unavailable: throw Problem("This device cannot run Apple Intelligence.")
    }
    let session = LanguageModelSession(instructions: """
        You draft paperwork for an ambulance crew from the transcript of what was said on a call. \
        Each line starts with its clock time in brackets. MARK lines are moments the medic flagged as important. \
        Use only facts that were said. Never guess, and never fill in typical values. \
        Leave a field empty when the transcript does not contain it. \
        Write spoken numbers as digits: "one forty-two over eighty-eight" becomes 142/88. Keep every field short.
        """)
    return try await session.respond(to: transcript, generating: Draft.self).content
}
