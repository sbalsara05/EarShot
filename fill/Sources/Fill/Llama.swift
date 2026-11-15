import Accelerate
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
/// every answer is held to a grammar, so it always parses. Questions about the same transcript share the work
/// of reading it (see `shared`).
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

    /// - opening: this text starts the prompt, so it gets the model's start-of-text token if it has one.
    func tokenize(_ text: String, opening: Bool = true) throws -> [llama_token] {
        var toks = [llama_token](repeating: 0, count: text.utf8.count + 16)
        var n = llama_tokenize(vocab, text, Int32(text.utf8.count), &toks, Int32(toks.count), opening, true)
        if n < 0 {
            toks = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, Int32(text.utf8.count), &toks, Int32(toks.count), opening, true)
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

    /// Where the part of a question shared with the next one ends. Everything up to and including this text
    /// (the instructions and the transcript) is read once, and the model's state at that point is kept, so each
    /// further question about the same transcript starts from there instead of reading it again.
    public var shared = "END OF TRANSCRIPT\n\n"
    private var kept: (tokens: [llama_token], state: [UInt8])?

    /// Reads tokens into the model, in pieces no larger than its batch.
    private func read(_ tokens: [llama_token]) throws {
        var tokens = tokens, at = 0
        while at < tokens.count {
            let n = min(2048, tokens.count - at)
            let rc = tokens[at..<at + n].withContiguousMutableStorageIfAvailable { llama_decode(ctx, llama_batch_get_one($0.baseAddress, Int32(n))) } ?? -1
            guard rc == 0 else { kept = nil; throw Problem("The model could not read the question (\(rc)).") }
            at += n
        }
    }

    public func complete(system: String, user: String, grammar: String, maxTokens: Int) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let text = format(system: system, user: user)
        var head: [llama_token] = [], tail: [llama_token]
        if let cut = text.range(of: shared), cut.upperBound < text.endIndex {
            head = try tokenize(String(text[..<cut.upperBound]))
            tail = try tokenize(String(text[cut.upperBound...]), opening: false)
        } else {
            tail = try tokenize(text)
        }
        guard head.count + tail.count + maxTokens <= Int(nCtx) else {
            throw Problem("A question of \(head.count + tail.count) tokens and an answer of up to \(maxTokens) do not fit in the model's \(nCtx).")
        }

        let t0 = Date()
        llama_memory_clear(llama_get_memory(ctx), true)
        var fresh = head.count + tail.count
        if let kept, !head.isEmpty, kept.tokens == head, kept.state.withUnsafeBufferPointer({ llama_state_seq_set_data(ctx, $0.baseAddress, $0.count, 0) }) > 0 {
            fresh = tail.count   // the shared start is back in place without being read again
        } else {
            llama_memory_clear(llama_get_memory(ctx), true)
            kept = nil
            try read(head)
            if !head.isEmpty {
                var state = [UInt8](repeating: 0, count: llama_state_seq_get_size(ctx, 0))
                let wrote = state.withUnsafeMutableBufferPointer { llama_state_seq_get_data(ctx, $0.baseAddress, $0.count, 0) }
                if wrote > 0 { kept = (head, Array(state.prefix(wrote))) }
            }
        }
        try read(tail)

        guard let g = llama_sampler_init_grammar(vocab, grammar, "root") else { throw Problem("The answer's grammar does not parse.") }
        defer { llama_sampler_free(g) }

        let t1 = Date()
        promptTokens += fresh
        promptSeconds += t1.timeIntervalSince(t0)
        defer { makeSeconds += Date().timeIntervalSince(t1) }

        let nVocab = Int(llama_vocab_n_tokens(vocab))
        var all = [llama_token_data](repeating: llama_token_data(id: 0, logit: 0, p: 0), count: nVocab)
        var out: [UInt8] = []
        for _ in 0..<maxTokens {
            guard let logits = llama_get_logits_ith(ctx, -1) else { throw Problem("The model gave no answer.") }
            // The most likely token, if the grammar allows it; otherwise the most likely one it does allow.
            // Found with Accelerate: a plain loop over the whole vocabulary for every token is slow in a debug build.
            var top: Float = 0, where_: vDSP_Length = 0
            vDSP_maxvi(logits, 1, &top, &where_, vDSP_Length(nVocab))
            let best = Int(where_)
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
            guard rc == 0 else { throw Problem("The model stopped part way through its answer (\(rc)).") }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
