import Foundation

/// Steers Whisper toward drug names while it decodes (contextual biasing, no model change).
///
/// Each bias phrase is stored as the token sequence Whisper's tokenizer gives it (" aspirin",
/// " Aspirin", ...). At every decoding step, the tokens decoded so far are matched against the
/// tree: a token that continues a phrase already started gets `nextBonus` added to its logit,
/// and the first token of any phrase gets `firstBonus`. Whisper's own scores still decide; the
/// bonus only tips close calls ("zofran" over "so fran").
///
/// Published methods (e.g. arXiv 2508.17796) also take the bonus back when a phrase is abandoned
/// half way, which a logits hook cannot do. So the first-token bonus is kept small: it is the one
/// that can make Whisper start a drug name that was not said. Measure both on speech without
/// drugs before raising them.
///
/// Pure Swift (token ids in, bonuses out) so it is tested without a model; WhisperTranscriber
/// tokenizes the phrases and applies the bonuses through whisper.cpp's logits filter.
public final class BiasTrie: @unchecked Sendable {
    final class Node {
        var children: [Int32: Node] = [:]
        var terminal = false
    }

    private let root = Node()
    public let firstBonus: Float
    public let nextBonus: Float
    public private(set) var phraseCount = 0
    private var maxDepth = 0
    /// Token ids at or above this are special (timestamps, end of text) and are skipped.
    public let textTokenLimit: Int32

    public init(sequences: [[Int32]], firstBonus: Float, nextBonus: Float, textTokenLimit: Int32 = .max) {
        self.firstBonus = firstBonus; self.nextBonus = nextBonus; self.textTokenLimit = textTokenLimit
        for s in sequences where !s.isEmpty {
            var n = root
            for t in s {
                if let c = n.children[t] { n = c } else { let c = Node(); n.children[t] = c; n = c }
            }
            if !n.terminal { n.terminal = true; phraseCount += 1 }
            maxDepth = max(maxDepth, s.count)
        }
    }

    /// Logit bonus per token for the next decoding step, given the tokens decoded so far.
    public func bonuses(history: [Int32]) -> [Int32: Float] {
        var out: [Int32: Float] = [:]
        if firstBonus != 0 { for t in root.children.keys { out[t] = firstBonus } }
        guard nextBonus != 0 else { return out }
        let text = history.filter { $0 < textTokenLimit }
        // every suffix of the recent tokens that is a started phrase
        let lo = max(0, text.count - maxDepth)
        for s in lo..<text.count {
            var n = root
            var ok = true
            for t in text[s...] {
                guard let c = n.children[t] else { ok = false; break }
                n = c
            }
            guard ok else { continue }
            for t in n.children.keys { out[t] = max(out[t] ?? 0, nextBonus) }
        }
        return out
    }
}

extension EMSDictionary {
    /// Phrases to bias Whisper toward: drug generic names, brands and common short names, each as
    /// written ("aspirin") and capitalized ("Aspirin"), with a leading space as Whisper writes words.
    /// Misspellings (asr_variants) are never included: biasing toward them would teach the error.
    /// Aliases that are everyday words ("context required", e.g. "sugar") are left out too.
    public func biasPhrases() -> [String] {
        var words = Set<String>()
        for d in formulary.drugs {
            for w in [d.generic] + d.brands + d.aliases + d.slang where w.count >= 4 && !contextRequired.contains(EMSText.normalizePhrase(w)) {
                words.insert(w.lowercased())
            }
        }
        return words.sorted().flatMap { w in [" " + w, " " + w.prefix(1).uppercased() + w.dropFirst()] }
    }
}
