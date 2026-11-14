import Foundation
import EarshotCore
#if canImport(CWhisper)
import CWhisper
#else
import whisper   // iOS: whisper.xcframework module
#endif

/// whisper.cpp through its C API. Default: beam search 5 with temperature
/// fallback (whisper.cpp seeds its sampler, so runs repeat), token timestamps,
/// fixed thread count. `beamSize: 1, temperatureFallback: false` = greedy (fastest).
public final class WhisperTranscriber: Transcriber {
    public let modelName: String
    private let ctx: OpaquePointer
    private let threads: Int32

    public var beamSize: Int32 = 5
    public var temperatureFallback = true

    public init(modelPath: String, name: String? = nil, threads: Int = 4, beamSize: Int = 5, temperatureFallback: Bool = true) throws {
        var cp = whisper_context_default_params()
        cp.use_gpu = false
        guard let c = whisper_init_from_file_with_params(modelPath, cp) else {
            throw NSError(domain: "earshot.whisper", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot load whisper model at \(modelPath)"])
        }
        ctx = c
        self.threads = Int32(threads)
        self.beamSize = Int32(max(1, beamSize))
        self.temperatureFallback = temperatureFallback
        let base = URL(fileURLWithPath: modelPath).lastPathComponent
        modelName = name ?? "whisper.cpp \(base.replacingOccurrences(of: "ggml-", with: "").replacingOccurrences(of: ".bin", with: ""))"
    }

    deinit { whisper_free(ctx) }

    /// Decodes a chunk. If the result has no speech at all (Whisper's "♪♪♪" in noise,
    /// often from temperature fallback), the chunk is decoded once more at
    /// temperature 0 with no fallback, and that result is kept when it has words.
    public func transcribe(_ pcm: [Float], prompt: String?) throws -> [ASRPiece] {
        let first = try decode(pcm, prompt: prompt, fallback: temperatureFallback)
        guard temperatureFallback, !first.isEmpty, first.allSatisfy({ ASRFilter.isHallucination($0.text) }) else { return first }
        let retry = try decode(pcm, prompt: prompt, fallback: false)
        return retry.contains(where: { !ASRFilter.isHallucination($0.text) }) ? retry : first
    }

    private func decode(_ pcm: [Float], prompt: String?, fallback: Bool) throws -> [ASRPiece] {
        // whisper needs >= 1 s of audio; pad short chunks with silence
        var audio = pcm
        if audio.count < 16000 + 1600 { audio += [Float](repeating: 0, count: 16000 + 1600 - audio.count) }
        var p = whisper_full_default_params(beamSize > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        if beamSize > 1 { p.beam_search.beam_size = beamSize }
        p.n_threads = threads
        p.print_progress = false
        p.print_realtime = false
        p.print_timestamps = false
        p.print_special = false
        p.translate = false
        p.no_context = true
        p.single_segment = false
        p.temperature = 0
        p.temperature_inc = fallback ? 0.2 : 0   // fallback re-decodes low-confidence windows; whisper.cpp seeds its RNG, so runs repeat
        p.token_timestamps = true
        p.suppress_blank = true
        p.suppress_nst = true
        p.no_timestamps = false
        let rc: Int32 = "en".withCString { lang in
            p.language = lang
            if let prompt = prompt {
                return prompt.withCString { pp in
                    p.initial_prompt = pp
                    return audio.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
                }
            }
            return audio.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
        }
        guard rc == 0 else {
            throw NSError(domain: "earshot.whisper", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: "whisper_full failed (\(rc))"])
        }
        var out: [ASRPiece] = []
        let n = whisper_full_n_segments(ctx)
        for i in 0..<n {
            let text = String(cString: whisper_full_get_segment_text(ctx, i))
            let t0 = Int64(whisper_full_get_segment_t0(ctx, i)) * 10
            let t1 = Int64(whisper_full_get_segment_t1(ctx, i)) * 10
            var lp = 0.0
            let nt = whisper_full_n_tokens(ctx, i)
            var cnt = 0
            var toks: [ASRToken] = []
            var offset = 0
            let eot = whisper_token_eot(ctx)
            for k in 0..<nt {
                let d = whisper_full_get_token_data(ctx, i, k)
                lp += Double(d.plog); cnt += 1
                let piece = String(cString: whisper_full_get_token_text(ctx, i, k))
                if d.id >= eot { continue }                       // special / timestamp tokens carry no text
                let lead = piece.prefix { $0.isWhitespace }.count  // time the word, not its leading space
                if !piece.trimmingCharacters(in: .whitespaces).isEmpty {
                    toks.append(ASRToken(charOffset: offset + lead, startMs: Int64(d.t0) * 10, endMs: Int64(d.t1) * 10))
                }
                offset += piece.count
            }
            out.append(ASRPiece(startMs: t0, endMs: t1, text: text, avgLogprob: cnt > 0 ? (lp / Double(cnt) * 1000).rounded() / 1000 : nil, tokens: toks))
        }
        return out
    }
}
