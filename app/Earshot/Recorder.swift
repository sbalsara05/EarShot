import AVFoundation
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
    /// The same audio as 16 kHz mono samples, for Whisper. Called on the audio's own thread.
    var onAudio: ([Int16]) -> Void = { _ in }
    /// Set when Whisper is writing the record, so live words are a help and not a need: where this device cannot
    /// recognise speech itself, the recording runs without them and text arrives a pause at a time.
    var liveOptional = false

    private(set) var segment = UUID()
    private let engine = AVAudioEngine()
    // ponytail: English (US) only. Pass the crew's locale here when other languages matter.
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let lock = NSLock()   // the audio thread reads `request` while the main thread swaps it
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var running = false
    private var live = true   // live words are on for this recording
    private var converter: AVAudioConverter?   // the microphone's own format to Whisper's
    private static let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
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

    init() {
        // A phone call or Siri takes the microphone away for a while. When it is given back, carry on in a new line.
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.running, self.source == .mic,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                try self.engine.start()
                self.newSegment()
            } catch {
                self.onProblem("The microphone could not be taken back after an interruption. \(error.localizedDescription)")
            }
        }
    }

    /// Asks for speech access, and for the microphone unless the audio comes from the clip.
    /// Returns what to tell the user if either is refused.
    /// With `liveOptional`, refusing speech recognition only turns the live words off.
    static func authorize(microphone: Bool = true, liveOptional: Bool = false) async -> String? {
        let speech = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
        guard speech == .authorized || liveOptional else { return "Speech recognition is off for Earshot. Turn it on in Settings." }
        guard !microphone else {
            return await AVAudioApplication.requestRecordPermission() ? nil : "The microphone is off for Earshot. Turn it on in Settings."
        }
        return nil
    }

    /// Starts listening. From the clip, the audio arrives through `push`; the device's own microphone stays off.
    func start(from source: Source = .mic) throws {
        let allowed = SFSpeechRecognizer.authorizationStatus() == .authorized
        if !liveOptional {
            guard allowed, let recognizer, recognizer.isAvailable else { throw Problem("Speech recognition is not available right now.") }
            guard staysOnDevice || Self.mayUseServers else {
                throw Problem("This \(deviceName) cannot transcribe English on the device yet, so Earshot will not record. Call audio is never sent off the \(deviceName).")
            }
        }
        live = allowed && recognizer?.isAvailable == true && (staysOnDevice || Self.mayUseServers)
        if source == .mic {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw Problem("No microphone was found.") }
            converter = AVAudioConverter(from: format, to: Self.wire)

            engine.inputNode.removeTap(onBus: 0)
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                self.lock.withLock { self.request }?.append(buffer)
                self.onAudio(self.samples(from: buffer))
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
        guard live else { return }
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.heard, Date().timeIntervalSince(self.lastHeard) > 1.5 else { return }
            self.newSegment()   // a pause ends the line
        }
    }

    /// Audio from the clip, in the order it was captured. Ignored unless listening to the clip.
    func push(_ buffer: AVAudioPCMBuffer) {
        guard running, source == .clip else { return }
        lock.withLock { request }?.append(buffer)
        if let samples = buffer.floatChannelData?[0] {
            onAudio((0..<Int(buffer.frameLength)).map { Int16(max(-1, min(1, samples[$0])) * 32767) })
        }
        levelFrames += Int(buffer.frameLength)
        levelPeak = max(levelPeak, Self.level(of: buffer))
        if levelFrames >= 1280 {   // the clip sends 20 ms at a time; report loudness about twelve times a second, as the mic does
            onLevel(levelPeak)
            levelFrames = 0
            levelPeak = 0
        }
    }
    private var levelFrames = 0, levelPeak = 0

    /// A microphone buffer as 16 kHz mono samples.
    private func samples(from buffer: AVAudioPCMBuffer) -> [Int16] {
        let room = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 32
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: Self.wire, frameCapacity: room) else { return [] }
        var given = false
        converter.convert(to: out, error: nil) { _, status in
            status.pointee = given ? .noDataNow : .haveData
            defer { given = true }
            return given ? nil : buffer
        }
        guard let samples = out.int16ChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
    }

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
        guard live, let recognizer else { return }
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
                if self.quickFailures >= 3 && self.liveOptional {
                    // Live words have failed, but Whisper is still writing the record: carry on without them.
                    self.live = false
                    self.pauseTimer?.invalidate()
                    self.lock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in defer { self.request = nil }; return self.request }?.endAudio()
                    self.onCut()
                } else if self.quickFailures >= 3 {
                    self.onProblem(error?.localizedDescription ?? "Speech recognition stopped.")
                } else {
                    self.newSegment()
                }
            }
        }
    }

    /// How loud a buffer is on the meter's scale, 0 to 6 rows.
    ///
    /// Three things make it follow quiet speech closely. It takes the loudest few milliseconds in the buffer, not the
    /// average of all of it, so a single word shows even when the buffer is mostly the pause around it. The scale tops out
    /// at ordinary speech, not at shouting, so speech fills most of the meter. And the curve lifts the low end, so a
    /// whisper or a person across the room still moves it.
    static let meterFloor: Float = -55   // dB: a quiet room sits near here, and shows nothing
    static let meterCeiling: Float = -22 // dB: ordinary close speech reaches here and fills the meter
    static let meterCurve: Float = 0.75  // under 1 lifts quiet sounds; 1 would be a straight line
    static func level(of buffer: AVAudioPCMBuffer) -> Int {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength), piece = 256   // about five milliseconds at 48 kHz
        var loudest: Float = 0
        var start = 0
        while start < count {
            let end = min(count, start + piece)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            loudest = max(loudest, sum / Float(end - start))
            start = end
        }
        let decibels = 10 * log10(max(loudest, 1e-10))
        let position = min(1, max(0, (decibels - meterFloor) / (meterCeiling - meterFloor)))
        return Int((pow(position, meterCurve) * 6).rounded())
    }
}
