import Foundation

/// IMA ADPCM (4-bit), matching firmware/common/adpcm.c bit for bit.
/// Block layout (per 20 ms frame): predictor i16 LE, step index u8, reserved
/// u8, then 160 bytes; low nibble first. The block header holds the encoder
/// state *before* the first sample, so each frame decodes independently and
/// a lost frame never desyncs the stream.
public enum IMAADPCM {
    static let indexTable: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]
    static let stepTable: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
        253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
        1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
        3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487,
        12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]

    public struct State: Equatable, Sendable {
        public var predictor: Int = 0
        public var index: Int = 0
        public init(predictor: Int = 0, index: Int = 0) { self.predictor = predictor; self.index = index }
    }

    @inline(__always) static func step(_ code: Int, _ s: inout State) -> Int {
        let st = stepTable[s.index]
        var diff = st >> 3
        if code & 4 != 0 { diff += st }
        if code & 2 != 0 { diff += st >> 1 }
        if code & 1 != 0 { diff += st >> 2 }
        if code & 8 != 0 { s.predictor -= diff } else { s.predictor += diff }
        s.predictor = min(32767, max(-32768, s.predictor))
        s.index = min(88, max(0, s.index + indexTable[code]))
        return s.predictor
    }

    /// Encode exactly `Wire.samplesPerFrame` samples into one 164-byte block.
    public static func encodeBlock(_ pcm: [Int16], state s: inout State) -> [UInt8] {
        precondition(pcm.count % 2 == 0)
        var out: [UInt8] = []
        out.reserveCapacity(4 + pcm.count / 2)
        out.appendLE(Int16(s.predictor))
        out.append(UInt8(s.index)); out.append(0)
        var byte: UInt8 = 0
        for (i, x) in pcm.enumerated() {
            let st = stepTable[s.index]
            var diff = Int(x) - s.predictor
            var code = 0
            if diff < 0 { code = 8; diff = -diff }
            var tmp = st
            if diff >= tmp { code |= 4; diff -= tmp }
            tmp >>= 1
            if diff >= tmp { code |= 2; diff -= tmp }
            tmp >>= 1
            if diff >= tmp { code |= 1 }
            _ = step(code, &s)
            if i & 1 == 0 { byte = UInt8(code) } else { byte |= UInt8(code) << 4; out.append(byte) }
        }
        return out
    }

    /// Decode one block. Returns 2*(count-4) samples.
    public static func decodeBlock(_ block: [UInt8]) -> [Int16] {
        guard block.count > 4 else { return [] }
        var s = State(predictor: Int(Int16(bitPattern: block.readLE(UInt16.self, at: 0))), index: min(88, Int(block[2])))
        var out: [Int16] = []
        out.reserveCapacity((block.count - 4) * 2)
        for b in block[4...] {
            out.append(Int16(step(Int(b & 0x0F), &s)))
            out.append(Int16(step(Int(b >> 4), &s)))
        }
        return out
    }
}
