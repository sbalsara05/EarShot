import XCTest
@testable import EarshotCore

final class LiveSessionTests: XCTestCase {
    func testLiveSessionMatchesBatchBehaviour() {
        let pcm = burstPCM(seconds: 8, bursts: [(1, 2.5), (5, 6.5)])
        let packets = ReplayFile.packets(fromPCM: pcm, taps: [TapInput(clipMs: 1500, source: "button", gesture: "yes"),
                                                              TapInput(clipMs: 1000 + 5200, source: "button")], startClipMs: 1000)
        let s = LiveSession(dict: TestEnv.dict, config: PipelineConfig(), callId: "c9", startEpochMs: 1_763_233_200_000, tzOffsetSeconds: -18000,
                            transcriber: ScriptedTranscriber(["BP 120 over 80, pulse 88.", "gave 4 milligrams zofran IV"]))
        s.callbackQueue = DispatchQueue(label: "cb")
        let src = ReplayPacketSource(packets: packets)
        s.source = src
        for p in packets { s.handle(p) }
        s.handle(.state(PacketHeader(type: .state, seq: 1, clipMs: 9000), StatePayload(state: .off)))
        s.drain()
        XCTAssertEqual(s.rawSegments.count, 2)
        XCTAssertEqual(s.events.first { $0.type == .medication }?.source, .tapHeard)
        XCTAssertEqual(s.events.first { $0.type == .consent }?.fields["consent"], "yes")
        XCTAssertEqual(src.sent.filter { if case .ack = $0 { return true }; return false }.count, 4, "every tap is acked (start, yes, mark, stop)")
        XCTAssertLessThan(s.audioSecondsHeld, 3, "audio is freed after transcription")
        s.wipe()
        XCTAssertTrue(s.events.isEmpty)
    }

    func testAudioIgnoredBeforeConsent() {
        let pcm = burstPCM(seconds: 3, bursts: [(1, 2)])
        // audio with no consent flow at all (a broken clip): never transcribed
        let packets = ReplayFile.packets(fromPCM: pcm, startClipMs: 1000).filter { if case .audio = $0 { return true }; return false }
        let asr = ScriptedTranscriber(["should never be heard"])
        let s = LiveSession(dict: TestEnv.dict, config: PipelineConfig(), callId: "c1", startEpochMs: 0, tzOffsetSeconds: 0, transcriber: asr)
        s.callbackQueue = DispatchQueue(label: "cb")
        for p in packets { s.handle(p) }
        s.drain()
        XCTAssertTrue(s.rawSegments.isEmpty)
        XCTAssertEqual(asr.lines.count, 1)
    }

    func testMedicLabelsUnlabeledTap() {
        let s = LiveSession(dict: TestEnv.dict, config: PipelineConfig(), callId: "c1", startEpochMs: 0, tzOffsetSeconds: 0, transcriber: nil)
        s.callbackQueue = DispatchQueue(label: "cb")
        s.handle(.state(PacketHeader(type: .state, seq: 0, clipMs: 1000), StatePayload(state: .listening)))
        s.handle(.tap(PacketHeader(type: .tap, seq: 0, clipMs: 5000), TapPayload(gesture: .mark, source: .button, pressClipMs: 5000)))
        s.drain()
        let tap = s.events.first { $0.isUnlabeledTap }!
        s.medicEntry(type: .procedure, fields: ["procedure": "12-lead ECG"], forTapId: tap.id, at: 0)
        s.drain()
        let e = s.events.first { $0.type == .procedure }!
        XCTAssertEqual(e.enteredBy, "medic"); XCTAssertEqual(e.tMs, tap.tMs); XCTAssertEqual(e.source, .tablet)
        XCTAssertFalse(s.events.contains { $0.isUnlabeledTap })
    }
}
