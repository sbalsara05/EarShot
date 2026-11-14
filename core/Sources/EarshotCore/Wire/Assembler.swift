import Foundation

/// A tap as seen by the pipeline (from the clip, the tablet, or a tap file).
public struct TapInput: Codable, Equatable, Sendable {
    public var clipMs: Int64
    public var source: String          // button | tablet (older tap files may say knock/snap: treated like any tap)
    public var gesture: String         // mark | start | stop | yes | no | arrival | handoff
    public var seq: Int?
    public init(clipMs: Int64, source: String, gesture: String = "mark", seq: Int? = nil) {
        self.clipMs = clipMs; self.source = source; self.gesture = gesture; self.seq = seq
    }
    enum CodingKeys: String, CodingKey { case clipMs = "clip_ms", source, gesture, seq }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        clipMs = try c.decode(Int64.self, forKey: .clipMs)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "button"
        gesture = try c.decodeIfPresent(String.self, forKey: .gesture) ?? "mark"
        seq = try c.decodeIfPresent(Int.self, forKey: .seq)
    }
}

public struct AudioGap: Equatable, Sendable, Codable {
    public var startClipMs: Int64
    public var endClipMs: Int64
    public var missingFrames: Int
}

/// Unwraps 16-bit sequence numbers into a monotonic Int64.
public struct SeqUnwrapper {
    private var last: Int64?
    public init() {}
    public mutating func unwrap(_ s: UInt16) -> Int64 {
        guard let l = last else { last = Int64(s); return Int64(s) }
        let base = l & ~0xFFFF
        var cand = base | Int64(s)
        if cand - l > 0x8000 { cand -= 0x10000 } else if l - cand > 0x8000 { cand += 0x10000 }
        last = max(l, cand)
        return cand
    }
}

/// Reorders audio frames by sequence number, drops duplicates (resends after
/// a link drop), decodes ADPCM and emits contiguous 16 kHz PCM. Missing frames
/// become silence plus an `AudioGap`. Audio is only ever held in memory.
public final class AudioAssembler {
    public private(set) var gaps: [AudioGap] = []
    public private(set) var taps: [TapInput] = []
    public private(set) var states: [(clipMs: Int64, state: ClipState)] = []
    public private(set) var clockOffsets: [(clipMs: Int64, epochMs: Int64)] = []
    public private(set) var firstClipMs: Int64?
    public private(set) var framesReceived = 0
    public private(set) var duplicates = 0

    private var unwrapAudio = SeqUnwrapper()
    private var unwrapTap = SeqUnwrapper()
    private var pending: [Int64: (clipMs: Int64, block: [UInt8])] = [:]
    private var nextSeq: Int64?
    private var seenTaps = Set<Int64>()
    private let reorderDepth: Int

    /// - reorderDepth: frames to wait for a late frame before declaring a gap
    ///   (10 frames = 200 ms). Use Int.max for offline (replay) assembly.
    public init(reorderDepth: Int = 10) { self.reorderDepth = reorderDepth }

    /// Push a packet; returns PCM that became contiguous.
    @discardableResult
    public func push(_ p: Packet) -> [Int16] {
        switch p {
        case .audio(let h, let a):
            let s = unwrapAudio.unwrap(h.seq)
            if let n = nextSeq, s < n { duplicates += 1; return [] }
            if pending[s] != nil { duplicates += 1; return [] }
            if firstClipMs == nil { firstClipMs = Int64(h.clipMs) }
            if nextSeq == nil { nextSeq = s }
            pending[s] = (Int64(h.clipMs), a)
            framesReceived += 1
            return drain(force: false)
        case .tap(let h, let t):
            let s = unwrapTap.unwrap(h.seq)
            if seenTaps.contains(s) { return [] } // resend until ack: dedupe
            seenTaps.insert(s)
            taps.append(TapInput(clipMs: Int64(t.pressClipMs), source: t.source.name, gesture: t.gesture.name, seq: Int(h.seq)))
            return []
        case .state(let h, let st):
            states.append((Int64(h.clipMs), st.state))
            return []
        case .clock(let h, let e):
            clockOffsets.append((Int64(h.clipMs), Int64(e)))
            return []
        case .ack:
            return []
        }
    }

    /// Flush everything still pending (end of stream).
    public func finish() -> [Int16] { drain(force: true) }

    private func drain(force: Bool) -> [Int16] {
        var out: [Int16] = []
        guard var n = nextSeq else { return out }
        while !pending.isEmpty {
            if let f = pending.removeValue(forKey: n) {
                out.append(contentsOf: IMAADPCM.decodeBlock(f.block))
                n += 1
                continue
            }
            // frame n missing: wait unless forced or buffer is deep enough
            guard force || pending.count >= reorderDepth else { break }
            guard let nextAvail = pending.keys.min() else { break }
            let missing = Int(nextAvail - n)
            let endClip = pending[nextAvail]!.clipMs
            let startClip = endClip - Int64(missing) * Int64(Wire.frameMs)
            gaps.append(AudioGap(startClipMs: startClip, endClipMs: endClip, missingFrames: missing))
            out.append(contentsOf: [Int16](repeating: 0, count: missing * Wire.samplesPerFrame))
            n = nextAvail
        }
        nextSeq = n
        return out
    }
}

/// Replay file = concatenated length-prefixed packets (same framing as Wi-Fi).
public enum ReplayFile {
    public static func read(_ url: URL) throws -> [Packet] {
        let data = try Data(contentsOf: url)
        var d = StreamDeframer()
        return d.push([UInt8](data))
    }
    #if !os(iOS)
    /// Eval tooling only (earshot-eval make-replay). Not compiled into the iPad app,
    /// which never writes audio to disk.
    public static func write(_ packets: [Packet], to url: URL) throws {
        var out: [UInt8] = []
        for p in packets { out.append(contentsOf: Wire.frame(p)) }
        try Data(out).write(to: url)
    }
    #endif
    /// Build a replay stream from PCM + taps (used by tests and mock generation).
    /// Build a contract-conformant clip stream from PCM + taps (tests, mocks,
    /// fake-clip): consent flow (ASKING + start tap, yes tap + LISTENING) before
    /// the first audio frame, a state heartbeat every 2 s, then stop tap + OFF.
    /// Consent gestures in `taps` are ignored; the generator plays that part.
    public static func packets(fromPCM pcm: [Int16], taps: [TapInput] = [], startClipMs: UInt32 = 1000) -> [Packet] {
        var out: [Packet] = []
        var st = IMAADPCM.State()
        var seq: UInt16 = 0
        var tapSeq: UInt16 = 0
        var stateSeq: UInt16 = 0
        var i = 0
        let t0 = max(startClipMs, 400)
        func state(_ s: ClipState, _ clip: UInt32) {
            out.append(.state(PacketHeader(type: .state, seq: stateSeq, clipMs: clip), StatePayload(state: s, flags: 1, version: Wire.protocolVersion)))
            stateSeq &+= 1
        }
        func tap(_ g: TapGesture, _ src: TapSource, press: UInt32, at clip: UInt32) {
            out.append(.tap(PacketHeader(type: .tap, seq: tapSeq, clipMs: clip), TapPayload(gesture: g, source: src, pressClipMs: press)))
            tapSeq &+= 1
        }
        state(.off, t0 - 400)
        tap(.start, .button, press: t0 - 400, at: t0 - 400); state(.asking, t0 - 400)
        tap(.yes, .button, press: t0 - 200, at: t0 - 200); state(.listening, t0 - 200)
        var pendingTaps = taps.filter { !["start", "yes", "no", "stop"].contains($0.gesture) && TapGesture(name: $0.gesture) != nil }
            .sorted { $0.clipMs < $1.clipMs }
        var lastState = t0 - 200
        var clip = t0
        while i + Wire.samplesPerFrame <= pcm.count {
            clip = t0 &+ UInt32(i / 16)
            while let t = pendingTaps.first, t.clipMs <= Int64(clip) {
                pendingTaps.removeFirst()
                tap(TapGesture(name: t.gesture) ?? .mark, TapSource(name: t.source) ?? .button, press: UInt32(t.clipMs), at: clip)
            }
            if clip - lastState >= 2000 { state(.listening, clip); lastState = clip }
            let block = IMAADPCM.encodeBlock(Array(pcm[i..<(i + Wire.samplesPerFrame)]), state: &st)
            out.append(.audio(PacketHeader(type: .audio, seq: seq, clipMs: clip), adpcm: block))
            seq &+= 1
            i += Wire.samplesPerFrame
        }
        let end = clip + 20
        for t in pendingTaps where t.clipMs <= Int64(end) + 3000 {   // marks just after the last frame
            tap(TapGesture(name: t.gesture) ?? .mark, TapSource(name: t.source) ?? .button, press: UInt32(t.clipMs), at: max(end, UInt32(t.clipMs)))
        }
        tap(.stop, .button, press: end, at: end); state(.off, end)
        return out
    }
}
