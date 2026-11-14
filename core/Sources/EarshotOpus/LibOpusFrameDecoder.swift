import Foundation
import EarshotCore
import COpus

/// Opus frames from the clip, decoded with libopus (macOS and Linux: the eval tool and tests).
/// The iPad app decodes with AVAudioConverter instead (app/Earshot/Clip/OpusDecoder.swift).
public final class LibOpusFrameDecoder: ClipFrameDecoder {
    public let codec = "opus"
    private var dec: OpaquePointer?
    private let rate: Int32
    private var out: [Int16]

    public init(sampleRate: Int = ClipProtocol.sampleRate) throws {
        rate = Int32(sampleRate)
        out = [Int16](repeating: 0, count: sampleRate * 120 / 1000)   // the longest Opus frame, 120 ms
        var err: Int32 = 0
        dec = opus_decoder_create(rate, 1, &err)
        guard err == OPUS_OK, dec != nil else { throw ClipDecodeError.unsupportedCodec("opus (libopus error \(err))") }
    }
    deinit { if let d = dec { opus_decoder_destroy(d) } }

    public func decode(_ payload: [UInt8]) throws -> [Int16] {
        guard let d = dec, !payload.isEmpty else { throw ClipDecodeError.badLength(payload.count) }
        let n = payload.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { o in
                opus_decode(d, p.baseAddress!, Int32(p.count), o.baseAddress!, Int32(o.count), 0)
            }
        }
        guard n > 0 else { throw ClipDecodeError.badLength(payload.count) }
        return Array(out[0..<Int(n)])
    }

    public func reset() {
        // OPUS_RESET_STATE is a variadic ctl that Swift cannot call, so start a fresh decoder.
        if let d = dec { opus_decoder_destroy(d) }
        var err: Int32 = 0
        dec = opus_decoder_create(rate, 1, &err)
    }
}

/// Encoder for tests (same settings as the firmware: 16 kHz mono, 20 ms, constant bitrate).
public final class LibOpusFrameEncoder {
    private var enc: OpaquePointer?
    public init(bitrate: Int32 = 32000) throws {
        var err: Int32 = 0
        enc = opus_encoder_create(16000, 1, OPUS_APPLICATION_VOIP, &err)
        guard err == OPUS_OK, enc != nil else { throw ClipDecodeError.unsupportedCodec("opus encoder \(err)") }
        _ = bitrate   // libopus picks a bitrate near 32 kbit/s for 16 kHz VOIP by default; ctl calls are variadic
    }
    deinit { if let e = enc { opus_encoder_destroy(e) } }
    public func encode(_ frame: [Int16]) throws -> [UInt8] {
        guard let e = enc, !frame.isEmpty else { throw ClipDecodeError.badLength(frame.count) }
        var buf = [UInt8](repeating: 0, count: 400)
        let n = frame.withUnsafeBufferPointer { f in
            buf.withUnsafeMutableBufferPointer { b in opus_encode(e, f.baseAddress!, Int32(f.count), b.baseAddress!, Int32(b.count)) }
        }
        guard n > 0 else { throw ClipDecodeError.badLength(Int(n)) }
        return Array(buf[0..<Int(n)])
    }
}
