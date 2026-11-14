#if canImport(CoreML)
import Foundation
import CoreML

/// EMSTagger.mlpackage slot. Expected model I/O (data agent contract, see
/// docs/PIPELINE_READY.md): input "input_ids" Int32 [1, N] built from
/// tagger-vocab.txt (one token per line, line index = id, "[UNK]" and "[PAD]"
/// required); output "logits" Float [1, N, L] with labels
/// O, B-DRUG, I-DRUG, B-DOSE, I-DOSE, B-UNIT, I-UNIT, B-ROUTE, I-ROUTE, B-VITAL, I-VITAL.
/// Word-level tokens (Earshot clean tokens), so no subword alignment needed.
public final class CoreMLTagger: TokenTagger {
    public let name: String
    let model: MLModel
    let vocab: [String: Int32]
    let unk: Int32
    let pad: Int32
    let maxLen = 128
    static let labels = ["O", "B-DRUG", "I-DRUG", "B-DOSE", "I-DOSE", "B-UNIT", "I-UNIT", "B-ROUTE", "I-ROUTE", "B-VITAL", "I-VITAL"]

    public init(modelPath: String) throws {
        let url = URL(fileURLWithPath: modelPath)
        let compiled = try MLModel.compileModel(at: url)
        model = try MLModel(contentsOf: compiled)
        let vocabURL = url.deletingLastPathComponent().appendingPathComponent("tagger-vocab.txt")
        let lines = try String(contentsOf: vocabURL, encoding: .utf8).split(separator: "\n").map(String.init)
        var v: [String: Int32] = [:]
        for (i, l) in lines.enumerated() { v[l] = Int32(i) }
        vocab = v
        unk = v["[UNK]"] ?? 0
        pad = v["[PAD]"] ?? 0
        name = "EMSTagger"
    }

    public func tag(_ tokens: [String]) throws -> [TaggedSpan] {
        let n = min(tokens.count, maxLen)
        guard n > 0 else { return [] }
        let ids = try MLMultiArray(shape: [1, NSNumber(value: maxLen)], dataType: .int32)
        for i in 0..<maxLen { ids[i] = NSNumber(value: i < n ? (vocab[tokens[i]] ?? unk) : pad) }
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input_ids": ids]))
        guard let logits = out.featureValue(for: "logits")?.multiArrayValue else { return [] }
        let L = CoreMLTagger.labels.count
        var tags: [String] = []
        for i in 0..<n {
            var best = 0; var bv = -Float.infinity
            for l in 0..<L { let v = logits[[0, NSNumber(value: i), NSNumber(value: l)]].floatValue; if v > bv { bv = v; best = l } }
            tags.append(CoreMLTagger.labels[best])
        }
        var spans: [TaggedSpan] = []
        var i = 0
        while i < n {
            if tags[i].hasPrefix("B-") || (tags[i].hasPrefix("I-") && (i == 0 || tags[i - 1] == "O")) {
                let lab = String(tags[i].dropFirst(2)); var j = i
                while j + 1 < n && tags[j + 1] == "I-" + lab { j += 1 }
                spans.append(TaggedSpan(label: lab, start: i, end: j)); i = j + 1
            } else { i += 1 }
        }
        return spans
    }
}
#endif
