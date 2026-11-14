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
    /// Contextual biasing toward drug names (see BiasTrie). Nil: off.
    public private(set) var bias: BiasTrie?

    /// Tokenizes `phrases` with this model's tokenizer and biases decoding toward them.
    /// Returns the number of phrases in the tree.
    @discardableResult
    public func setBias(phrases: [String], firstBonus: Double, nextBonus: Double) -> Int {
        guard !phrases.isEmpty, firstBonus != 0 || nextBonus != 0 else { bias = nil; return 0 }
        var seqs: [[Int32]] = []
        var buf = [whisper_token](repeating: 0, count: 64)
        for ph in phrases {
            let n = ph.withCString { whisper_tokenize(ctx, $0, &buf, Int32(buf.count)) }
            if n > 0 { seqs.append(Array(buf[0..<Int(n)])) }
        }
        bias = BiasTrie(sequences: seqs, firstBonus: Float(firstBonus), nextBonus: Float(nextBonus), textTokenLimit: whisper_token_eot(ctx))
        return bias?.phraseCount ?? 0
    }

    /// - useGPU: Metal on Apple silicon (much faster). Off by default so CPU runs repeat exactly;
    ///   GPU results can differ in the last digits, so compare runs made the same way.
    public init(modelPath: String, name: String? = nil, threads: Int = 4, beamSize: Int = 5, temperatureFallback: Bool = true,
                useGPU: Bool = false) throws {
        _ = Self.loadBackends
        var cp = whisper_context_default_params()
        cp.use_gpu = useGPU
        guard let c = whisper_init_from_file_with_params(modelPath, cp) else {
            throw NSError(domain: "earshot.whisper", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot load whisper model at \(modelPath)"])
        }
        ctx = c
        self.threads = Int32(threads)
        self.beamSize = Int32(max(1, beamSize))
        self.temperatureFallback = temperatureFallback
        modelName = name ?? ASRModel.name(forModelFile: modelPath)
    }

    /// A ggml built with dynamic backends (Homebrew whisper.cpp 1.8+, Linux packages) loads its CPU and
    /// Metal backends as plugins; without this whisper finds no device. The iOS xcframework links them in.
    private static let loadBackends: Void = {
        #if canImport(CWhisper)
        ggml_backend_load_all()
        #endif
    }()

    deinit { whisper_free(ctx) }

    /// Decodes a chunk. If the result has no speech at all (Whisper's "♪♪♪" in noise,
    /// often from temperature fallback), the chunk is decoded once more at
    /// temperature 0 with no fallback, and that result is kept when it has words.
    public func transcribe(_ pcm: [Float]) throws -> [ASRPiece] {
        let first = try decode(pcm, fallback: temperatureFallback)
        guard temperatureFallback, !first.isEmpty, first.allSatisfy({ ASRFilter.isHallucination($0.text) }) else { return first }
        let retry = try decode(pcm, fallback: false)
        return retry.contains(where: { !ASRFilter.isHallucination($0.text) }) ? retry : first
    }

    /// The decoder settings for one chunk. No initial prompt: `initial_prompt` and `prompt_tokens`
    /// stay unset (tested in EarshotWhisperTests).
    public static func decodeParams(beamSize: Int32, threads: Int32, fallback: Bool) -> whisper_full_params {
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
        p.initial_prompt = nil
        p.prompt_tokens = nil
        p.prompt_n_tokens = 0
        return p
    }

    private func decode(_ pcm: [Float], fallback: Bool) throws -> [ASRPiece] {
        // whisper needs >= 1 s of audio; pad short chunks with silence
        var audio = pcm
        if audio.count < 16000 + 1600 { audio += [Float](repeating: 0, count: 16000 + 1600 - audio.count) }
        var p = Self.decodeParams(beamSize: beamSize, threads: threads, fallback: fallback)
        if let b = bias {
            p.logits_filter_callback = { _, _, tokens, n, logits, user in
                guard let user, let logits else { return }
                let trie = Unmanaged<BiasTrie>.fromOpaque(user).takeUnretainedValue()
                var history: [Int32] = []
                if let tokens, n > 0 { history.reserveCapacity(Int(n)); for i in 0..<Int(n) { history.append(tokens[i].id) } }
                for (t, bonus) in trie.bonuses(history: history) { logits[Int(t)] += bonus }
            }
            p.logits_filter_callback_user_data = Unmanaged.passUnretained(b).toOpaque()
        }
        let rc: Int32 = "en".withCString { lang in
            p.language = lang
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
                    toks.append(ASRToken(charOffset: offset + lead, startMs: Int64(d.t0) * 10, endMs: Int64(d.t1) * 10, p: Double(d.p)))
                }
                offset += piece.count
            }
            out.append(ASRPiece(startMs: t0, endMs: t1, text: text, avgLogprob: cnt > 0 ? (lp / Double(cnt) * 1000).rounded() / 1000 : nil, tokens: toks))
        }
        return out
    }
}
