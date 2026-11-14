import Foundation

/// In-memory PCM ring buffer (16 kHz mono Int16). Never touches disk.
public final class PCMRingBuffer {
    private var buf: [Int16]
    private var start = 0         // index of oldest sample in buf
    private var count = 0
    /// Absolute sample index of the oldest held sample.
    public private(set) var baseSample: Int64 = 0
    public init(capacitySeconds: Int = 60) {
        buf = [Int16](repeating: 0, count: capacitySeconds * Wire.sampleRate)
    }
    public var capacity: Int { buf.count }
    public var endSample: Int64 { baseSample + Int64(count) }

    public func append(_ pcm: [Int16]) {
        for x in pcm {
            if count == buf.count { start = (start + 1) % buf.count; count -= 1; baseSample += 1 }
            buf[(start + count) % buf.count] = x
            count += 1
        }
    }
    /// Copy samples [from, to) (absolute indices). Clamped to what is held.
    public func read(from: Int64, to: Int64) -> [Int16] {
        let a = max(from, baseSample), b = min(to, endSample)
        guard b > a else { return [] }
        var out = [Int16](); out.reserveCapacity(Int(b - a))
        for k in a..<b { out.append(buf[(start + Int(k - baseSample)) % buf.count]) }
        return out
    }
    /// Drop everything before `sample` (free audio once transcribed).
    public func discard(before sample: Int64) {
        let n = Int(min(max(0, sample - baseSample), Int64(count)))
        for k in 0..<n { buf[(start + k) % buf.count] = 0 }
        start = (start + n) % buf.count; count -= n; baseSample += Int64(n)
    }
    /// Zero and drop everything (stop / sign).
    public func wipe() {
        for i in buf.indices { buf[i] = 0 }
        baseSample = endSample; start = 0; count = 0
    }
}

/// A finished speech segment, in samples relative to call start.
public struct SpeechChunk: Equatable, Sendable {
    public var startSample: Int64
    public var endSample: Int64
    public var startMs: Int64 { startSample * 1000 / Int64(Wire.sampleRate) }
    public var endMs: Int64 { endSample * 1000 / Int64(Wire.sampleRate) }
}

public struct VADConfig: Codable, Equatable, Sendable {
    /// "energy": adaptive energy VAD (default). "fixed": no VAD, cut the audio
    /// into windows of maxSegmentMs at the quietest frame (Whisper handles silence).
    public var mode: String = "energy"
    public var frameMs: Int = 20
    public var startDb: Double = 6.0           // speech if frame energy is this far above the noise floor
    public var minRMS: Double = 120            // absolute floor (Int16 units)
    public var floorWindowMs: Int = 3000       // noise floor = 15th percentile of frame RMS over this window
    public var hangoverMs: Int = 700
    public var minSpeechMs: Int = 200
    public var maxSegmentMs: Int = 25000
    public var preRollMs: Int = 300
    public init() {}
    enum CodingKeys: String, CodingKey { case mode, frameMs, startDb, minRMS, floorWindowMs, hangoverMs, minSpeechMs, maxSegmentMs, preRollMs }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = VADConfig()
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? z.mode
        frameMs = try c.decodeIfPresent(Int.self, forKey: .frameMs) ?? z.frameMs
        startDb = try c.decodeIfPresent(Double.self, forKey: .startDb) ?? z.startDb
        minRMS = try c.decodeIfPresent(Double.self, forKey: .minRMS) ?? z.minRMS
        floorWindowMs = try c.decodeIfPresent(Int.self, forKey: .floorWindowMs) ?? z.floorWindowMs
        hangoverMs = try c.decodeIfPresent(Int.self, forKey: .hangoverMs) ?? z.hangoverMs
        minSpeechMs = try c.decodeIfPresent(Int.self, forKey: .minSpeechMs) ?? z.minSpeechMs
        maxSegmentMs = try c.decodeIfPresent(Int.self, forKey: .maxSegmentMs) ?? z.maxSegmentMs
        preRollMs = try c.decodeIfPresent(Int.self, forKey: .preRollMs) ?? z.preRollMs
    }
}

/// Energy VAD with a noise floor that keeps adapting (low percentile of the
/// last few seconds), so steady cab/road/monitor noise raises the floor
/// instead of reading as one endless utterance. Streaming and deterministic.
/// Long speech is cut at the quietest frame near the max length.
public final class EnergyVAD {
    public let cfg: VADConfig
    private var history: [Double] = []      // recent frame RMS (ring)
    private var hIdx = 0
    private var inSpeech = false
    private var segStart: Int64 = 0
    private var lastVoice: Int64 = 0
    private var voicedMs = 0
    private var pos: Int64 = 0
    private var carry: [Int16] = []
    private var frameRMS: [(Int64, Double)] = []   // frames of the open segment (for quiet-point cuts)
    public init(_ cfg: VADConfig = VADConfig()) { self.cfg = cfg }

    var frameLen: Int { cfg.frameMs * Wire.sampleRate / 1000 }
    var samplesPerMs: Int64 { Int64(Wire.sampleRate / 1000) }

    func noiseFloor() -> Double {
        guard history.count >= 10 else { return cfg.minRMS }
        let s = history.sorted()
        return s[Int(Double(s.count - 1) * 0.15)]
    }

    public func push(_ pcm: [Int16]) -> [SpeechChunk] {
        var out: [SpeechChunk] = []
        carry.append(contentsOf: pcm)
        var i = 0
        let fl = frameLen
        let histMax = max(10, cfg.floorWindowMs / cfg.frameMs)
        while i + fl <= carry.count {
            var acc = 0.0
            for k in i..<(i + fl) { let v = Double(carry[k]); acc += v * v }
            let rms = (acc / Double(fl)).squareRoot()
            let frameStart = pos
            pos += Int64(fl)
            if history.count < histMax { history.append(rms) } else { history[hIdx] = rms; hIdx = (hIdx + 1) % histMax }
            if cfg.mode == "fixed" {
                if !inSpeech { inSpeech = true; segStart = frameStart; frameRMS.removeAll() }
                frameRMS.append((frameStart, rms))
                if (pos - segStart) / samplesPerMs >= Int64(cfg.maxSegmentMs) { out.append(cutAtQuietPoint()) }
                i += fl; continue
            }
            let floor = noiseFloor()
            let thr = max(cfg.minRMS, floor * pow(10, cfg.startDb / 20))
            let voiced = rms > thr
            if voiced {
                if !inSpeech {
                    inSpeech = true
                    segStart = max(0, frameStart - Int64(cfg.preRollMs) * samplesPerMs)
                    voicedMs = 0; frameRMS.removeAll()
                }
                lastVoice = pos
                voicedMs += cfg.frameMs
            }
            if inSpeech {
                frameRMS.append((frameStart, rms))
                let silentMs = (pos - lastVoice) / samplesPerMs
                let lenMs = (pos - segStart) / samplesPerMs
                if silentMs >= Int64(cfg.hangoverMs) {
                    if voicedMs >= cfg.minSpeechMs {
                        out.append(SpeechChunk(startSample: segStart, endSample: min(pos, lastVoice + Int64(cfg.hangoverMs / 2) * samplesPerMs)))
                    }
                    inSpeech = false
                } else if lenMs >= Int64(cfg.maxSegmentMs) {
                    out.append(cutAtQuietPoint())
                }
            }
            i += fl
        }
        carry.removeFirst(i)
        return out
    }

    /// Close the open segment at the quietest frame in its last third and
    /// continue a new one from there (no audio is lost between chunks).
    private func cutAtQuietPoint() -> SpeechChunk {
        let tail = frameRMS.suffix(max(1, frameRMS.count / 3))
        let cut = tail.min { $0.1 < $1.1 }!.0
        let c = SpeechChunk(startSample: segStart, endSample: cut)
        segStart = cut
        frameRMS.removeAll { $0.0 < cut }
        voicedMs = cfg.minSpeechMs   // the continuation is speech by construction
        return c
    }

    public func finish() -> [SpeechChunk] {
        defer { inSpeech = false }
        if inSpeech && (cfg.mode == "fixed" || voicedMs >= cfg.minSpeechMs) && pos > segStart { return [SpeechChunk(startSample: segStart, endSample: pos)] }
        return []
    }
}

/// WAV reader for eval input (16-bit PCM; resamples/downmixes if needed).
public enum WAVReader {
    public enum Err: Error { case notWav, unsupported(String) }
    public static func read(_ url: URL) throws -> [Int16] {
        let d = [UInt8](try Data(contentsOf: url))
        guard d.count > 44, String(bytes: d[0..<4], encoding: .ascii) == "RIFF", String(bytes: d[8..<12], encoding: .ascii) == "WAVE" else { throw Err.notWav }
        var off = 12
        var channels = 1, rate = 16000, bits = 16, fmt = 1
        var pcm: [Int16] = []
        while off + 8 <= d.count {
            let id = String(bytes: d[off..<(off + 4)], encoding: .ascii) ?? ""
            let size = Int(d.readLE(UInt32.self, at: off + 4))
            let body = off + 8
            if id == "fmt " {
                fmt = Int(d.readLE(UInt16.self, at: body))
                channels = Int(d.readLE(UInt16.self, at: body + 2))
                rate = Int(d.readLE(UInt32.self, at: body + 4))
                bits = Int(d.readLE(UInt16.self, at: body + 14))
            } else if id == "data" {
                let end = min(d.count, body + size)
                if fmt == 1 && bits == 16 {
                    var i = body
                    while i + 2 * channels <= end {
                        var acc = 0
                        for c in 0..<channels { acc += Int(Int16(bitPattern: d.readLE(UInt16.self, at: i + 2 * c))) }
                        pcm.append(Int16(acc / channels)); i += 2 * channels
                    }
                } else if fmt == 3 && bits == 32 {
                    var i = body
                    while i + 4 * channels <= end {
                        var acc: Float = 0
                        for c in 0..<channels { acc += Float(bitPattern: d.readLE(UInt32.self, at: i + 4 * c)) }
                        pcm.append(Int16(max(-1, min(1, acc / Float(channels))) * 32767)); i += 4 * channels
                    }
                } else { throw Err.unsupported("fmt=\(fmt) bits=\(bits)") }
            }
            off = body + size + (size & 1)
        }
        if rate != Wire.sampleRate { pcm = resample(pcm, from: rate, to: Wire.sampleRate) }
        return pcm
    }

    /// Linear resampler (good enough for speech -> 16 kHz).
    public static func resample(_ x: [Int16], from: Int, to: Int) -> [Int16] {
        guard from != to, !x.isEmpty else { return x }
        let n = Int(Int64(x.count) * Int64(to) / Int64(from))
        var out = [Int16](repeating: 0, count: n)
        let r = Double(from) / Double(to)
        for i in 0..<n {
            let p = Double(i) * r
            let j = Int(p), f = p - Double(j)
            let a = Double(x[min(j, x.count - 1)]), b = Double(x[min(j + 1, x.count - 1)])
            out[i] = Int16(a + (b - a) * f)
        }
        return out
    }

    /// WAV bytes in memory (tests only; Earshot never writes audio to disk).
    public static func encode(_ pcm: [Int16], rate: Int = 16000) -> [UInt8] {
        var o: [UInt8] = Array("RIFF".utf8)
        o.appendLE(UInt32(36 + pcm.count * 2)); o += Array("WAVEfmt ".utf8)
        o.appendLE(UInt32(16)); o.appendLE(UInt16(1)); o.appendLE(UInt16(1)); o.appendLE(UInt32(rate))
        o.appendLE(UInt32(rate * 2)); o.appendLE(UInt16(2)); o.appendLE(UInt16(16))
        o += Array("data".utf8); o.appendLE(UInt32(pcm.count * 2))
        for s in pcm { o.appendLE(s) }
        return o
    }
}
