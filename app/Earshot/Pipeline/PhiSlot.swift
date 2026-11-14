import Foundation
import EarshotCore
#if os(iOS)
import os
#endif

/// The Phi-3.5-mini slot (core/Sources/EarshotLLM, llama.cpp). Optional and off by default: the
/// setting is `Model.phiEnabled`. With it off, the model missing, or too little memory, calls are
/// drafted by the rules alone, exactly as without it.
///
/// Model files go in the app's Documents folder (Finder or Files) or app/Models (bundled by
/// app/scripts/fetch_deps.sh). Q4_K_M is preferred; IQ4_XS is the low-memory fallback.
enum PhiSlot {
    /// File name and the memory it needs free to load and run with a 4096-token context
    /// (weights + about 1.6 GB of key/value cache + working buffers), in GB.
    static let choices: [(name: String, needGB: Double)] = [
        ("phi-3.5-mini-instruct-Q4_K_M", 4.4),
        ("phi-3.5-mini-instruct-IQ4_XS", 4.1),
    ]

    /// Memory the app can still use, in GB. nil where the system does not say (macOS).
    static var availableGB: Double? {
        #if os(iOS)
        return Double(os_proc_available_memory()) / 1_000_000_000
        #else
        return nil
        #endif
    }

    /// The first model that is installed and fits in memory, loaded; or why there is none.
    static func load(threads: Int = 4) -> (engine: LLMEngine?, problem: String?) {
        let installed = choices.compactMap { c in ModelFiles.find(c.name, ext: "gguf").map { (c, $0) } }
        guard !installed.isEmpty else {
            return (nil, "Phi is on but no model is installed (copy phi-3.5-mini-instruct-Q4_K_M.gguf into the app's Documents folder).")
        }
        let free = availableGB
        guard let (choice, url) = installed.first(where: { free == nil || free! >= $0.0.needGB }) else {
            return (nil, String(format: "Phi was skipped: %.1f GB of memory is free and it needs %.1f GB.", free ?? 0, installed.map(\.0.needGB).min() ?? 0))
        }
        do {
            return (TurnTakingLLM(try LlamaEngine(modelPath: url.path, threads: threads)), nil)
        } catch {
            return (nil, "Phi could not be loaded (\(error)). \(choice.name)")
        }
    }
}

/// One model runs at a time on the device. Whisper and Phi take turns on this lock, one call each:
/// a Phi window waits for the Whisper chunk being decoded, and the next chunk waits for that window.
enum ModelTurn {
    static let lock = NSLock()
}

/// Phi, taking turns with Whisper (`ModelTurn`) on every call into the model.
final class TurnTakingLLM: LLMEngine {
    private let inner: LLMEngine
    init(_ inner: LLMEngine) { self.inner = inner }
    var modelName: String { inner.modelName }
    var usage: LLMUsage { inner.usage }
    func complete(system: String, user: String, grammar: String, maxTokens: Int) throws -> String {
        try ModelTurn.lock.withLock { try inner.complete(system: system, user: user, grammar: grammar, maxTokens: maxTokens) }
    }
}
