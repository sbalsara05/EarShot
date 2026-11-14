import XCTest
@testable import EarshotCore

final class RecognizerChoiceTests: XCTestCase {
    struct LoadFailed: Error {}

    private func option(_ kind: RecognizerKind, _ name: String, available: Bool = true, loads: Bool = true) -> RecognizerOption {
        RecognizerOption(kind: kind, name: name,
                         unavailableReason: { available ? nil : "not here" },
                         make: { if loads { return ScriptedTranscriber([name]) } else { throw LoadFailed() } })
    }

    /// Same kind throughout, so any policy keeps the given order: this tests the walk, not the ranking.
    func testSkipsUnavailableAndFailingOptionsAndSaysWhy() throws {
        let c = try RecognizerSelector.choose(from: [
            option(.whisperStock, "small", available: false),
            option(.whisperStock, "base", loads: false),
            option(.whisperStock, "tiny"),
        ])
        XCTAssertEqual(c.name, "tiny")
        XCTAssertEqual(c.skipped.map(\.name), ["small", "base"])
        XCTAssertEqual(c.skipped[0].reason, "not here")
        XCTAssertTrue(c.skipped[1].reason.hasPrefix("failed to load"))
    }

    func testOnlyTheChosenOptionIsBuilt() throws {
        var built: [String] = []
        let opts = ["a", "b"].map { n in
            RecognizerOption(kind: .whisperStock, name: n, unavailableReason: { nil },
                             make: { built.append(n); return ScriptedTranscriber([]) })
        }
        _ = try RecognizerSelector.choose(from: opts)
        XCTAssertEqual(built, ["a"])
    }

    func testNothingRunsGivesEveryReason() {
        XCTAssertThrowsError(try RecognizerSelector.choose(from: [
            option(.whisperStock, "small", available: false),
            option(.whisperStock, "base", available: false),
        ])) { e in
            XCTAssertEqual((e as? RecognizerSelectionFailure)?.skipped.count, 2)
        }
    }

    /// A clean comparison: the side the setting leaves out never writes the record, even when the
    /// chosen side cannot run.
    func testNoFallbackAcrossTheWhisperSetting() throws {
        let appleDown = [option(.appleOnDevice, "apple-speech", available: false), option(.whisperStock, "small")]
        XCTAssertThrowsError(try RecognizerSelector.choose(from: appleDown, whisper: false)) { e in
            XCTAssertEqual((e as? RecognizerSelectionFailure)?.skipped.map(\.name), ["apple-speech"])
        }
        XCTAssertEqual(try RecognizerSelector.choose(from: appleDown, whisper: true).name, "small")

        let whisperDown = [option(.appleOnDevice, "apple-speech"), option(.whisperStock, "small", available: false)]
        XCTAssertThrowsError(try RecognizerSelector.choose(from: whisperDown, whisper: true))
        XCTAssertEqual(try RecognizerSelector.choose(from: whisperDown, whisper: false).name, "apple-speech")
    }

    func testFineTunedWhisperIsTriedBeforeStock() {
        let ranked = RecognizerPolicy.rank(mixed.map { option($0.0, $0.1) }, whisper: true).map(\.name)
        XCTAssertEqual(ranked, ["ems", "small", "base"])
    }

    private let mixed: [(RecognizerKind, String)] = [
        (.whisperStock, "small"), (.appleOnDevice, "apple-speech"), (.whisperFineTuned, "ems"), (.whisperStock, "base"),
    ]

    /// Whatever the policy decides, it must not invent or duplicate options, and must keep options
    /// of one kind in the order given (small.en before base.en before tiny.en).
    func testPolicyNeverInventsOrReordersWithinAKind() {
        let given = mixed.map { option($0.0, $0.1) }
        for whisper in [true, false] {
            let ranked = RecognizerPolicy.rank(given, whisper: whisper).map(\.name)
            XCTAssertEqual(Set(ranked).count, ranked.count, "duplicated an option")
            XCTAssertTrue(Set(ranked).isSubset(of: Set(given.map(\.name))), "invented an option")
            if let s = ranked.firstIndex(of: "small"), let b = ranked.firstIndex(of: "base") { XCTAssertLessThan(s, b) }
        }
    }

    /// The toggle: with Whisper on, a Whisper model is tried first; with it off, Apple's recogniser is.
    func testWhisperSettingDecidesWhoIsTriedFirst() {
        let given = mixed.map { option($0.0, $0.1) }
        XCTAssertEqual(RecognizerPolicy.rank(given, whisper: true).first?.kind.isWhisper, true)
        XCTAssertEqual(RecognizerPolicy.rank(given, whisper: false).first?.kind, .appleOnDevice)
    }
}
