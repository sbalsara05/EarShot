import AVFoundation
import EarshotCore

/// Decodes the clip's Opus frames (16 kHz mono, 20 ms, one packet per frame) with the system's
/// Opus decoder. Not yet tried on a device: if it fails, the pipeline counts the frames as
/// undecodable and they show as gaps. The pipeline's libopus decoder (core/Sources/EarshotOpus)
/// is tested and could be built for iOS instead.
final class OpusFrameDecoder: ClipFrameDecoder {
    let codec = "opus"
    private let input: AVAudioFormat
    private let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let converter: AVAudioConverter

    init() throws {
        var asbd = AudioStreamBasicDescription(mSampleRate: 16000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                               mFramesPerPacket: 320, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let f = AVAudioFormat(streamDescription: &asbd), let c = AVAudioConverter(from: f, to: output) else {
            throw ClipDecodeError.unsupportedCodec("opus")
        }
        input = f
        converter = c
    }

    func decode(_ payload: [UInt8]) throws -> [Int16] {
        guard !payload.isEmpty else { throw ClipDecodeError.badLength(0) }
        let packet = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: payload.count)
        payload.withUnsafeBytes { packet.data.copyMemory(from: $0.baseAddress!, byteCount: payload.count) }
        packet.byteLength = UInt32(payload.count)
        packet.packetCount = 1
        packet.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                          mDataByteSize: UInt32(payload.count))
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 1920) else { throw ClipDecodeError.badLength(payload.count) }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, s in
            if fed { s.pointee = .noDataNow; return nil }
            fed = true
            s.pointee = .haveData
            return packet
        }
        guard status != .error, error == nil, let ch = out.int16ChannelData, out.frameLength > 0 else {
            throw ClipDecodeError.badLength(payload.count)
        }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    func reset() { converter.reset() }
}
