import XCTest
@testable import EarshotCore

final class ConformanceTests: XCTestCase {
    func stream() -> [Packet] {
        ReplayFile.packets(fromPCM: burstPCM(seconds: 6, bursts: [(1, 2)]), taps: [TapInput(clipMs: 3000, source: "button")], startClipMs: 1000)
    }
    func failing(_ r: ConformanceReport) -> [String] { r.checks.filter { !$0.pass }.map(\.id) }

    func testGeneratedStreamConforms() {
        let r = StreamConformance.check(packets: stream())
        XCTAssertTrue(r.pass, "\(r.checks.filter { !$0.pass })")
        XCTAssertEqual(r.stats["audio_kbps"]!, 68.4, accuracy: 1.0)
    }

    func testAudioBeforeConsentFailsC1() {
        var p = stream()
        p.insert(.audio(PacketHeader(type: .audio, seq: 999, clipMs: 100), adpcm: [UInt8](repeating: 0, count: Wire.audioPayloadSize)), at: 1)
        XCTAssertTrue(failing(StreamConformance.check(packets: p)).contains("C1"))
    }

    func testIllegalTransitionAndMarkOutsideListening() {
        var p = stream()
        p.insert(.state(PacketHeader(type: .state, seq: 50, clipMs: 200), StatePayload(state: .listening, flags: 1, version: 1)), at: 1)  // OFF -> LISTENING
        p.insert(.tap(PacketHeader(type: .tap, seq: 77, clipMs: 150), TapPayload(gesture: .mark, source: .button, pressClipMs: 150)), at: 1)
        let f = failing(StreamConformance.check(packets: p))
        XCTAssertTrue(f.contains("C2")); XCTAssertTrue(f.contains("T1"))
    }

    func testLossAndMissingVersion() {
        var p = stream()
        var dropped = 0
        p.removeAll { if case .audio(let h, _) = $0, h.seq % 20 == 0 { dropped += 1; return true }; return false }
        p = p.map { if case .state(let h, var s) = $0 { s.version = nil; return .state(h, s) }; return $0 }
        let f = failing(StreamConformance.check(packets: p))
        XCTAssertTrue(f.contains("A1")); XCTAssertTrue(f.contains("W2"))
    }

    func testRawBytesWithGarbage() {
        var bytes: [UInt8] = []
        for p in stream() { bytes += Wire.frame(p) }
        bytes += [3, 0, 0x7F, 1, 2]   // unknown packet type
        XCTAssertTrue(failing(StreamConformance.check(rawBytes: bytes)).contains("W1"))
    }
}
