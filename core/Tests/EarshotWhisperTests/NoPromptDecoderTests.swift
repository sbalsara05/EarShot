import XCTest
import CWhisper
@testable import EarshotWhisper

/// Replaces PromptFreezeTests: Whisper decodes with no initial prompt, for every model and every
/// setting (beam / greedy, with and without temperature fallback).
final class NoPromptDecoderTests: XCTestCase {
    func testNoInitialPromptReachesTheDecoder() {
        for (beam, fallback) in [(Int32(5), true), (5, false), (1, true), (1, false)] {
            let p = WhisperTranscriber.decodeParams(beamSize: beam, threads: 4, fallback: fallback)
            XCTAssertNil(p.initial_prompt, "beam \(beam) fallback \(fallback)")
            XCTAssertNil(p.prompt_tokens, "beam \(beam) fallback \(fallback)")
            XCTAssertEqual(p.prompt_n_tokens, 0)
            XCTAssertTrue(p.no_context, "no text carried over from an earlier chunk either")
        }
    }

    /// Decoding settings this change must not touch.
    func testDecodingSettingsUnchanged() {
        let p = WhisperTranscriber.decodeParams(beamSize: 5, threads: 4, fallback: true)
        XCTAssertEqual(p.strategy, WHISPER_SAMPLING_BEAM_SEARCH)
        XCTAssertEqual(p.beam_search.beam_size, 5)
        XCTAssertEqual(p.temperature, 0)
        XCTAssertEqual(p.temperature_inc, 0.2, accuracy: 1e-6)
        XCTAssertTrue(p.token_timestamps)
    }
}
