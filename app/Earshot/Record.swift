import Foundation
import Transcribe

/// Whisper's side of a call (the `transcribe` package): the same audio the live recogniser hears, read again more
/// carefully. Its lines arrive a few seconds behind the words and take the place of the live ones.
///
///   audio ─┬─► Transcriber (Apple, live)  ─► words on screen at once
///          └─► Record (Whisper)           ─► lines with a confidence, which replace them
///
/// One `Scribe` runs for each unbroken stretch of audio: from Start or Resume to Pause, or to a dropped clip.
/// A call that is completed can still be read while the next one records.
final class Record {
    /// A call's new lines, and the moment in the audio Whisper has got to. On the main queue.
    var onLines: (Call.ID, [Item], Date) -> Void = { _, _, _ in }

    /// The model writing the record, like "ems-small.en-ft-q5_0". Nil when none is installed: live words are then all there is.
    private(set) var name: String?

    private var whisper: Whisper?
    private final class Stretch {
        let scribe: Scribe, call: Call.ID
        var began: Date?   // when its first sample was heard
        init(_ scribe: Scribe, _ call: Call.ID) { self.scribe = scribe; self.call = call }
    }
    private let lock = NSLock()            // audio arrives on its own thread
    private var current: Stretch?          // guarded by `lock`
    private var reading: [Call.ID: Int] = [:]              // stretches not yet read to the end, by call
    private var waiting: [Call.ID: [() -> Void]] = [:]     // who to tell when a call has been read to the end

    /// Loads the model, which takes a few seconds, then calls `done` on the main queue.
    /// Each model is looked for in the app's Documents folder (copied in with Finder), then in the app itself.
    func load(_ done: @escaping () -> Void) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let places = Self.models.flatMap { [documents.appending(path: "\($0).bin"), Bundle.main.url(forResource: $0, withExtension: "bin")] }
        guard let file = places.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return done() }
        DispatchQueue.global(qos: .userInitiated).async {
            #if targetEnvironment(simulator)
            let loaded = try? Whisper(model: file, gpu: false)   // the simulator's graphics chip is not a real one
            #else
            let loaded = try? Whisper(model: file)
            #endif
            loaded?.lean(toward: Drugs.names)
            DispatchQueue.main.async {
                self.whisper = loaded
                self.name = loaded?.name
                done()
            }
        }
    }
    /// The models to look for, best first: Whisper small.en fine-tuned on EMS speech, which the app is built with,
    /// then the stock one, for comparing the two.
    static let models = ["ggml-ems-small.en-ft-q5_0", "ggml-small.en"]

    /// A stretch of audio is starting for this call.
    func begin(for call: Call.ID) {
        guard let whisper else { return }
        end()
        let stretch = Stretch(Scribe(whisper), call)
        stretch.scribe.onLines = { [weak self, weak stretch] lines, heard in
            guard let self, let began = stretch?.began else { return }
            self.onLines(call, lines.map { Item($0, since: began) }, began.addingTimeInterval(Double(heard) / 1000))
        }
        #if DEBUG
        stretch.scribe.onTimed = { length, took in print(String(format: "whisper: %.1f s of speech read in %.1f s", length, took)) }
        #endif
        reading[call, default: 0] += 1
        lock.withLock { current = stretch }
    }

    /// 16 kHz mono audio, from any thread.
    func feed(_ pcm: [Int16]) {
        lock.withLock {
            guard let current else { return }
            if current.began == nil { current.began = Date().addingTimeInterval(-Double(pcm.count) / 16000) }
            current.scribe.feed(pcm)
        }
    }

    /// The stretch has ended. What it still holds is read; its lines keep arriving until then.
    func end() {
        guard let stretch = lock.withLock({ () -> Stretch? in defer { current = nil }; return current }) else { return }
        stretch.scribe.finish { [weak self] in
            guard let self else { return }
            self.reading[stretch.call, default: 1] -= 1
            if self.reading[stretch.call] == 0 {
                self.reading[stretch.call] = nil
                self.waiting.removeValue(forKey: stretch.call)?.forEach { $0() }
            }
        }
    }

    /// Returns once Whisper has read everything recorded for this call.
    @MainActor func finished(_ call: Call.ID) async {
        guard reading[call] != nil else { return }
        await withCheckedContinuation { done in waiting[call, default: []].append { done.resume() } }
    }
}

extension Item {
    /// A line Whisper wrote, placed on the clock.
    init(_ line: Line, since began: Date) {
        func at(_ ms: Int64) -> Date { began.addingTimeInterval(Double(ms) / 1000) }
        self.init(time: at(line.startMs), text: line.text, end: at(line.endMs), source: .whisper, confidence: line.confidence,
                  words: line.words.map { Word(offset: $0.offset, time: at($0.ms), confidence: $0.confidence) })
    }

    /// True for a line to read with care: only the live recogniser heard it, or Whisper was not sure of it.
    var unsure: Bool { source == .apple || (source == .whisper && (confidence ?? 1) < Lines.unsure) }
}
