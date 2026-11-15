import AVFoundation
import Opus

/// One unbroken stretch of a call's audio on disk: from Start or Resume to Pause, or to a dropped clip.
/// A moment in the transcript is found in it by the clock: `time - start` seconds into the file.
struct Take: Codable {
    var file: String   // its name in the call's audio folder
    var start: Date    // when its first sample was heard
}

/// Keeps a call's audio beside its transcript, so a line can be heard again or read again later.
///
///   clip ──► Opus packets ──────────────► saved as they arrive, nothing re-encoded
///   mic  ──► 16 kHz samples ─► Opus ────► saved
///
/// Each take is one small .opus file (see `OggOpus`): about 15 MB an hour from the clip, 8 MB from the microphone.
final class Tape {
    /// A take has its first audio. On the main queue.
    var onTake: (Call.ID, Take) -> Void = { _, _ in }

    private let queue = DispatchQueue(label: "earshot.tape")   // everything below is touched on this queue only
    private var call: Call.ID?
    private var source = Transcriber.Source.mic
    private var writer: OggOpus.Writer?
    private var encoder: Opus.Encoder?
    private var spare: [Int16] = []   // microphone samples short of a whole 20 ms frame

    private static let pcm = AVAudioFormat(opusPCMFormat: .int16, sampleRate: 16000, channels: 1)!
    private static let frame = 320    // samples in 20 ms

    // MARK: Where the audio lives

    private static let folder = URL.applicationSupportDirectory.appending(path: "audio")
    static func folder(of call: Call.ID) -> URL { folder.appending(path: call.uuidString) }
    static func url(of take: Take, in call: Call.ID) -> URL { folder(of: call).appending(path: take.file) }

    /// Deletes a call's audio. Called when the call itself is deleted.
    static func erase(_ call: Call.ID) { try? FileManager.default.removeItem(at: folder(of: call)) }

    /// Deletes the audio of every call not in `calls`: what a crash or an older build left behind.
    static func keep(only calls: Set<Call.ID>) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where UUID(uuidString: name).map(calls.contains) != true {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    // MARK: Saving

    /// A stretch of audio is starting for this call. Its file is made when the first audio arrives.
    func begin(for call: Call.ID, from source: Transcriber.Source) {
        end()
        queue.async {
            self.call = call
            self.source = source
            self.encoder = source == .mic ? try? Opus.Encoder(format: Self.pcm, application: .voip) : nil
        }
    }

    /// One Opus packet from the clip, and how many were lost on the way just before it.
    func packet(_ opus: Data, lost: Int) {
        let now = Date()
        queue.async {
            guard self.source == .clip, let writer = self.open(at: now.addingTimeInterval(-Double(lost + 1) * 0.02)) else { return }
            for _ in 0..<lost { try? writer.add(OggOpus.gap(like: opus)) }
            try? writer.add(opus)
        }
    }

    /// 16 kHz mono samples from the microphone, from any thread. Ignored while the clip is the source.
    func feed(_ samples: [Int16]) {
        let now = Date()
        queue.async {
            guard self.source == .mic, let writer = self.open(at: now.addingTimeInterval(-Double(samples.count) / 16000)) else { return }
            self.spare += samples
            var at = 0
            while self.spare.count - at >= Self.frame {
                self.encode(self.spare[at..<at + Self.frame], to: writer)
                at += Self.frame
            }
            self.spare.removeFirst(at)
        }
    }

    /// The stretch has ended: its file is finished.
    func end() {
        queue.async {
            if let writer = self.writer {
                if !self.spare.isEmpty {   // the last few milliseconds, filled out with silence
                    self.encode((self.spare + [Int16](repeating: 0, count: Self.frame - self.spare.count))[...], to: writer)
                }
                try? writer.close()
            }
            self.writer = nil
            self.encoder = nil
            self.call = nil
            self.spare = []
        }
    }

    private func encode(_ samples: ArraySlice<Int16>, to writer: OggOpus.Writer) {
        guard let encoder, let buffer = AVAudioPCMBuffer(pcmFormat: Self.pcm, frameCapacity: AVAudioFrameCount(Self.frame)) else { return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.int16ChannelData?[0].update(from: $0.baseAddress!, count: Self.frame) }
        var packet = [UInt8](repeating: 0, count: 1275)   // the most an Opus frame can be
        if let size = try? encoder.encode(buffer, to: &packet), size > 0 { try? writer.add(Data(packet[0..<size])) }
    }

    /// The file being written, made now if this is the stretch's first audio. Nil when there is no stretch.
    private func open(at start: Date) -> OggOpus.Writer? {
        if let writer { return writer }
        guard let call else { return nil }
        let take = Take(file: "\(Int(start.timeIntervalSince1970 * 1000)).opus", start: start)
        do {
            try FileManager.default.createDirectory(at: Self.folder(of: call), withIntermediateDirectories: true)
            // Call audio is patient information: kept out of iCloud backups, and encrypted whenever the device is
            // locked and the file is not being written. A recording carries on while locked, so the open file must too.
            var folder = Self.folder, values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            let url = Self.url(of: take, in: call)
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]) else {
                throw Problem("The file could not be made.")
            }
            writer = try OggOpus.Writer(try FileHandle(forWritingTo: url))
            DispatchQueue.main.async { self.onTake(call, take) }
        } catch {
            print("tape: this stretch's audio is not being saved: \(error.localizedDescription)")
            self.call = nil   // do not try again for every packet
        }
        return writer
    }

    // MARK: Reading back

    /// Part of a take as 16 kHz mono samples, the same audio Whisper was given: from `from` to `to` seconds into it.
    /// Empty when the file is missing or the range lies outside it.
    static func samples(of file: URL, from: TimeInterval, to: TimeInterval) -> [Int16] {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), let decoder = try? Opus.Decoder(format: pcm) else { return [] }
        var out: [Int16] = [], clock = 0   // samples at 48 kHz before the packet in hand
        let first = Int(max(0, from) * 48000), last = Int(to * 48000)
        for packet in OggOpus.packets(in: data) {
            let length = OggOpus.length(of: packet)
            defer { clock += length }
            guard clock < last else { break }
            // The decoder needs a few packets before `from` to settle; their sound is thrown away.
            guard clock + length > first - 4800, let heard = try? decoder.decode(packet), let samples = heard.int16ChannelData?[0] else { continue }
            if clock + length > first { out += UnsafeBufferPointer(start: samples, count: Int(heard.frameLength)) }
        }
        return out
    }
}

/// Plays a few seconds of a call back through the speaker.
final class Speaker: NSObject, AVAudioPlayerDelegate {
    var onDone: () -> Void = {}   // the sound ended by itself

    private var player: AVAudioPlayer?

    /// Plays 16 kHz mono samples. Stops whatever was playing.
    func play(_ quiet: [Int16]) throws {
        stop()
        // The clip's microphone records far below full volume, so what is played is turned up until its loudest
        // moment is near the top (a hundred times at most, so a silent stretch is not turned into a roar of hiss).
        // Only the sound played is changed; the saved audio stays as it was recorded.
        let peak = quiet.reduce(0) { max($0, abs(Int($1))) }
        let gain = min(100, 23000 / Double(max(peak, 1)))
        let samples = gain > 1 ? quiet.map { Int16(max(-32767, min(32767, Double($0) * gain))) } : quiet
        var wav = Data("RIFF".utf8) + bytes(UInt32(36 + samples.count * 2)) + Data("WAVEfmt ".utf8)
        wav += bytes(UInt32(16)) + bytes(UInt16(1)) + bytes(UInt16(1)) + bytes(UInt32(16000)) + bytes(UInt32(32000)) + bytes(UInt16(2)) + bytes(UInt16(16))
        wav += Data("data".utf8) + bytes(UInt32(samples.count * 2)) + samples.withUnsafeBytes { Data($0) }
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        let player = try AVAudioPlayer(data: wav)
        player.delegate = self
        player.play()
        self.player = player
    }

    func stop() {
        guard let player else { return }
        player.stop()
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stop()
        onDone()
    }

    private func bytes<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}
