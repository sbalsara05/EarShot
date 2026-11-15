import Foundation

/// Turns quiet audio up before anything listens to it, so speech reaches the chunker and Whisper at a level they
/// work well at. Audio that is already loud enough passes through untouched.
///
///   audio ─► Level (turn up if quiet) ─► Chunker ─► Whisper
///
/// The clip's microphone records about 30 dB below full volume. Left alone, most of its speech sits under the
/// level the chunker counts as speech, and words are lost before Whisper ever sees them.
///
/// How much it turns up, decided 50 times a second:
/// 1. Enough that the loudest recent speech peaks at `goal`.
/// 2. But never so much that the room's own noise rises above `hush`.
/// 3. And never more than `most` times. Audio within 6 dB of the goal is not touched at all.
/// It turns down at once when something loud arrives, so nothing clips, and back up over about half a second.
public struct Level {
    public static let goal = 11_500.0   // where the loudest speech should peak: about a third of full scale (-9 dB)
    public static let hush = 150.0      // the room's noise is never raised above this (about -47 dB)
    public static let most = 60.0       // 36 dB

    /// How many times the audio is being turned up right now. 1 is untouched.
    public private(set) var gain = 1.0
    private var loud = 0.0              // the loudest recent sample; fades by half every 20 seconds
    private var recent: [Double] = []   // loudness of the last 5 seconds, a 20 ms piece at a time, for the room's level

    public init() {}

    public mutating func apply(_ pcm: [Int16]) -> [Int16] {
        var out = [Int16](), at = 0
        out.reserveCapacity(pcm.count)
        while at < pcm.count {
            let piece = pcm[at..<min(pcm.count, at + 320)]
            at += piece.count
            var peak = 0.0, sum = 0.0
            for s in piece { let v = Double(s); peak = max(peak, abs(v)); sum += v * v }
            loud = max(peak, loud * pow(0.5, Double(piece.count) / 320_000))
            recent.append((sum / Double(piece.count)).squareRoot())
            if recent.count > 250 { recent.removeFirst() }
            let room = recent.sorted()[recent.count / 10]
            var want = min(Self.most, Self.goal / max(loud, 1), Self.hush / max(room, 0.01))
            if want < 2 { want = 1 }   // within 6 dB of the goal is loud enough: leave it exactly as it came
            gain = want < gain ? want : min(want, gain * 1.12)
            for s in piece { out.append(Int16(max(-32767, min(32767, (Double(s) * gain).rounded())))) }
        }
        return out
    }
}
