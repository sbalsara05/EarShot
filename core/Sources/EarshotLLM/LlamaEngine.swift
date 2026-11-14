import Foundation
import EarshotCore
#if canImport(CLlama)
import CLlama
#else
import llama   // iOS: llama.xcframework module
#endif

public struct LlamaError: Error, CustomStringConvertible {
    public var description: String
    init(_ s: String) { description = s }
}

/// llama.cpp through its C API, for Phi-3.5-mini-instruct (GGUF).
///
/// Deterministic by construction: greedy sampling (temperature 0; the seed is fixed but unused
/// by greedy), a fixed thread count, CPU only (no GPU kernels whose reductions can vary), and
/// the KV cache cleared before every call, so the same prompt gives the same reply. Every
/// reply is constrained by a GBNF grammar, so it always parses.
public final class LlamaEngine: LLMEngine {
    public let modelName: String
    public static let seed: UInt32 = 1234

    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private let template: String?
    private let nCtx: Int32
    private let lock = NSLock()
    public private(set) var usage = LLMUsage()

    /// - name: provenance name; default "phi-3.5-mini-<quant>" from the file name.
    public init(modelPath: String, name: String? = nil, threads: Int = 4, context: Int = 4096) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else { throw LlamaError("no model at \(modelPath)") }
        llama_log_set({ _, _, _ in }, nil)   // llama.cpp logs to stderr by default; the pipeline keeps its own notes
        llama_backend_init()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 0
        guard let m = llama_model_load_from_file(modelPath, mp) else { throw LlamaError("cannot load model at \(modelPath)") }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(context)
        cp.n_batch = UInt32(context)
        cp.n_ubatch = 512
        cp.n_threads = Int32(threads)
        cp.n_threads_batch = Int32(threads)
        cp.no_perf = true
        guard let c = llama_init_from_model(m, cp) else { llama_model_free(m); throw LlamaError("cannot create a llama context") }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        nCtx = Int32(llama_n_ctx(c))
        template = llama_model_chat_template(m, nil).map { String(cString: $0) }
        modelName = name ?? Self.defaultName(modelPath)
    }

    deinit {
        llama_free(ctx)
        llama_model_free(model)
    }

    /// "phi-3.5-mini-instruct-Q4_K_M.gguf" -> "phi-3.5-mini-q4".
    static func defaultName(_ path: String) -> String {
        let f = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
        let quant: String
        if let r = f.range(of: #"(?:i?q\d)"#, options: .regularExpression) { quant = String(f[r]).replacingOccurrences(of: "i", with: "") } else { quant = "f16" }
        let base = f.contains("phi-3.5-mini") ? "phi-3.5-mini" : f.components(separatedBy: "-q").first ?? f
        return f.contains("iq4_xs") ? "\(base)-iq4" : "\(base)-\(quant)"
    }

    /// The prompt in the model's own chat template (Phi-3.5: <|system|> … <|end|> <|user|> … <|end|> <|assistant|>).
    func format(system: String, user: String) -> String {
        let roles = [("system", system), ("user", user)]
        let cRoles = roles.map { (strdup($0.0), strdup($0.1)) }
        defer { for (a, b) in cRoles { free(a); free(b) } }
        var msgs = cRoles.map { llama_chat_message(role: $0.0, content: $0.1) }
        var buf = [CChar](repeating: 0, count: (system.utf8.count + user.utf8.count) * 2 + 256)
        var n = llama_chat_apply_template(template, &msgs, msgs.count, true, &buf, Int32(buf.count))
        if n > buf.count {
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = llama_chat_apply_template(template, &msgs, msgs.count, true, &buf, Int32(buf.count))
        }
        guard n > 0 else {
            // template not recognised: Phi-3.5's format written out
            return "<|system|>\n\(system)<|end|>\n<|user|>\n\(user)<|end|>\n<|assistant|>\n"
        }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func tokenize(_ text: String) throws -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        var toks = [llama_token](repeating: 0, count: utf8.count + 16)
        var n = llama_tokenize(vocab, text, Int32(text.utf8.count), &toks, Int32(toks.count), true, true)
        if n < 0 {
            toks = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, Int32(text.utf8.count), &toks, Int32(toks.count), true, true)
        }
        guard n >= 0 else { throw LlamaError("tokenization failed") }
        return Array(toks.prefix(Int(n)))
    }

    func piece(_ t: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, t, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, t, &buf, Int32(buf.count), 0, false)
        }
        return buf.prefix(Int(max(0, n))).map { UInt8(bitPattern: $0) }
    }

    /// Tokens whose keys/values are in the context now (the last prompt plus its reply). A new
    /// prompt that starts the same way (the same system prompt) reuses them instead of recomputing.
    private var cached: [llama_token] = []

    public func complete(system: String, user: String, grammar: String, maxTokens: Int) throws -> String {
        lock.lock(); defer { lock.unlock() }
        var prompt = try tokenize(format(system: system, user: user))
        guard prompt.count + maxTokens <= Int(nCtx) else {
            throw LlamaError("prompt of \(prompt.count) tokens + \(maxTokens) to generate exceeds the \(nCtx)-token context")
        }
        // reuse the shared prefix; at least one token is decoded so there are logits to sample from
        var keep = zip(cached, prompt).prefix { $0 == $1 }.count
        keep = min(keep, prompt.count - 1)
        let mem = llama_get_memory(ctx)
        if keep > 0, llama_memory_seq_rm(mem, 0, Int32(keep), -1) {
            cached = Array(prompt.prefix(keep))
        } else {
            llama_memory_clear(mem, true)
            keep = 0
            cached = []
        }

        guard let g = llama_sampler_init_grammar(vocab, grammar, "root") else { throw LlamaError("grammar does not parse") }
        defer { llama_sampler_free(g) }

        let t0 = Date()
        var rc = prompt[keep...].withContiguousMutableStorageIfAvailable { llama_decode(ctx, llama_batch_get_one($0.baseAddress, Int32($0.count))) } ?? -1
        guard rc == 0 else { cached = []; throw LlamaError("decode failed (\(rc))") }
        cached = prompt
        let t1 = Date()
        usage.calls += 1
        usage.promptTokens += prompt.count - keep
        usage.promptSeconds += t1.timeIntervalSince(t0)
        defer { usage.generateSeconds += Date().timeIntervalSince(t1) }

        let nVocab = Int(llama_vocab_n_tokens(vocab))
        var all = [llama_token_data](repeating: llama_token_data(id: 0, logit: 0, p: 0), count: nVocab)
        var out: [UInt8] = []
        for _ in 0..<maxTokens {
            guard let logits = llama_get_logits_ith(ctx, -1) else { throw LlamaError("no logits") }
            // greedy (temperature 0) under the grammar. Fast path: the overall best token, if the
            // grammar allows it, is also the best allowed token. Ties go to the lowest id.
            var best = 0
            for i in 1..<nVocab where logits[i] > logits[best] { best = i }
            var one = llama_token_data(id: llama_token(best), logit: logits[best], p: 0)
            var t = llama_token(best)
            let allowed: Bool = withUnsafeMutablePointer(to: &one) { ptr in
                var arr = llama_token_data_array(data: ptr, size: 1, selected: -1, sorted: false)
                llama_sampler_apply(g, &arr)
                return ptr.pointee.logit.isFinite
            }
            if !allowed {
                usage.grammarFallbacks += 1
                for i in 0..<nVocab { all[i] = llama_token_data(id: llama_token(i), logit: logits[i], p: 0) }
                all.withUnsafeMutableBufferPointer { buf in
                    var arr = llama_token_data_array(data: buf.baseAddress, size: nVocab, selected: -1, sorted: false)
                    llama_sampler_apply(g, &arr)
                }
                var bi = -1
                for i in 0..<nVocab where all[i].logit.isFinite && (bi < 0 || all[i].logit > all[bi].logit) { bi = i }
                guard bi >= 0 else { throw LlamaError("grammar allows no token") }
                t = all[bi].id
            }
            llama_sampler_accept(g, t)
            if llama_vocab_is_eog(vocab, t) { break }
            out += piece(t)
            usage.generatedTokens += 1
            rc = withUnsafeMutablePointer(to: &t) { llama_decode(ctx, llama_batch_get_one($0, 1)) }
            guard rc == 0 else { cached = []; throw LlamaError("decode failed (\(rc))") }
            cached.append(t)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
