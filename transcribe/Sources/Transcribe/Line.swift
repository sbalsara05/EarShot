import Foundation

/// One word of a line: where it starts in the line's text, when it was said, and how sure Whisper was of it.
public struct Word: Codable, Equatable, Sendable {
    public var offset: Int          // character offset in the line's text
    public var ms: Int64            // when it was said, in milliseconds since the audio began
    public var confidence: Double   // 0 to 1

    public init(offset: Int, ms: Int64, confidence: Double) {
        self.offset = offset; self.ms = ms; self.confidence = confidence
    }
}

/// One sentence of the transcript, as Whisper wrote it.
public struct Line: Codable, Equatable, Sendable {
    public var startMs: Int64       // when its first word was said, in milliseconds since the audio began
    public var endMs: Int64         // when its last word ended
    public var text: String
    public var confidence: Double   // the average of its words' confidences, 0 to 1
    public var words: [Word]

    public init(startMs: Int64, endMs: Int64, text: String, confidence: Double, words: [Word]) {
        self.startMs = startMs; self.endMs = endMs; self.text = text; self.confidence = confidence; self.words = words
    }
}

/// What Whisper returns for a chunk of audio, before it is made into lines: word-pieces, each with the
/// probability Whisper gave it. A word is one or more pieces; a piece that starts a word begins with a space.
public struct Piece: Equatable, Sendable {
    public var text: String
    public var startMs: Int64       // since the start of the chunk
    public var endMs: Int64
    public var probability: Double  // 0 to 1: how likely Whisper thought this piece was, against every other it could have written

    public init(text: String, startMs: Int64, endMs: Int64, probability: Double) {
        self.text = text; self.startMs = startMs; self.endMs = endMs; self.probability = probability
    }
}

public enum Lines {
    /// A line whose average falls below this is shown as unsure.
    public static let unsure = 0.6

    /// Makes a chunk's word-pieces into lines, one per sentence.
    ///
    /// How a line gets its confidence:
    /// 1. Whisper writes text a word-piece at a time. For each piece it gives a probability, 0 to 1.
    /// 2. A word's confidence is the average of its pieces' probabilities. Punctuation does not count.
    /// 3. A line's confidence is the average of its words' confidences.
    ///
    /// Sounds Whisper writes as tags ("[beep]", "(siren)", "*cough*") and the phrases it makes up in silence
    /// ("Thank you.") are left out.
    public static func build(_ pieces: [Piece], chunkStartMs: Int64) -> [Line] {
        // Pieces into words.
        struct Spoken { var text: String; var startMs: Int64; var endMs: Int64; var probabilities: [Double] }
        var words: [Spoken] = []
        for p in pieces where !p.text.trimmingCharacters(in: .whitespaces).isEmpty {
            let counts = p.text.contains { $0.isLetter || $0.isNumber }
            if p.text.first?.isWhitespace != false || words.isEmpty {
                words.append(Spoken(text: p.text.trimmingCharacters(in: .whitespaces), startMs: p.startMs, endMs: p.endMs, probabilities: counts ? [p.probability] : []))
            } else {
                words[words.count - 1].text += p.text
                words[words.count - 1].endMs = max(words[words.count - 1].endMs, p.endMs)
                if counts { words[words.count - 1].probabilities.append(p.probability) }
            }
        }
        // Tags are not speech: drop every word from an opening bracket to its closing one.
        var kept: [Spoken] = []
        var closing: Character?
        for w in words {
            if let c = closing {
                if w.text.contains(c) { closing = nil }
                continue
            }
            if let first = w.text.first, let c = ["[": "]", "(": ")", "*": "*"][String(first)]?.first {
                if !w.text.dropFirst().contains(c) { closing = c }
                continue
            }
            if w.text.contains(where: { $0.isLetter || $0.isNumber }) { kept.append(w) }
        }
        // Words into sentences.
        var lines: [Line] = []
        var open: [Spoken] = []
        func close() {
            guard !open.isEmpty else { return }
            var text = "", out: [Word] = []
            for w in open {
                if !text.isEmpty { text += " " }
                let sure = w.probabilities.isEmpty ? 0 : w.probabilities.reduce(0, +) / Double(w.probabilities.count)
                out.append(Word(offset: text.count, ms: chunkStartMs + w.startMs, confidence: round3(sure)))
                text += w.text
            }
            let end = chunkStartMs + (open.map(\.endMs).max() ?? 0)
            open = []
            guard !made(up: text) else { return }
            lines.append(Line(startMs: out[0].ms, endMs: max(end, out[0].ms), text: text,
                              confidence: round3(out.map(\.confidence).reduce(0, +) / Double(out.count)), words: out))
        }
        for (i, w) in kept.enumerated() {
            open.append(w)
            if endsSentence(w.text, next: i + 1 < kept.count ? kept[i + 1].text : nil) { close() }
        }
        close()
        return lines
    }

    /// True when a word ends a sentence: it ends in ". ? !", is not a title like "Dr.", and what follows starts
    /// a new sentence (a capital or a digit), so "2 p.m. today" stays together.
    static func endsSentence(_ word: String, next: String?) -> Bool {
        let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]"))
        guard let last = bare.last, ".?!".contains(last) else { return false }
        if ["mr.", "mrs.", "ms.", "dr.", "vs.", "st."].contains(bare.lowercased()) { return false }
        guard let first = next?.first(where: { $0.isLetter || $0.isNumber }) else { return true }
        return last != "." || first.isUppercase || first.isNumber
    }

    /// Phrases Whisper writes when there is no speech, from its training on video subtitles.
    static func made(up text: String) -> Bool {
        let bare = text.lowercased().trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        return ["", "you", "thank you", "thanks for watching", "thank you for watching", "bye"].contains(bare)
    }

    static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}
