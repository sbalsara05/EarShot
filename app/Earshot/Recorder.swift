import AVFoundation
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
    /// Loudness 0...6 for the meter. A quiet room sits near -55 dB and close speech near -10 dB.
    static func level(_ pcm: [Int16]) -> Int {
        guard !pcm.isEmpty else { return 0 }
        var sum: Double = 0
        for s in pcm { let v = Double(s) / 32768; sum += v * v }
        let decibels = 10 * log10(max(sum / Double(pcm.count), 1e-10))
        return min(6, max(0, Int(((decibels + 55) / 45 * 6).rounded())))
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
