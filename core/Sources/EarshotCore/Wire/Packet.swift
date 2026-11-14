import Foundation

/// Earshot wire format (see docs/WIRE_FORMAT.md). Little-endian.
/// 7-byte header: type u8, seq u16, clip_ms u32. Then the payload.
public enum PacketType: UInt8, Codable, Sendable {
    case audio = 0x01
    case tap = 0x02
    case state = 0x03
    case clock = 0x04
    case ack = 0x05
}

public enum TapGesture: UInt8, Codable, Sendable, CaseIterable {
    case mark = 0, start = 1, stop = 2, yes = 3, no = 4
    public var name: String { ["mark", "start", "stop", "yes", "no"][Int(rawValue)] }
    public init?(name: String) {
        guard let g = TapGesture.allCases.first(where: { $0.name == name.lowercased() }) else { return nil }
        self = g
    }
}

public enum TapSource: UInt8, Codable, Sendable, CaseIterable {
    /// The clip button is the only tap input on the wire. Raw values 1 and 2
    /// (knock, snap) are retired and decode as invalid. `tablet` never travels on the wire.
    case button = 0, tablet = 3
    public var name: String { self == .button ? "button" : "tablet" }
    public init?(name: String) {
        guard let s = TapSource.allCases.first(where: { $0.name == name.lowercased() }) else { return nil }
        self = s
    }
}

public enum ClipState: UInt8, Codable, Sendable, CaseIterable {
    case off = 0, asking = 1, listening = 2, refused = 3
    public var name: String { ["OFF", "ASKING", "LISTENING", "REFUSED"][Int(rawValue)] }
}

public struct PacketHeader: Equatable, Sendable {
    public static let size = 7
    public var type: PacketType
    public var seq: UInt16
    public var clipMs: UInt32
    public init(type: PacketType, seq: UInt16, clipMs: UInt32) {
        self.type = type; self.seq = seq; self.clipMs = clipMs
    }
}

/// Tap payload: gesture u8, source u8, press_clip_ms u32 (6 bytes).
public struct TapPayload: Equatable, Sendable {
    public static let size = 6
    public var gesture: TapGesture
    public var source: TapSource
    public var pressClipMs: UInt32
    public init(gesture: TapGesture, source: TapSource, pressClipMs: UInt32) {
        self.gesture = gesture; self.source = source; self.pressClipMs = pressClipMs
    }
}

/// State payload.
/// clip -> iPad (3 bytes): state u8, flags u8, proto_version u8.
///   Flags bit0 = USB power, bit1 = battery low, bit2 = tone playing (mic muted).
/// iPad -> clip write (2 bytes): state u8 (only OFF is honoured), flags u8 (ignored).
public struct StatePayload: Equatable, Sendable {
    public var state: ClipState
    public var flags: UInt8
    public var version: UInt8?
    public init(state: ClipState, flags: UInt8 = 0, version: UInt8? = nil) {
        self.state = state; self.flags = flags; self.version = version
    }
    public var usbPower: Bool { flags & 0x01 != 0 }
    public var batteryLow: Bool { flags & 0x02 != 0 }
}

public enum Packet: Equatable, Sendable {
    case audio(PacketHeader, adpcm: [UInt8])
    case tap(PacketHeader, TapPayload)
    case state(PacketHeader, StatePayload)
    case clock(PacketHeader, epochMs: UInt64)
    case ack(PacketHeader, ackedSeq: UInt16)

    public var header: PacketHeader {
        switch self {
        case .audio(let h, _), .tap(let h, _), .state(let h, _), .clock(let h, _), .ack(let h, _): return h
        }
    }
}

public enum WireError: Error, Equatable {
    case tooShort, unknownType(UInt8), badPayload(PacketType)
}

public enum Wire {
    /// ADPCM audio frame: 4-byte block header (predictor i16, step index u8,
    /// reserved u8) + 160 bytes of 4-bit codes = 320 samples (20 ms @ 16 kHz).
    public static let audioPayloadSize = 164
    public static let samplesPerFrame = 320
    public static let sampleRate = 16000
    public static let frameMs: UInt32 = 20
    public static let protocolVersion: UInt8 = 1

    public static func encode(_ p: Packet) -> [UInt8] {
        var out: [UInt8] = []
        let h = p.header
        out.append(h.type.rawValue)
        out.appendLE(h.seq)
        out.appendLE(h.clipMs)
        switch p {
        case .audio(_, let a): out.append(contentsOf: a)
        case .tap(_, let t):
            out.append(t.gesture.rawValue); out.append(t.source.rawValue); out.appendLE(t.pressClipMs)
        case .state(_, let s):
            out.append(s.state.rawValue); out.append(s.flags)
            if let v = s.version { out.append(v) }
        case .clock(_, let e): out.appendLE(e)
        case .ack(_, let s): out.appendLE(s)
        }
        return out
    }

    public static func decode(_ b: [UInt8]) throws -> Packet {
        guard b.count >= PacketHeader.size else { throw WireError.tooShort }
        guard let type = PacketType(rawValue: b[0]) else { throw WireError.unknownType(b[0]) }
        let h = PacketHeader(type: type, seq: b.readLE(UInt16.self, at: 1), clipMs: b.readLE(UInt32.self, at: 3))
        let p = Array(b[PacketHeader.size...])
        switch type {
        case .audio:
            guard p.count == audioPayloadSize else { throw WireError.badPayload(type) }
            return .audio(h, adpcm: p)
        case .tap:
            guard p.count >= TapPayload.size, let g = TapGesture(rawValue: p[0]), let s = TapSource(rawValue: p[1])
            else { throw WireError.badPayload(type) }
            return .tap(h, TapPayload(gesture: g, source: s, pressClipMs: p.readLE(UInt32.self, at: 2)))
        case .state:
            guard p.count >= 2, let st = ClipState(rawValue: p[0]) else { throw WireError.badPayload(type) }
            return .state(h, StatePayload(state: st, flags: p[1], version: p.count >= 3 ? p[2] : nil))
        case .clock:
            guard p.count >= 8 else { throw WireError.badPayload(type) }
            return .clock(h, epochMs: p.readLE(UInt64.self, at: 0))
        case .ack:
            guard p.count >= 2 else { throw WireError.badPayload(type) }
            return .ack(h, ackedSeq: p.readLE(UInt16.self, at: 0))
        }
    }

    /// Stream framing for Wi-Fi TCP and replay files: u16 LE length + packet.
    public static func frame(_ p: Packet) -> [UInt8] {
        let body = encode(p)
        var out: [UInt8] = []
        out.appendLE(UInt16(body.count))
        out.append(contentsOf: body)
        return out
    }
}

/// Incremental deframer for length-prefixed streams.
public struct StreamDeframer {
    private var buf: [UInt8] = []
    public init() {}
    public mutating func push(_ bytes: [UInt8]) -> [Packet] {
        buf.append(contentsOf: bytes)
        var out: [Packet] = []
        var off = 0
        while buf.count - off >= 2 {
            let len = Int(buf.readLE(UInt16.self, at: off))
            guard buf.count - off - 2 >= len else { break }
            if let p = try? Wire.decode(Array(buf[(off + 2)..<(off + 2 + len)])) { out.append(p) }
            off += 2 + len
        }
        if off > 0 { buf.removeFirst(off) }
        return out
    }
}

extension Array where Element == UInt8 {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    func readLE<T: FixedWidthInteger>(_: T.Type, at i: Int) -> T {
        var v: T = 0
        for k in 0..<MemoryLayout<T>.size { v |= T(self[i + k]) << (8 * k) }
        return v
    }
}
