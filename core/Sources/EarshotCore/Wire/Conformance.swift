import Foundation

/// Checks a packet capture from a clip against docs/FIRMWARE_CONTRACT.md.
/// Feed it the clip -> iPad stream (a Wi-Fi TCP capture is already in replay
/// format: `nc 192.168.4.1 7070 > capture.replay`). Check ids match the contract.
public struct ConformanceReport: Codable, Sendable {
    public struct Check: Codable, Sendable {
        public var id: String
        public var pass: Bool
        public var detail: String
    }
    public var pass: Bool
    public var checks: [Check]
    public var stats: [String: Double]
}

public enum StreamConformance {
    public static func check(rawBytes: [UInt8]) -> ConformanceReport {
        // decode frame by frame so undecodable packets are counted, not dropped
        var packets: [Packet] = []
        var bad = 0, off = 0
        while rawBytes.count - off >= 2 {
            let len = Int(rawBytes.readLE(UInt16.self, at: off))
            guard rawBytes.count - off - 2 >= len else { break }
            if let p = try? Wire.decode(Array(rawBytes[(off + 2)..<(off + 2 + len)])) { packets.append(p) } else { bad += 1 }
            off += 2 + len
        }
        let trailing = rawBytes.count - off
        return check(packets: packets, undecodable: bad, trailingBytes: trailing)
    }

    public static func check(packets: [Packet], undecodable: Int = 0, trailingBytes: Int = 0) -> ConformanceReport {
        var checks: [ConformanceReport.Check] = []
        func add(_ id: String, _ ok: Bool, _ detail: String) { checks.append(.init(id: id, pass: ok, detail: detail)) }

        add("W1", undecodable == 0 && trailingBytes == 0, "\(packets.count) packets decoded, \(undecodable) undecodable, \(trailingBytes) trailing bytes")
        let states = packets.compactMap { p -> (UInt32, StatePayload)? in if case .state(let h, let s) = p { return (h.clipMs, s) }; return nil }
        let versions = Set(states.compactMap { $0.1.version })
        add("W2", !states.isEmpty && states.allSatisfy { $0.1.version != nil } && versions == [Wire.protocolVersion],
            "state packets: \(states.count); versions seen: \(versions.sorted())")

        // walk the stream: consent gate and gesture legality
        var state: ClipState = .off
        var sawState = false
        var audioOutsideListening = 0, illegalTransitions: [String] = [], marksOutside = 0
        var lastTapGesture: [UInt16: TapGesture] = [:]
        var tapSends: [UInt16: Int] = [:]
        var pressLag: [Int64] = []
        var badPress = 0
        var audio: [(seq: Int64, clip: UInt32)] = []
        var unwrap = SeqUnwrapper()
        var stateTimes: [UInt32] = []
        var audioBytes = 0
        for p in packets {
            switch p {
            case .state(let h, let s):
                if sawState || s.state != .off {
                    let ok: Bool
                    switch (state, s.state) {
                    case (let a, let b) where a == b: ok = true
                    case (.off, .asking), (.asking, .listening), (.asking, .off), (.asking, .refused), (.refused, .off), (.listening, .off): ok = true
                    default: ok = !sawState   // first state packet may be anything (capture started mid-call)
                    }
                    if !ok { illegalTransitions.append("\(state.name)->\(s.state.name)@\(h.clipMs)") }
                }
                state = s.state; sawState = true; stateTimes.append(h.clipMs)
            case .audio(let h, let a):
                audioBytes += Wire.encode(p).count
                _ = a
                if state != .listening { audioOutsideListening += 1 }
                audio.append((unwrap.unwrap(h.seq), h.clipMs))
            case .tap(let h, let t):
                tapSends[h.seq, default: 0] += 1
                if let g = lastTapGesture[h.seq], g != t.gesture { illegalTransitions.append("tap seq \(h.seq) reused for a different gesture") }
                lastTapGesture[h.seq] = t.gesture
                if t.gesture == .mark && state != .listening && tapSends[h.seq] == 1 { marksOutside += 1 }
                let lag = Int64(h.clipMs) - Int64(t.pressClipMs)
                if lag < 0 || lag > 3000 { if tapSends[h.seq] == 1 { badPress += 1 } } else { pressLag.append(lag) }
            case .clock, .ack:
                illegalTransitions.append("clip sent an iPad->clip packet type")
            }
        }
        add("C1", audioOutsideListening == 0, "\(audioOutsideListening) audio packets while not LISTENING (consent gate)")
        add("C2", illegalTransitions.isEmpty, illegalTransitions.isEmpty ? "state transitions legal" : illegalTransitions.prefix(5).joined(separator: "; "))
        add("T1", marksOutside == 0, "\(marksOutside) mark taps outside LISTENING")
        add("T2", badPress == 0, "\(badPress) taps with press time after the packet time or > 3 s before it")

        // audio continuity and pacing
        var gaps = 0, missing = 0, dupes = 0, badSpacing = 0
        var seen = Set<Int64>()
        var prev: (Int64, UInt32)? = nil
        for f in audio {
            if seen.contains(f.seq) { dupes += 1; continue }
            seen.insert(f.seq)
            if let p = prev, f.seq > p.0 {
                if f.seq != p.0 + 1 { gaps += 1; missing += Int(f.seq - p.0 - 1) }
                let expect = Int64(f.seq - p.0) * 20
                if abs(Int64(f.clip &- p.1) - expect) > 5 { badSpacing += 1 }
            }
            if prev == nil || f.seq > prev!.0 { prev = (f.seq, f.clip) }
        }
        let frames = seen.count
        let lossPct = frames + missing > 0 ? Double(missing) / Double(frames + missing) * 100 : 0
        add("A1", lossPct < 1.0, String(format: "%d frames, %d gaps, %d missing (%.2f%% loss), %d resent duplicates", frames, gaps, missing, lossPct, dupes))
        add("A2", badSpacing == 0, "\(badSpacing) frames whose clip_ms is not 20 ms x seq step (±5 ms)")
        // state heartbeat while connected
        var maxStateGap: UInt32 = 0
        for i in stride(from: 1, to: stateTimes.count, by: 1) { maxStateGap = max(maxStateGap, stateTimes[i] &- stateTimes[i - 1]) }
        add("S1", stateTimes.count >= 1 && maxStateGap <= 5000, "max gap between state packets \(maxStateGap) ms (<= 5000)")
        let durS = audio.count > 1 ? Double(audio.last!.clip &- audio.first!.clip) / 1000 : 0
        let kbps = durS > 0 ? Double(audioBytes * 8) / durS / 1000 : 0
        let resent = tapSends.values.filter { $0 > 1 }.count
        let stats: [String: Double] = ["packets": Double(packets.count), "audio_frames": Double(frames), "audio_kbps": (kbps * 10).rounded() / 10,
                                        "loss_pct": (lossPct * 100).rounded() / 100, "taps": Double(tapSends.count), "taps_resent": Double(resent),
                                        "tap_press_lag_ms_max": Double(pressLag.max() ?? 0), "duration_s": durS]
        return ConformanceReport(pass: checks.allSatisfy(\.pass), checks: checks, stats: stats)
    }
}
