import Foundation
import os
import EarshotCore

/// Diagnostic: how loud the audio given to the record (Whisper) is on this device, and how loud it
/// was under each live line that ends up "not in the record". Answers whether those lines fell
/// under the speech detector's fixed floor (`VADConfig.minRMS`).
///
/// Logs numbers only: never words, never audio. Read it in Console.app (iPad connected, filter
/// `category:levels`) or in Xcode's console when running from Xcode.
final class LevelProbe {
    static let shared = LevelProbe()

    /// The speech detector's fixed floor in dBFS: a 20 ms frame quieter than this is never speech.
    static let vadFloorDb: Float = 20 * log10(Float(PipelineConfig().vad.minRMS) / 32768)   // about -48.7

    private let log = Logger(subsystem: "com.mihirargulkar.earshot", category: "levels")
    private let lock = NSLock()
    private var frames: [(t: Date, db: Float)] = []   // the last ten minutes of 20 ms frames
    private var pending: [Float] = []                 // this second's frames, for the once-a-second line
    private var pendingStart = Date()

    /// One 20 ms frame (320 samples, 16 kHz) as it is handed to the record. Any thread.
    func frame(_ pcm: [Int16], at t: Date = Date()) {
        guard !pcm.isEmpty else { return }
        var acc: Float = 0
        for v in pcm { let x = Float(v); acc += x * x }
        let db = 20 * log10(max((acc / Float(pcm.count)).squareRoot(), 1) / 32768)
        lock.withLock {
            frames.append((t, db))
            if let first = frames.first, t.timeIntervalSince(first.t) > 600 {
                frames.removeFirst(frames.firstIndex { t.timeIntervalSince($0.t) <= 600 } ?? 0)
            }
            pending.append(db)
            if t.timeIntervalSince(pendingStart) >= 1 {
                let s = Self.stats(pending)
                log.info("second: median \(s.p50, format: .fixed(precision: 1)) p90 \(s.p90, format: .fixed(precision: 1)) max \(s.max, format: .fixed(precision: 1)) dBFS, over floor \(s.overFloor, format: .fixed(precision: 0))%")
                pending.removeAll(keepingCapacity: true)
                pendingStart = t
            }
        }
    }

    /// A live line was marked "not in the record". `from`/`to` is the stretch the record was checked over.
    func lineMarked(from: Date, to: Date, chars: Int, by step: String) {
        let dbs = lock.withLock { frames.filter { $0.t >= from && $0.t <= to }.map(\.db) }
        let s = Self.stats(dbs)
        log.notice("not in record (\(step, privacy: .public)): \(chars) chars, \(to.timeIntervalSince(from), format: .fixed(precision: 1)) s, \(dbs.count) frames; median \(s.p50, format: .fixed(precision: 1)) p90 \(s.p90, format: .fixed(precision: 1)) max \(s.max, format: .fixed(precision: 1)) dBFS, over floor \(s.overFloor, format: .fixed(precision: 0))% -> \(Self.verdict(dbs), privacy: .public)")
    }

    struct Stats { var p50: Float; var p90: Float; var max: Float; var overFloor: Float }

    static func stats(_ dbs: [Float]) -> Stats {
        guard !dbs.isEmpty else { return Stats(p50: -120, p90: -120, max: -120, overFloor: 0) }
        let s = dbs.sorted()
        func q(_ p: Double) -> Float { s[Int(Double(s.count - 1) * p)] }
        let over = Float(dbs.filter { $0 > vadFloorDb }.count) / Float(dbs.count) * 100
        return Stats(p50: q(0.5), p90: q(0.9), max: s.last!, overFloor: over)
    }

    /// One word for why a line was not recorded, from the frame levels under it.
    /// The VAD opens a chunk only after `minSpeechMs` of voiced 20 ms frames (10 frames by default), and
    /// a frame is voiced only above the fixed floor. The window also holds the pause before the words,
    /// so the count of frames over the floor is used, not a share or the median.
    /// - no-audio: no frames in the window (a clock or timing problem, not level)
    /// - below-floor: too few frames over the floor for the VAD ever to open a chunk
    /// - borderline: just enough; the VAD's other rule (6 dB over the room) or a short chunk may have lost it
    /// - loud-enough: the fixed floor was not the cause; look at timing or Whisper's output
    static func verdict(_ dbs: [Float]) -> String {
        guard !dbs.isEmpty else { return "no-audio" }
        let minFrames = max(1, PipelineConfig().vad.minSpeechMs / PipelineConfig().vad.frameMs)
        let over = dbs.filter { $0 > vadFloorDb }.count
        if over < minFrames { return "below-floor" }
        if over < minFrames * 3 { return "borderline" }
        return "loud-enough"
    }
}
