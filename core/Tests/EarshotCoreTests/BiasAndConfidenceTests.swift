import XCTest
@testable import EarshotCore

final class BiasAndConfidenceTests: XCTestCase {
    // MARK: bias tree

    // pretend token ids: " zof"=10 "ran"=11 " asp"=20 "irin"=21 " so"=30 "fran"=31
    let trie = BiasTrie(sequences: [[10, 11], [20, 21]], firstBonus: 0.5, nextBonus: 2.0, textTokenLimit: 1000)

    func testFirstTokensGetTheSmallBonus() {
        let b = trie.bonuses(history: [])
        XCTAssertEqual(b[10], 0.5); XCTAssertEqual(b[20], 0.5)
        XCTAssertNil(b[11], "a continuation is not boosted out of context")
    }

    func testContinuingANameGetsTheLargeBonus() {
        let b = trie.bonuses(history: [30, 5, 10])        // "... zof"
        XCTAssertEqual(b[11], 2.0)
        XCTAssertNil(b[21])
    }

    func testSpecialTokensAreSkipped() {
        // timestamp/special ids (>= limit) between the pieces do not break the match
        XCTAssertEqual(trie.bonuses(history: [10, 5000])[11], 2.0)
    }

    func testOffMeansNoBonus() {
        XCTAssertTrue(BiasTrie(sequences: [[10, 11]], firstBonus: 0, nextBonus: 0).bonuses(history: [10]).isEmpty)
        XCTAssertEqual(trie.phraseCount, 2)
    }

    func testBiasPhrasesUseCorrectSpellingsOnly() {
        let p = TestEnv.dict.biasPhrases()
        XCTAssertTrue(p.contains(" ondansetron")); XCTAssertTrue(p.contains(" Zofran"))
        XCTAssertTrue(p.allSatisfy { $0.hasPrefix(" ") })
        let variants = Set(TestEnv.dict.formulary.drugs.flatMap(\.asr_variants).map { " " + $0.lowercased() })
        let names = Set(TestEnv.dict.formulary.drugs.flatMap { [$0.generic] + $0.brands + $0.aliases + $0.slang }.map { " " + $0.lowercased() })
        let misspellingsOnly = variants.subtracting(names)
        XCTAssertTrue(misspellingsOnly.isDisjoint(with: Set(p.map { $0.lowercased() })), "misspellings are never biased toward")
    }

    // MARK: confidence flags

    /// "gave 4 milligrams zofran IV" with Whisper unsure of "4" (p 0.31).
    func seg(conf four: Double) -> CleanSegment {
        let text = "gave 4 milligrams zofran IV"
        let raw = RawSegment(id: "s1", startMs: 0, endMs: 3000, text: text,
                             wordTimes: [[0, 0], [5, 400], [7, 600], [18, 1400], [25, 2200]],
                             wordConf: [0.98, four, 0.95, 0.91, 0.97])
        return Cleanup(dict: TestEnv.dict).clean(raw).0
    }

    func testUnsureDoseIsFlagged() {
        let c = seg(conf: 0.31)
        let f = ConfidenceFlags.apply(RulesExtractor(dict: TestEnv.dict).extract(c), seg: c, minConfidence: 0.5)
        let m = f.first { $0.type == .medication }
        XCTAssertEqual(m?.fields["dose"], "4")
        XCTAssertTrue(m?.flags.contains("low_confidence") ?? false)
        XCTAssertTrue(m?.flags.contains("confirm") ?? false)
    }

    func testSureDoseIsNotFlagged() {
        let c = seg(conf: 0.93)
        let f = ConfidenceFlags.apply(RulesExtractor(dict: TestEnv.dict).extract(c), seg: c, minConfidence: 0.5)
        XCTAssertFalse(f.first { $0.type == .medication }?.flags.contains("low_confidence") ?? true)
    }

    /// From the 10 dB test run: Whisper unsure of "heart" (0.325) but sure of "96" (0.987).
    func testUnsureLabelWordDoesNotFlagAClearNumber() {
        let raw = RawSegment(id: "s1", startMs: 0, endMs: 2000, text: "heart rate 96, west 18",
                             wordTimes: [[0, 0], [6, 300], [11, 600], [13, 800], [15, 1000], [20, 1300]],
                             wordConf: [0.325, 0.979, 0.987, 0.934, 0.052, 0.683])
        let c = Cleanup(dict: TestEnv.dict).clean(raw).0
        let f = ConfidenceFlags.apply(RulesExtractor(dict: TestEnv.dict).extract(c), seg: c, minConfidence: 0.5)
        let v = f.first { $0.fields["heart_rate"] != nil }
        XCTAssertEqual(v?.fields["heart_rate"], "96")
        XCTAssertFalse(v?.flags.contains("low_confidence") ?? true)
    }

    func testNoConfidenceDataOrOffChangesNothing() {
        let c = seg(conf: 0.31)
        let f = RulesExtractor(dict: TestEnv.dict).extract(c)
        XCTAssertEqual(ConfidenceFlags.apply(f, seg: c, minConfidence: 0), f)
        var bare = c; bare.wordConf = nil
        XCTAssertEqual(ConfidenceFlags.apply(f, seg: bare, minConfidence: 0.5), f)
    }

    func testConfidenceSurvivesJoinAndRawSegment() {
        let a = ASRPiece(startMs: 0, endMs: 1000, text: " BP 120 over", tokens: [ASRToken(charOffset: 0, startMs: 0, endMs: 300, p: 0.9)])
        let b = ASRPiece(startMs: 1000, endMs: 2000, text: " 80.", tokens: [ASRToken(charOffset: 0, startMs: 1000, endMs: 1300, p: 0.4)])
        let s = ASRPiece.joinUnfinished([a, b])[0].rawSegment(id: "s1", chunkStartMs: 0, chunkEndMs: 2000)!
        XCTAssertEqual(s.wordConf, [0.9, 0.4])
        XCTAssertEqual(s.wordTimes?.count, 2)
    }
}
