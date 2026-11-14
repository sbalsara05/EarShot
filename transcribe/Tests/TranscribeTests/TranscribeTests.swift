import XCTest
@testable import Transcribe

final class TranscribeTests: XCTestCase {
    private func piece(_ text: String, _ at: Int64, _ p: Double) -> Piece { Piece(text: text, startMs: at, endMs: at + 200, probability: p) }

    func testPiecesBecomeSentencesWithAveragedConfidence() {
        let lines = Lines.build([
            piece(" Giving", 0, 0.9), piece(" 3", 300, 0.4), piece("24", 400, 0.6), piece(" of", 600, 0.8), piece(" aspirin", 800, 1.0), piece(".", 1000, 0.2),
            piece(" Heart", 1500, 0.8), piece(" rate", 1700, 0.8), piece(" 96", 1900, 0.8),
        ], chunkStartMs: 10_000)
        XCTAssertEqual(lines.map(\.text), ["Giving 324 of aspirin.", "Heart rate 96"])
        // "324" is two pieces, 0.4 and 0.6: the word is 0.5. The full stop does not count.
        XCTAssertEqual(lines[0].words.map(\.confidence), [0.9, 0.5, 0.8, 1.0])
        XCTAssertEqual(lines[0].confidence, 0.8)
        XCTAssertEqual(lines[0].words.map(\.offset), [0, 7, 11, 14])
        XCTAssertEqual(lines[0].startMs, 10_000)
        XCTAssertEqual(lines[1].startMs, 11_500)
        XCTAssertEqual(lines[1].endMs, 12_100)
    }

    func testTagsAndMadeUpPhrasesAreLeftOut() {
        XCTAssertEqual(Lines.build([piece(" [", 0, 1), piece("beep", 0, 1), piece("]", 0, 1), piece(" Thank", 0, 1), piece(" you", 0, 1), piece(".", 0, 1)], chunkStartMs: 0), [])
        XCTAssertEqual(Lines.build([piece(" (siren)", 0, 1), piece(" BP", 0, 1), piece(" is", 0, 1), piece(" *cough*", 0, 1), piece(" fine", 0, 1)], chunkStartMs: 0).map(\.text), ["BP is fine"])
    }

    func testSentenceEnds() {
        XCTAssertTrue(Lines.endsSentence("pain.", next: "He"))
        XCTAssertTrue(Lines.endsSentence("pain?", next: "he"))
        XCTAssertFalse(Lines.endsSentence("p.m.", next: "today"))
        XCTAssertFalse(Lines.endsSentence("Dr.", next: "Patel"))
        XCTAssertFalse(Lines.endsSentence("2.5", next: "milligrams"))
        XCTAssertTrue(Lines.endsSentence("done.", next: nil))
    }

    func testChunkerCutsAtPauses() {
        func tone(_ ms: Int, _ loud: Double) -> [Int16] { (0..<(ms * 16)).map { Int16(loud * sin(Double($0) * 0.3)) } }
        let chunker = Chunker()
        var chunks: [Chunk] = []
        for part in [tone(1000, 0), tone(2000, 4000), tone(1500, 0), tone(100, 4000), tone(1500, 0), tone(3000, 4000)] {
            var i = 0
            while i < part.count { chunks += chunker.push(Array(part[i..<min(part.count, i + 320)])); i += 320 }
        }
        chunks += chunker.finish()
        // Two stretches of speech; the 100 ms click between them is too short to send.
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].startMs, 600)                       // 400 ms kept before the first loud frame
        XCTAssertTrue((3300...3400).contains(chunks[0].endMs))       // and half the pause after the last
        XCTAssertEqual(chunks[1].endMs, 9100)
    }

    func testLongSpeechIsCutWithNothingLost() {
        let chunker = Chunker()
        var chunks: [Chunk] = []
        for i in 0..<(60 * 50) {   // a minute of syllables with no pause long enough to end a chunk
            let loud = i % 5 == 0 ? 50.0 : 4000.0
            chunks += chunker.push((0..<320).map { Int16(loud * sin(Double($0) * 0.3)) })
        }
        chunks += chunker.finish()
        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.samples.count <= 25_000 * 16 })
        for (a, b) in zip(chunks, chunks.dropFirst()) { XCTAssertEqual(a.startSample + Int64(a.samples.count), b.startSample) }
    }

    func testBiasFavoursPiecesThatCarryOnAName() {
        let bias = Bias(sequences: [[10, 11, 12], [10, 20], [30]], textLimit: 1000)
        XCTAssertEqual(bias.bonuses(after: []), [10: Bias.first, 30: Bias.first])
        XCTAssertEqual(bias.bonuses(after: [5, 10]), [10: Bias.first, 30: Bias.first, 11: Bias.next, 20: Bias.next])
        XCTAssertEqual(bias.bonuses(after: [10, 2000, 11])[12], Bias.next)   // a timestamp between pieces is skipped
        XCTAssertNil(bias.bonuses(after: [10, 99])[11])
    }

    func testDrugListIsBundled() {
        XCTAssertTrue(Drugs.names.contains("aspirin") && Drugs.names.contains("narcan"))
        XCTAssertFalse(Drugs.names.contains("sugar"))
    }
}
