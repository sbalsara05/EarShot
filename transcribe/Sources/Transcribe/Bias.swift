import Foundation

/// Leans Whisper toward drug names while it writes, without changing the model.
///
/// Whisper scores every word-piece it could write next. Each drug name is stored as the pieces Whisper would
/// write it in. A piece that carries on a name already begun gets `next` added to its score, and a piece that
/// begins any name gets `first`. Whisper's own scores still decide: the bonus only tips a close call, such as
/// "Zofran" over "so fran". `first` is kept small because it is the one that could start a drug name nobody said.
final class Bias {
    static let first: Float = 0.5
    static let next: Float = 2.0

    private final class Node { var children: [Int32: Node] = [:] }
    private let root = Node()
    private var deepest = 0
    private let textLimit: Int32   // pieces at or above this are timestamps and markers, not text

    init(sequences: [[Int32]], textLimit: Int32 = .max) {
        self.textLimit = textLimit
        for sequence in sequences where !sequence.isEmpty {
            var node = root
            for piece in sequence {
                if let child = node.children[piece] { node = child } else { let child = Node(); node.children[piece] = child; node = child }
            }
            deepest = max(deepest, sequence.count)
        }
    }

    /// The bonus for each piece Whisper could write next, given the pieces written so far.
    func bonuses(after written: [Int32]) -> [Int32: Float] {
        var out: [Int32: Float] = [:]
        for piece in root.children.keys { out[piece] = Self.first }
        let text = written.filter { $0 < textLimit }
        // Every tail of the recent pieces that is the start of a name.
        for from in max(0, text.count - deepest)..<text.count {
            var node: Node? = root
            for piece in text[from...] {
                node = node?.children[piece]
                if node == nil { break }
            }
            for piece in (node?.children.keys).map(Array.init) ?? [] { out[piece] = max(out[piece] ?? 0, Self.next) }
        }
        return out
    }
}

public enum Drugs {
    /// Drug names to lean toward: generic names, brands and the short names crews use, four letters or longer.
    /// Misspellings are never in the list, since leaning toward them would teach the mistake, and neither are
    /// everyday words that are only sometimes a drug ("sugar", "saline").
    /// From the Massachusetts statewide protocols and RxNorm, gathered in pull request 15's formulary, plus the
    /// medicines patients most often say they take or are allergic to, which is what a history is made of.
    public static let names: [String] = {
        guard let url = Bundle.module.url(forResource: "drugs", withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }()
}

public enum Terms {
    /// Clinical words to lean toward that are not drugs: the ones Whisper has been seen to mishear ("end title"
    /// for end tidal, "bronchi" for rhonchi) and others as rare in everyday speech. Common words are left out:
    /// Whisper knows them, and every word added is one more it can be tipped toward by mistake.
    /// Kept apart from the drugs because the report-filling step reads the drug list as "these are medicines".
    public static let names: [String] = {
        guard let url = Bundle.module.url(forResource: "terms", withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }()
}
