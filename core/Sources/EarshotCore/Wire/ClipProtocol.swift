import Foundation

/// The clip firmware's protocol (firmware/lib/earshot_core/src/protocol.h, firmware/BLUETOOTH.md).
/// The same messages travel over Bluetooth LE (one per packet) and Wi-Fi (WebSocket at /clip):
///   text    JSON events from the clip (hello, state, consent, marker) and JSON commands to it
///   binary  one audio frame: seq u32 LE, t_ms u32 LE, then one 20 ms frame in the codec named in hello
///
/// This replaces the older ADPCM packet format (Packet.swift, docs/pipeline/WIRE_FORMAT.md) as the live
/// input. The older format stays for replay files and the eval tool.
public enum ClipMessage: Equatable, Sendable {
    case hello(ClipHello)
    case state(listening: Bool, clipMs: Int64)
    /// granted: the medic pressed start (or the tablet sent start) and capture begins.
    /// stopped: the capture ended. Audio frames only arrive between the two.
    case consent(granted: Bool, source: String, clipMs: Int64)
    case marker(id: Int, source: String, clipMs: Int64, audioSeq: Int64)
    case audio(ClipAudioFrame)
}

public struct ClipHello: Equatable, Sendable {
    public var device: String
    public var firmware: String
    public var codec: String          // "opus" | "pcm"
    public var sampleRate: Int
    public var channels: Int
    public var frameMs: Int
    public var bitrate: Int
    public init(device: String, firmware: String, codec: String, sampleRate: Int = 16000, channels: Int = 1, frameMs: Int = 20, bitrate: Int = 0) {
        self.device = device; self.firmware = firmware; self.codec = codec
        self.sampleRate = sampleRate; self.channels = channels; self.frameMs = frameMs; self.bitrate = bitrate
    }
}

public struct ClipAudioFrame: Equatable, Sendable {
    /// Frame counter. Restarts at 0 with every capture; a gap means frames were lost.
    public var seq: UInt32
    /// Clip clock (ms since the clip booted) when the frame was captured.
    public var clipMs: UInt32
    /// One encoded frame (an Opus packet, or 320 int16 LE samples for pcm).
    public var payload: [UInt8]
    public init(seq: UInt32, clipMs: UInt32, payload: [UInt8]) { self.seq = seq; self.clipMs = clipMs; self.payload = payload }
}

public enum ClipCommand: String, Sendable {
    case start, stop, marker
}

public enum ClipProtocol {
    public static let serviceUUID = "E5A70001-7C1B-4F0E-9D52-3A6B8C4D2E10"
    public static let audioUUID = "E5A70002-7C1B-4F0E-9D52-3A6B8C4D2E10"
    public static let eventsUUID = "E5A70003-7C1B-4F0E-9D52-3A6B8C4D2E10"
    public static let commandsUUID = "E5A70004-7C1B-4F0E-9D52-3A6B8C4D2E10"
    public static let audioHeaderBytes = 8
    public static let sampleRate = 16000
    public static let frameMs = 20
    public static let samplesPerFrame = 320

    /// Parses one JSON event from the clip. Unknown or malformed messages return nil (and are ignored).
    public static func parseText(_ text: String) -> ClipMessage? {
        guard let data = text.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = o["type"] as? String else { return nil }
        func int(_ k: String) -> Int64? { (o[k] as? NSNumber)?.int64Value }
        switch type {
        case "hello":
            let a = o["audio"] as? [String: Any] ?? [:]
            func ai(_ k: String, _ d: Int) -> Int { (a[k] as? NSNumber)?.intValue ?? d }
            return .hello(ClipHello(device: o["device"] as? String ?? "clip", firmware: o["fw"] as? String ?? "?",
                                    codec: a["codec"] as? String ?? "opus", sampleRate: ai("rate", 16000), channels: ai("channels", 1),
                                    frameMs: ai("frame_ms", 20), bitrate: ai("bitrate", 0)))
        case "state":
            let listening = (o["listening"] as? Bool) ?? ((o["state"] as? String) == "listening")
            return .state(listening: listening, clipMs: int("t_ms") ?? 0)
        case "consent":
            guard let ev = o["event"] as? String, ev == "granted" || ev == "stopped" else { return nil }
            return .consent(granted: ev == "granted", source: o["source"] as? String ?? "button", clipMs: int("t_ms") ?? 0)
        case "marker":
            guard let t = int("t_ms") else { return nil }
            return .marker(id: Int(int("id") ?? 0), source: o["source"] as? String ?? "button", clipMs: t, audioSeq: int("audio_seq") ?? -1)
        default:
            return nil
        }
    }

    /// Parses one binary audio message (8-byte header + one encoded frame).
    public static func parseAudio(_ bytes: [UInt8]) -> ClipMessage? {
        guard bytes.count > audioHeaderBytes else { return nil }
        func le32(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }
        return .audio(ClipAudioFrame(seq: le32(0), clipMs: le32(4), payload: Array(bytes[audioHeaderBytes...])))
    }

    /// Builds the binary audio message (tests, the mic stand-in, the simulator).
    public static func audioMessage(_ f: ClipAudioFrame) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(audioHeaderBytes + f.payload.count)
        for v in [f.seq, f.clipMs] { for k in 0..<4 { out.append(UInt8((v >> (8 * UInt32(k))) & 0xFF)) } }
        out.append(contentsOf: f.payload)
        return out
    }

    /// JSON command for the clip: {"cmd":"start"}.
    public static func command(_ c: ClipCommand) -> String { "{\"cmd\":\"\(c.rawValue)\"}" }
}

/// Turns one encoded audio frame into 16 kHz mono int16 samples. Opus decoding is platform code
/// (AVAudioConverter on iOS, libopus elsewhere) and lives in the app; pcm is decoded here.
public protocol ClipFrameDecoder: AnyObject {
    var codec: String { get }
    func decode(_ payload: [UInt8]) throws -> [Int16]
    /// Called at the start of each capture: forget decoder state from the last one.
    func reset()
}

public enum ClipDecodeError: Error, Equatable {
    case badLength(Int)
    case unsupportedCodec(String)
}

/// The firmware's raw mode (AUDIO_OPUS_KBPS 0): 320 int16 little-endian samples per frame.
public final class PCMFrameDecoder: ClipFrameDecoder {
    public let codec = "pcm"
    public init() {}
    public func decode(_ p: [UInt8]) throws -> [Int16] {
        guard p.count % 2 == 0 else { throw ClipDecodeError.badLength(p.count) }
        var out = [Int16](repeating: 0, count: p.count / 2)
        for i in 0..<out.count { out[i] = Int16(bitPattern: UInt16(p[2 * i]) | UInt16(p[2 * i + 1]) << 8) }
        return out
    }
    public func reset() {}
    /// Encodes samples as one pcm frame payload (tests and the mic stand-in).
    public static func encode(_ s: [Int16]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.count * 2)
        for v in s { let u = UInt16(bitPattern: v); out.append(UInt8(u & 0xFF)); out.append(UInt8(u >> 8)) }
        return out
    }
}
