import Foundation
import whisper

/// A Whisper model, loaded once and used for every chunk. whisper.cpp runs one chunk at a time, so calls take turns.
public final class Whisper {
    public let name: String
    /// How many candidate sentences Whisper keeps while it writes. 1 is fastest; more is a little more accurate.
    public var beam: Int32 = 5
    /// Read a chunk again with more freedom when the first reading looks wrong. Slower on noisy audio.
    public var retries = true

    private let context: OpaquePointer
    private let threads: Int32
    private let lock = NSLock()
    private var bias: Bias?

    /// - gpu: use the graphics chip, which is several times faster on an iPad or a Mac.
    public init(model: URL, gpu: Bool = true) throws {
        var params = whisper_context_default_params()
        params.use_gpu = gpu
        guard let c = whisper_init_from_file_with_params(model.path, params) else {
            throw NSError(domain: "earshot.whisper", code: 1, userInfo: [NSLocalizedDescriptionKey: "The Whisper model at \(model.path) could not be loaded."])
        }
        context = c
        threads = Int32(min(4, max(2, ProcessInfo.processInfo.activeProcessorCount - 2)))
        name = model.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "")
    }

    deinit { whisper_free(context) }

    /// Leans Whisper toward these words while it writes (see `Bias`). An empty list turns it off.
    public func lean(toward words: [String]) {
        // Each word as Whisper would write it: after a space, in lower case and capitalised.
        let phrases = words.flatMap { [" " + $0, " " + $0.prefix(1).uppercased() + $0.dropFirst()] }
        var buffer = [whisper_token](repeating: 0, count: 64)
        let sequences: [[Int32]] = phrases.compactMap { phrase in
            let n = phrase.withCString { whisper_tokenize(context, $0, &buffer, Int32(buffer.count)) }
            return n > 0 ? Array(buffer[0..<Int(n)]) : nil
        }
        lock.withLock { bias = sequences.isEmpty ? nil : Bias(sequences: sequences, textLimit: whisper_token_eot(context)) }
    }

    /// Reads one chunk of 16 kHz mono audio. Returns its word-pieces, timed from the start of the chunk.
    public func read(_ samples: [Int16]) throws -> [Piece] {
        try lock.withLock {
            let first = try decode(samples, retries: retries)
            // In noise the freer second reading can come back as music notes or nothing. Read it plainly once more.
            guard retries, !first.isEmpty, !first.contains(where: { $0.text.contains { $0.isLetter || $0.isNumber } }) else { return first }
            let plain = try decode(samples, retries: false)
            return plain.contains { $0.text.contains { $0.isLetter || $0.isNumber } } ? plain : first
        }
    }

    private func decode(_ samples: [Int16], retries: Bool) throws -> [Piece] {
        var audio = samples.map { Float($0) / 32768 }
        if audio.count < 17_600 { audio += [Float](repeating: 0, count: 17_600 - audio.count) }   // Whisper needs over a second
        var p = whisper_full_default_params(beam > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        if beam > 1 { p.beam_search.beam_size = beam }
        p.n_threads = threads
        p.print_progress = false
        p.print_realtime = false
        p.print_timestamps = false
        p.print_special = false
        p.translate = false
        p.no_context = true              // each chunk is read on its own, so one bad chunk cannot colour the next
        p.single_segment = false
        p.temperature = 0
        p.temperature_inc = retries ? 0.2 : 0
        p.token_timestamps = true        // a time for every word-piece
        p.suppress_blank = true
        p.suppress_nst = true            // no "[music]" or "♪"
        p.no_timestamps = false
        if let bias {
            p.logits_filter_callback = { _, _, tokens, count, logits, user in
                guard let user, let logits else { return }
                let bias = Unmanaged<Bias>.fromOpaque(user).takeUnretainedValue()
                var written: [Int32] = []
                if let tokens, count > 0 { for i in 0..<Int(count) { written.append(tokens[i].id) } }
                for (token, bonus) in bias.bonuses(after: written) { logits[Int(token)] += bonus }
            }
            p.logits_filter_callback_user_data = Unmanaged.passUnretained(bias).toOpaque()
        }
        let result: Int32 = "en".withCString { language in
            p.language = language
            return audio.withUnsafeBufferPointer { whisper_full(context, p, $0.baseAddress, Int32($0.count)) }
        }
        guard result == 0 else {
            throw NSError(domain: "earshot.whisper", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "Whisper could not read a chunk (\(result))."])
        }
        var pieces: [Piece] = []
        let end = whisper_token_eot(context)
        for s in 0..<whisper_full_n_segments(context) {
            for t in 0..<whisper_full_n_tokens(context, s) {
                let data = whisper_full_get_token_data(context, s, t)
                guard data.id < end else { continue }   // timestamps and other special tokens carry no text
                pieces.append(Piece(text: String(cString: whisper_full_get_token_text(context, s, t)),
                                    startMs: Int64(data.t0) * 10, endMs: Int64(data.t1) * 10, probability: Double(data.p)))
            }
        }
        return pieces
    }
}
