import XCTest
@testable import EarshotCore

/// The clip firmware's protocol (firmware/lib/earshot_core/src/protocol.h) into the pipeline.
final class ClipProtocolTests: XCTestCase {
    // Messages exactly as the firmware writes them (protocol.cpp / BLUETOOTH.md).
    func testParsesFirmwareEvents() {
        XCTAssertEqual(ClipProtocol.parseText(#"{"type":"hello","device":"Earshot-A3F2","fw":"0.6.0","audio":{"codec":"opus","rate":16000,"channels":1,"frame_ms":20,"bitrate":32000}}"#),
                       .hello(ClipHello(device: "Earshot-A3F2", firmware: "0.6.0", codec: "opus", bitrate: 32000)))
        XCTAssertEqual(ClipProtocol.parseText(#"{"type":"state","state":"listening","listening":true,"t_ms":41234}"#), .state(listening: true, clipMs: 41234))
        XCTAssertEqual(ClipProtocol.parseText(#"{"type":"consent","event":"granted","source":"button","t_ms":41230}"#), .consent(granted: true, source: "button", clipMs: 41230))
        XCTAssertEqual(ClipProtocol.parseText(#"{"type":"consent","event":"stopped","source":"tablet","t_ms":63010}"#), .consent(granted: false, source: "tablet", clipMs: 63010))
        XCTAssertEqual(ClipProtocol.parseText(#"{"type":"marker","id":1,"source":"button","t_ms":47781,"audio_seq":327}"#), .marker(id: 1, source: "button", clipMs: 47781, audioSeq: 327))
        // firmware 0.11: toggles, from firmware/APP_AGENT_PROMPT.md
        XCTAssertEqual(ClipProtocol.parseText(#"{"type":"toggle","target":"recording","source":"button","t_ms":52310}"#),
                       .toggle(target: "recording", source: "button", clipMs: 52310))
        XCTAssertEqual(ClipProtocol.parseText(#"{"type":"toggle","target":"call","source":"button","t_ms":91500}"#),
                       .toggle(target: "call", source: "button", clipMs: 91500))
        XCTAssertEqual(ClipProtocol.parseText(#"{"type":"toggle","source":"button","t_ms":5}"#), .toggle(target: "recording", source: "button", clipMs: 5))
        XCTAssertEqual(ClipProtocol.command(.find), #"{"cmd":"find"}"#)
        XCTAssertNil(ClipProtocol.parseText(#"{"type":"unknown"}"#))
        XCTAssertNil(ClipProtocol.parseText("not json"))
        XCTAssertEqual(ClipProtocol.command(.start), #"{"cmd":"start"}"#)
    }

    /// The recorded simulator run in firmware/evidence parses end to end.
    func testParsesRecordedSimulatorRun() throws {
        let url = TestEnv.repoRoot.appendingPathComponent("firmware/evidence/2026-11-13-sim-run/messages.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        var kinds: [String: Int] = [:]
        for l in lines {
            guard let o = try JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any], let msg = o["message"] else { continue }
            let text = String(data: try JSONSerialization.data(withJSONObject: msg), encoding: .utf8)!
            guard let m = ClipProtocol.parseText(text) else { continue }
            switch m {
            case .hello: kinds["hello", default: 0] += 1
            case .state: kinds["state", default: 0] += 1
            case .consent: kinds["consent", default: 0] += 1
            case .marker: kinds["marker", default: 0] += 1
            case .toggle: kinds["toggle", default: 0] += 1
            case .audio: break
            }
        }
        XCTAssertGreaterThan(kinds["hello"] ?? 0, 0)
        XCTAssertGreaterThan(kinds["consent"] ?? 0, 0)
        XCTAssertGreaterThan(kinds["marker"] ?? 0, 0)
    }

    func testAudioMessageRoundTrip() {
        let f = ClipAudioFrame(seq: 327, clipMs: 47781, payload: [1, 2, 3])
        let b = ClipProtocol.audioMessage(f)
        XCTAssertEqual(b.prefix(8), [0x47, 0x01, 0, 0, 0xA5, 0xBA, 0, 0])
        XCTAssertEqual(ClipProtocol.parseAudio(b), .audio(f))
        XCTAssertNil(ClipProtocol.parseAudio([0, 0, 0, 0, 0, 0, 0, 0]))
        let s: [Int16] = [0, 1, -1, 32767, -32768]
        XCTAssertEqual(try PCMFrameDecoder().decode(PCMFrameDecoder.encode(s)), s)
    }

    /// Two captures with a marker each. Clip time maps to call time through the wall clock at consent.
    func testTwoCapturesLandOnOneCallTimeline() {
        let start = Date(timeIntervalSince1970: 1_763_233_200)
        let s = LiveSession(dict: TestEnv.dict, config: PipelineConfig(), callId: "c1", startEpochMs: Int64(start.timeIntervalSince1970 * 1000),
                            tzOffsetSeconds: -18000, transcriber: ScriptedTranscriber(["BP 120 over 80, pulse 88.", "gave 4 milligrams zofran IV"]))
        s.callbackQueue = DispatchQueue(label: "cb")
        let dec = PCMFrameDecoder()
        // capture 1: consent 10 s into the call, clip clock 50,000; speech at 1-2.5 s; marker at 2 s
        feedCapture(s, dec, consentAt: start.addingTimeInterval(10), clipStart: 50_000,
                    pcm: burstPCM(seconds: 4, bursts: [(1, 2.5)]), markerAfterMs: 2000)
        // capture 2: 60 s into the call. The clip rebooted, so its clock is lower than before.
        feedCapture(s, dec, consentAt: start.addingTimeInterval(60), clipStart: 3_000,
                    pcm: burstPCM(seconds: 4, bursts: [(1, 2.5)]), markerAfterMs: nil)
        s.drain()
        XCTAssertEqual(s.rawSegments.count, 2)
        // speech starts ~1 s into each capture (minus the VAD pre-roll)
        XCTAssertEqual(Double(s.rawSegments[0].startMs), 11_000, accuracy: 400)
        XCTAssertEqual(Double(s.rawSegments[1].startMs), 61_000, accuracy: 400)
        XCTAssertEqual(s.events.filter { $0.type == .consent }.count, 2)
        XCTAssertEqual(s.events.first { $0.type == .vitals }.map { Double($0.tMs) } ?? 0, 11_000, accuracy: 1_500)
        XCTAssertEqual(s.events.first { $0.type == .medication }.map { Double($0.tMs) } ?? 0, 61_000, accuracy: 1_500)
        XCTAssertFalse(s.capturing)
    }

    func testLostFramesBecomeAGapAndAudioOutsideCaptureIsDropped() {
        let start = Date(timeIntervalSince1970: 1_000)
        let asr = ScriptedTranscriber(["should never be heard"])
        let s = LiveSession(dict: TestEnv.dict, config: PipelineConfig(), callId: "c1", startEpochMs: 1_000_000, tzOffsetSeconds: 0, transcriber: asr)
        s.callbackQueue = DispatchQueue(label: "cb")
        let dec = PCMFrameDecoder()
        // audio before consent: ignored
        s.handle(.audio(ClipAudioFrame(seq: 0, clipMs: 100, payload: PCMFrameDecoder.encode(burstPCM(seconds: 0.02, bursts: [(0, 0.02)])))), decoder: dec)
        s.drain()
        XCTAssertTrue(s.rawSegments.isEmpty)
        XCTAssertEqual(asr.lines.count, 1)
        // a capture with frames 50..59 missing (a link drop)
        s.handle(.consent(granted: true, source: "button", clipMs: 1_000), decoder: dec, receivedAt: start)
        let pcm = [Int16](repeating: 0, count: 320 * 100)
        for i in 0..<100 where !(50..<60).contains(i) {
            let frame = Array(pcm[(i * 320)..<((i + 1) * 320)])
            s.handle(.audio(ClipAudioFrame(seq: UInt32(i), clipMs: UInt32(1_000 + i * 20), payload: PCMFrameDecoder.encode(frame))), decoder: dec, receivedAt: start)
        }
        s.handle(.consent(granted: false, source: "button", clipMs: 3_000), decoder: dec, receivedAt: start)
        s.drain()
        let gap = s.events.first { $0.type == .audioGap }
        XCTAssertNotNil(gap)
        XCTAssertEqual(Double(gap?.tMs ?? 0), 1_000, accuracy: 25)   // frame 50 = 1 s into the capture
    }

    func testReconnectMidCaptureResumesFromState() {
        let s = LiveSession(dict: TestEnv.dict, config: PipelineConfig(), callId: "c1", startEpochMs: 0, tzOffsetSeconds: 0,
                            transcriber: ScriptedTranscriber(["pulse 88"]))
        s.callbackQueue = DispatchQueue(label: "cb")
        let dec = PCMFrameDecoder()
        // the app connects while the clip is already listening: hello, then state listening
        s.handle(.hello(ClipHello(device: "Earshot-A3F2", firmware: "0.6.0", codec: "pcm")), decoder: dec)
        s.handle(.state(listening: true, clipMs: 9_000), decoder: dec, receivedAt: Date(timeIntervalSince1970: 5))
        let pcm = burstPCM(seconds: 3, bursts: [(0.5, 2)])
        for i in 0..<(pcm.count / 320) {
            s.handle(.audio(ClipAudioFrame(seq: UInt32(400 + i), clipMs: UInt32(9_000 + i * 20),
                                           payload: PCMFrameDecoder.encode(Array(pcm[(i * 320)..<((i + 1) * 320)])))), decoder: dec)
        }
        s.handle(.state(listening: false, clipMs: 12_000), decoder: dec)
        s.drain()
        XCTAssertEqual(s.clipHello?.device, "Earshot-A3F2")
        XCTAssertEqual(s.rawSegments.count, 1)
        XCTAssertTrue(s.events.contains { $0.type == .vitals })
        XCTAssertFalse(s.events.contains { $0.type == .consent }, "consent happened before the app joined")
    }

    // MARK: helpers

    private func feedCapture(_ s: LiveSession, _ dec: PCMFrameDecoder, consentAt: Date, clipStart: UInt32, pcm: [Int16], markerAfterMs: UInt32?) {
        s.handle(.consent(granted: true, source: "button", clipMs: Int64(clipStart)), decoder: dec, receivedAt: consentAt)
        let n = pcm.count / 320
        for i in 0..<n {
            let t = clipStart + UInt32(i * 20)
            if let m = markerAfterMs, t == clipStart + m {
                s.handle(.marker(id: 1, source: "button", clipMs: Int64(t), audioSeq: Int64(i)), decoder: dec)
            }
            let payload = PCMFrameDecoder.encode(Array(pcm[(i * 320)..<((i + 1) * 320)]))
            s.handle(.audio(ClipAudioFrame(seq: UInt32(i), clipMs: t, payload: payload)), decoder: dec)
        }
        s.handle(.consent(granted: false, source: "button", clipMs: Int64(clipStart) + Int64(n * 20)), decoder: dec)
    }
}

extension ClipProtocolTests {
    func testDecodedAudioPathAndSegmentCallback() {
        let s = LiveSession(dict: TestEnv.dict, config: PipelineConfig(), callId: "c1", startEpochMs: 0, tzOffsetSeconds: 0,
                            transcriber: ScriptedTranscriber(["pulse 88"]))
        let cb = DispatchQueue(label: "cb")
        s.callbackQueue = cb
        var seen: [RawSegment] = []
        s.onSegments = { seen = $0 }
        s.handle(.consent(granted: true, source: "tablet", clipMs: 0), decoder: PCMFrameDecoder(), receivedAt: Date(timeIntervalSince1970: 0))
        let pcm = burstPCM(seconds: 3, bursts: [(0.5, 2)])
        for i in 0..<(pcm.count / 320) { s.handleDecodedAudio(seq: UInt32(i), clipMs: UInt32(i * 20), pcm: Array(pcm[(i * 320)..<((i + 1) * 320)])) }
        s.endCapture()
        s.drain(); cb.sync {}
        XCTAssertEqual(seen.map(\.text), ["pulse 88"])
        XCTAssertFalse(TestEnv.dict.liveVocabulary().isEmpty)
        XCTAssertLessThanOrEqual(TestEnv.dict.liveVocabulary().count, 100)
    }
}
