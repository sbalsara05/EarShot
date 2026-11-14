import Foundation

/// Audio in, lines out, for one unbroken stretch of audio.
///
///   feed(audio) ─► Chunker cuts at pauses ─► Whisper reads each chunk ─► onLines(new lines, heard up to)
///
/// Feed it 16 kHz mono audio from any thread as it arrives, then call `finish`. Lines come back on `queue`, each
/// timed in milliseconds since the first sample. `heard up to` says how far into the audio Whisper has got, so
/// the caller knows which stretch is settled even when nothing was said in it.
public final class Scribe {
    public var onLines: ([Line], Int64) -> Void = { _, _ in }
    /// Called after each chunk with its length and how long Whisper took over it, both in seconds.
    public var onTimed: (Double, Double) -> Void = { _, _ in }
    public var queue = DispatchQueue.main

    private let whisper: Whisper
    private let chunker = Chunker()
    private let work = DispatchQueue(label: "earshot.scribe")           // the chunker
    private let reading = DispatchQueue(label: "earshot.scribe.whisper") // Whisper, which is slow
    private var waiting = 0          // chunks handed to Whisper and not yet read
    private var lastQuiet: Int64 = 0

    public init(_ whisper: Whisper) { self.whisper = whisper }

    public func feed(_ pcm: [Int16]) {
        work.async {
            for chunk in self.chunker.push(pcm) { self.read(chunk) }
            // Nothing being said and nothing waiting: say how far the silence has got, about once a second.
            let heard = self.chunker.heardMs
            if !self.chunker.isSpeaking, self.waiting == 0, heard - self.lastQuiet >= 1000 {
                self.lastQuiet = heard
                self.queue.async { self.onLines([], heard) }
            }
        }
    }

    /// The audio has ended. What is still held is read, then `done` is called on `queue`.
    public func finish(_ done: @escaping () -> Void = {}) {
        work.async {
            for chunk in self.chunker.finish() { self.read(chunk) }
            let heard = self.chunker.heardMs
            self.reading.async { self.queue.async { self.onLines([], heard); done() } }
        }
    }

    private func read(_ chunk: Chunk) {
        waiting += 1
        reading.async {
            let began = Date()
            let lines = Lines.build((try? self.whisper.read(chunk.samples)) ?? [], chunkStartMs: chunk.startMs)
            let took = Date().timeIntervalSince(began)
            self.queue.async {
                self.onTimed(Double(chunk.samples.count) / 16000, took)
                self.onLines(lines, chunk.endMs)
            }
            self.work.async { self.waiting -= 1 }
        }
    }
}
