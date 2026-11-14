import XCTest
@testable import EarshotCore

/// A call's record must survive the app closing: saved, read back into a new session, it gives the
/// same events, and the call carries on from there.
final class SessionRecordTests: XCTestCase {
    private func session(_ lines: [String]) -> LiveSession {
        let s = LiveSession(dict: TestEnv.dict, config: PipelineConfig(), callId: "c1", startEpochMs: 1_000_000, tzOffsetSeconds: -18000,
                            transcriber: ScriptedTranscriber(lines))
        s.callbackQueue = DispatchQueue(label: "cb")
        return s
    }

    /// One capture with a burst of "speech" per line, starting at `clipMs` on the clip's clock.
    private func speak(_ s: LiveSession, lines: Int, clipMs: Int, at seconds: Double) {
        let dec = PCMFrameDecoder()
        s.handle(.consent(granted: true, source: "button", clipMs: Int64(clipMs)), decoder: dec, receivedAt: Date(timeIntervalSince1970: 1000 + seconds))
        let pcm = burstPCM(seconds: Double(lines) * 6, bursts: (0..<lines).map { (Double($0) * 6 + 1, Double($0) * 6 + 4) })
        for i in 0..<(pcm.count / 320) {
            s.handleDecodedAudio(seq: UInt32(i), clipMs: UInt32(clipMs + i * 20), pcm: Array(pcm[(i * 320)..<((i + 1) * 320)]))
        }
        s.handle(.marker(id: 1, source: "button", clipMs: Int64(clipMs + 2000), audioSeq: -1), decoder: dec)
        s.handle(.consent(granted: false, source: "button", clipMs: Int64(clipMs + lines * 6000)), decoder: dec)
        s.drain()
    }

    private func through(_ r: SessionRecord) throws -> SessionRecord {
        try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(r))
    }

    func testARestoredSessionHasTheSameRecord() throws {
        let first = session(["BP 150 over 90, heart rate 104.", "Gave 324 of aspirin, chewed."])
        speak(first, lines: 2, clipMs: 0, at: 0)
        XCTAssertFalse(first.rawSegments.isEmpty)
        XCTAssertTrue(first.events.contains { $0.fields["bp_systolic"] == "150" })
        XCTAssertTrue(first.events.contains { $0.type == .medication })

        let again = session([])
        again.restore(try through(first.saved()))
        again.drain()
        XCTAssertEqual(again.rawSegments, first.rawSegments)
        XCTAssertEqual(again.events, first.events)
        XCTAssertEqual(again.saved(), first.saved())
    }

    func testTheCallCarriesOnAfterARestore() throws {
        let first = session(["BP 150 over 90."])
        speak(first, lines: 1, clipMs: 0, at: 0)
        let before = first.rawSegments

        let again = session(["Heart rate 104."])
        again.restore(try through(first.saved()))
        speak(again, lines: 1, clipMs: 0, at: 60)   // a minute later, the clip's clock starting over
        again.drain()
        XCTAssertEqual(Array(again.rawSegments.prefix(before.count)), before)
        XCTAssertEqual(again.rawSegments.count, before.count + 1)
        XCTAssertEqual(Set(again.rawSegments.map(\.id)).count, again.rawSegments.count, "segment ids clash")
        XCTAssertGreaterThan(again.rawSegments.last!.startMs, before.last!.endMs)
        XCTAssertTrue(again.events.contains { $0.fields["bp_systolic"] == "150" })
        XCTAssertTrue(again.events.contains { $0.fields["heart_rate"] == "104" })
    }

    func testAnEmptyRecordRestoresToNothing() throws {
        let s = session([])
        s.restore(try through(session([]).saved()))
        s.drain()
        XCTAssertTrue(s.rawSegments.isEmpty && s.events.isEmpty)
    }
}
