import Foundation

/// A stretch of speech cut out of the audio, ready for Whisper.
public struct Chunk: Equatable, Sendable {
    public var startSample: Int64   // since the audio began, at 16,000 samples a second
    public var samples: [Int16]
    public var startMs: Int64 { startSample / 16 }
    public var endMs: Int64 { (startSample + Int64(samples.count)) / 16 }
}

/// Cuts 16 kHz mono audio into chunks of speech at pauses, as it arrives. Whisper reads a finished chunk, not a
/// stream, so where the cuts fall decides how soon text shows and whether a sentence is split.
///
/// Speech is a 20 ms frame louder than the room: the room's level is the quiet end of the last five seconds, so
/// steady road or cab noise raises it and is not heard as one endless sentence. The settings lean toward letting
/// too much through: audio that is not sent is never transcribed, while noise that is sent costs Whisper a moment
/// and is mostly thrown out by `Lines`. A chunk ends after `quiet` of
/// no speech. One that runs past `longest` is cut at its quietest moment and carries on, with no audio lost.
/// Audio is held in memory only, and only until its chunk is handed over.
public final class Chunker {
    public var quiet = 700            // ms of no speech that ends a chunk
    public var longest = 25_000       // ms: Whisper reads at most 30 s at a time
    public var shortest = 200         // ms of speech a chunk needs, so a click or a cough is not sent
    public var lead = 400             // ms kept before the first loud frame, so the first word is whole
    public var aboveRoom = 4.0        // dB over the room's level that counts as speech
    public var floor = 60.0           // and never quieter than this: about -55 dB, where the app's meter starts to move

    private static let frame = 320    // 20 ms
    private var held: [Int16] = []    // audio from `base` on
    private var base: Int64 = 0       // sample index of held[0]
    private var position: Int64 = 0   // samples looked at so far
    private var room: [Double] = []   // loudness of recent frames
    private var roomIndex = 0
    private var speaking = false
    private var start: Int64 = 0, lastLoud: Int64 = 0
    private var loudMs = 0
    private var frames: [(at: Int64, level: Double)] = []   // the open chunk's frames, to find its quietest moment

    public init() {}

    /// True while a chunk is open.
    public var isSpeaking: Bool { speaking }
    /// How much audio has been taken in, in milliseconds.
    public var heardMs: Int64 { position / 16 }

    public func push(_ pcm: [Int16]) -> [Chunk] {
        held += pcm
        var out: [Chunk] = []
        while Int64(held.count) - (position - base) >= Int64(Self.frame) {
            let i = Int(position - base)
            var sum = 0.0
            for k in i..<(i + Self.frame) { let v = Double(held[k]); sum += v * v }
            let level = (sum / Double(Self.frame)).squareRoot()
            let at = position
            position += Int64(Self.frame)
            if room.count < 250 { room.append(level) } else { room[roomIndex] = level; roomIndex = (roomIndex + 1) % 250 }

            if level > max(floor, roomLevel() * pow(10, aboveRoom / 20)) {
                if !speaking {
                    speaking = true
                    start = max(base, at - Int64(lead) * 16)
                    loudMs = 0
                    frames = []
                }
                lastLoud = position
                loudMs += 20
            }
            if speaking {
                frames.append((at, level))
                if (position - lastLoud) / 16 >= Int64(quiet) {
                    if loudMs >= shortest { out.append(cut(from: start, to: min(position, lastLoud + Int64(quiet / 2) * 16))) }
                    speaking = false
                } else if (position - start) / 16 >= Int64(longest) {
                    // Cut at the quietest frame in the last third, and carry on from there.
                    let at = frames.suffix(max(1, frames.count / 3)).min { $0.level < $1.level }!.at
                    out.append(cut(from: start, to: at))
                    start = at
                    frames.removeAll { $0.at < at }
                    loudMs = shortest
                }
            }
            if !speaking { forget(before: position - Int64(lead) * 16) }
        }
        return out
    }

    /// The audio has ended: hands over the chunk still open, if it holds speech.
    public func finish() -> [Chunk] {
        defer { speaking = false; forget(before: position) }
        return speaking && loudMs >= shortest && position > start ? [cut(from: start, to: position)] : []
    }

    private func roomLevel() -> Double {
        guard room.count >= 10 else { return floor }
        return room.sorted()[Int(Double(room.count - 1) * 0.10)]
    }

    private func cut(from a: Int64, to b: Int64) -> Chunk {
        let chunk = Chunk(startSample: a, samples: Array(held[Int(a - base)..<Int(b - base)]))
        forget(before: b)
        return chunk
    }

    private func forget(before sample: Int64) {
        let n = Int(min(max(0, sample - base), Int64(held.count)))
        guard n > 0 else { return }
        held.removeFirst(n)
        base += Int64(n)
    }
}
