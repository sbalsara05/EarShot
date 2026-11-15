import Foundation
import llama

/// What the filling step needs from a language model: one question in, one answer out, in a fixed shape.
/// `Llama` is the real one; tests use a scripted stand-in.
public protocol Engine: AnyObject {
    var name: String { get }
    /// One chat turn. The answer is forced to fit `grammar` (GBNF), so it always has the shape asked for.
    func complete(system: String, user: String, grammar: String, maxTokens: Int) throws -> String
}

public struct Problem: Error, LocalizedError {
    public var errorDescription: String?
    public init(_ text: String) { errorDescription = text }
}

/// A language model on this device, through llama.cpp's C API.
///
/// This is Shourya Yadav's `LlamaEngine` from the `pipeline` branch (commit 2a78746), with two changes: it can
/// run on the GPU, and it no longer depends on his `EarshotCore`.
///
/// The same question always gets the same answer: the most likely token is taken every time (no dice), and
/// every answer is held to a grammar, so it always parses. A question that starts the same way as the last one
/// (the same transcript) reuses the work already done on that shared start.
public final class Llama: Engine {
    public let name: String

    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private let template: String?
    private let nCtx: Int32
    private let lock = NSLock()
    public private(set) var promptTokens = 0, promptSeconds = 0.0, madeTokens = 0, makeSeconds = 0.0

    /// - gpu: run on the GPU (Metal). Off in the simulator, which has none worth using.
    /// - context: how many tokens the model can hold at once, question and answer together.
    public init(_ path: String, gpu: Bool = true, threads: Int = 4, context: Int = 8192) throws {
        guard FileManager.default.fileExists(atPath: path) else { throw Problem("There is no model at \(path).") }
        llama_log_set({ _, _, _ in }, nil)   // llama.cpp prints a great deal by default
        llama_backend_init()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = gpu ? 999 : 0
        guard let m = llama_model_load_from_file(path, mp) else { throw Problem("The model at \(path) could not be loaded.") }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(context)
        cp.n_batch = UInt32(context)
        cp.n_ubatch = 512
        cp.n_threads = Int32(threads)
        cp.n_threads_batch = Int32(threads)
        cp.no_perf = true
        guard let c = llama_init_from_model(m, cp) else { llama_model_free(m); throw Problem("There is not enough memory to run the model.") }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        nCtx = Int32(llama_n_ctx(c))
        template = llama_model_chat_template(m, nil).map { String(cString: $0) }
        name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    deinit {
        llama_free(ctx)
        llama_model_free(model)
    }

    /// The question in the model's own chat layout.
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
            // The layout was not recognised: ChatML, which most small models use, written out.
            return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func tokenize(_ text: String) throws -> [llama_token] {
        var toks = [llama_token](repeating: 0, count: text.utf8.count + 16)
        var n = llama_tokenize(vocab, text, Int32(text.utf8.count), &toks, Int32(toks.count), true, true)
        if n < 0 {
            toks = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, Int32(text.utf8.count), &toks, Int32(toks.count), true, true)
        }
        guard n >= 0 else { throw Problem("The question could not be read by the model.") }
        return Array(toks.prefix(Int(n)))
    }

    /// How many tokens a piece of text costs.
    public func count(_ text: String) -> Int { (try? tokenize(text).count) ?? text.utf8.count / 3 }

    func piece(_ t: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, t, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, t, &buf, Int32(buf.count), 0, false)
        }
        return buf.prefix(Int(max(0, n))).map { UInt8(bitPattern: $0) }
    }

    /// The tokens the model is holding now: the last question and its answer.
    private var cached: [llama_token] = []

    public func complete(system: String, user: String, grammar: String, maxTokens: Int) throws -> String {
        lock.lock(); defer { lock.unlock() }
        var prompt = try tokenize(format(system: system, user: user))
        guard prompt.count + maxTokens <= Int(nCtx) else {
            throw Problem("A question of \(prompt.count) tokens and an answer of up to \(maxTokens) do not fit in the model's \(nCtx).")
        }
        // Reuse the shared start. At least one token is always read, so there is something to answer from.
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

        guard let g = llama_sampler_init_grammar(vocab, grammar, "root") else { throw Problem("The answer's grammar does not parse.") }
        defer { llama_sampler_free(g) }

        let t0 = Date()
        // Read in pieces no larger than the batch, so a long transcript never overruns it.
        var at = keep
        while at < prompt.count {
            let n = min(2048, prompt.count - at)
            let rc = prompt[at..<at + n].withContiguousMutableStorageIfAvailable { llama_decode(ctx, llama_batch_get_one($0.baseAddress, Int32(n))) } ?? -1
            guard rc == 0 else { cached = []; throw Problem("The model could not read the question (\(rc)).") }
            at += n
        }
        cached = prompt
        let t1 = Date()
        promptTokens += prompt.count - keep
        promptSeconds += t1.timeIntervalSince(t0)
        defer { makeSeconds += Date().timeIntervalSince(t1) }

        let nVocab = Int(llama_vocab_n_tokens(vocab))
        var all = [llama_token_data](repeating: llama_token_data(id: 0, logit: 0, p: 0), count: nVocab)
        var out: [UInt8] = []
        for _ in 0..<maxTokens {
            guard let logits = llama_get_logits_ith(ctx, -1) else { throw Problem("The model gave no answer.") }
            // The most likely token, if the grammar allows it; otherwise the most likely one it does allow.
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
                for i in 0..<nVocab { all[i] = llama_token_data(id: llama_token(i), logit: logits[i], p: 0) }
                all.withUnsafeMutableBufferPointer { buf in
                    var arr = llama_token_data_array(data: buf.baseAddress, size: nVocab, selected: -1, sorted: false)
                    llama_sampler_apply(g, &arr)
                }
                var bi = -1
                for i in 0..<nVocab where all[i].logit.isFinite && (bi < 0 || all[i].logit > all[bi].logit) { bi = i }
                guard bi >= 0 else { throw Problem("The grammar allows no next token.") }
                t = all[bi].id
            }
            llama_sampler_accept(g, t)
            if llama_vocab_is_eog(vocab, t) { break }
            out += piece(t)
            madeTokens += 1
            let rc = withUnsafeMutablePointer(to: &t) { llama_decode(ctx, llama_batch_get_one($0, 1)) }
            guard rc == 0 else { cached = []; throw Problem("The model stopped part way through its answer (\(rc)).") }
            cached.append(t)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
