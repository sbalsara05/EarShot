import Foundation

// MARK: - Packet sources

/// One protocol for every transport. BLE and Wi-Fi live in the app
/// (CoreBluetooth / Network.framework); replay lives here so it runs
/// everywhere, including the Simulator and Linux tests.
public protocol PacketSource: AnyObject {
    var name: String { get }
    var onPacket: ((Packet) -> Void)? { get set }
    var onStatus: ((LinkStatus) -> Void)? { get set }
    func start()
    func stop()
    /// iPad -> clip writes (clock, ack, state). Replay ignores them.
    func send(_ p: Packet)
}

public struct LinkStatus: Equatable, Sendable {
    public var connected: Bool
    public var transport: String
    public var detail: String
    public var kbps: Double
    public var lossPct: Double
    public init(connected: Bool, transport: String, detail: String = "", kbps: Double = 0, lossPct: Double = 0) {
        self.connected = connected; self.transport = transport; self.detail = detail; self.kbps = kbps; self.lossPct = lossPct
    }
}

/// Plays a replay file at real time (speed 1) or faster.
public final class ReplayPacketSource: PacketSource {
    public let name = "Replay"
    public var onPacket: ((Packet) -> Void)?
    public var onStatus: ((LinkStatus) -> Void)?
    private let packets: [Packet]
    private let speed: Double
    private var timer: DispatchSourceTimer?
    private var idx = 0
    private var t0 = Date()
    private let queue = DispatchQueue(label: "earshot.replay")
    public private(set) var sent: [Packet] = []

    public init(packets: [Packet], speed: Double = 1) { self.packets = packets; self.speed = max(0.1, speed) }
    public convenience init(url: URL, speed: Double = 1) throws { self.init(packets: try ReplayFile.read(url), speed: speed) }

    public func start() {
        guard timer == nil else { return }
        idx = 0; t0 = Date()
        onStatus?(LinkStatus(connected: true, transport: name, detail: "\(packets.count) packets"))
        let base = packets.first?.header.clipMs ?? 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let elapsed = Date().timeIntervalSince(self.t0) * 1000 * self.speed
            while self.idx < self.packets.count, Double(self.packets[self.idx].header.clipMs &- base) <= elapsed {
                let p = self.packets[self.idx]; self.idx += 1
                self.onPacket?(p)
            }
            if self.idx >= self.packets.count { self.stop() }
        }
        timer = t
        t.resume()
    }
    public func stop() {
        timer?.cancel(); timer = nil
        onStatus?(LinkStatus(connected: false, transport: name, detail: "ended"))
    }
    public func send(_ p: Packet) { sent.append(p) }
}

// MARK: - Ledger

/// Everything that ever left the device. Audio bytes sent is always 0:
/// audio is never written to disk or sent anywhere.
public final class Ledger: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var time: String
        public var what: String
        public var destination: String
        public var bytes: Int
    }
    public private(set) var entries: [Entry] = []
    public let audioBytesSent = 0
    private let lock = NSLock()
    public init() {}
    public func record(what: String, destination: String, bytes: Int, at time: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        entries.append(Entry(time: ISO8601DateFormatter().string(from: time), what: what, destination: destination, bytes: bytes))
    }
}

// MARK: - Live session

/// The live call pipeline used by the iPad app: packets -> ADPCM decode ->
/// in-memory ring buffer -> VAD -> whisper (background queue) -> cleanup
/// (batched ~30 s) -> rules extraction -> tap merge -> events. Audio is held
/// only in memory and each chunk is freed right after it is transcribed.
public final class LiveSession {
    public let dict: EMSDictionary
    public let config: PipelineConfig
    public let callId: String
    public private(set) var clock: CallClock
    public var transcriber: Transcriber?
    public var tagger: TokenTagger?

    /// Called on `callbackQueue` whenever events change.
    public var onEvents: (([EarshotEvent]) -> Void)?
    public var onState: ((ClipState) -> Void)?
    public var callbackQueue = DispatchQueue.main

    public private(set) var state: ClipState = .off
    public private(set) var rawSegments: [RawSegment] = []
    public private(set) var events: [EarshotEvent] = []
    public private(set) var audioSecondsHeld: Double = 0

    private let work = DispatchQueue(label: "earshot.live")       // packet handling, VAD, merge
    private let asrQueue = DispatchQueue(label: "earshot.asr")    // whisper (slow)
    private let assembler = AudioAssembler(reorderDepth: 10)
    private let ring = PCMRingBuffer(capacitySeconds: 90)
    private let vad: EnergyVAD
    private let cleaner: Cleanup
    private let rules: RulesExtractor
    private var clean: [String: CleanSegment] = [:]
    private var findings: [String: [Finding]] = [:]
    private var pendingClean: [RawSegment] = []
    private var lastCleanFlush = Date()
    private var taps: [PlacedTap] = []
    private var tablet: [EarshotEvent] = []
    private var segCounter = 0
    private var firstClip: Int64?
    private var sampleCursor: Int64 = 0
    private var gapList: [(Int64, Int64, Int)] = []
    private var lastAckedTapSeq: UInt16?
    public weak var source: PacketSource?

    public init(dict: EMSDictionary, config: PipelineConfig, callId: String, startEpochMs: Int64, tzOffsetSeconds: Int,
                transcriber: Transcriber?, tagger: TokenTagger? = nil) {
        self.dict = dict; self.config = config; self.callId = callId
        self.clock = CallClock(startEpochMs: startEpochMs, tzOffsetSeconds: tzOffsetSeconds)
        self.transcriber = transcriber; self.tagger = tagger
        vad = EnergyVAD(config.vad); cleaner = Cleanup(dict: dict); rules = RulesExtractor(dict: dict)
    }

    // MARK: input

    public func handle(_ p: Packet) {
        work.async { self._handle(p) }
    }

    private func _handle(_ p: Packet) {
        switch p {
        case .state(_, let s):
            state = s.state
            let st = s.state
            callbackQueue.async { self.onState?(st) }
            if st == .off { finishAudio() }
        case .tap(let h, let t):
            // ack every tap (the clip resends until acked), dedupe in the assembler
            source?.send(.ack(PacketHeader(type: .ack, seq: 0, clipMs: 0), ackedSeq: h.seq))
            let before = assembler.taps.count
            _ = assembler.push(p)
            guard assembler.taps.count > before else { return }
            if t.gesture == .no {
                // refusal: logged, nothing captured
                addTap(t, h); return
            }
            if t.gesture == .yes || t.gesture == .mark { addTap(t, h) }
            if t.gesture == .stop { finishAudio() }
        case .audio(let h, _):
            // consent gate is enforced in firmware; double-check here
            guard state == .listening else { return }
            if firstClip == nil { firstClip = Int64(h.clipMs) }
            let pcm = assembler.push(p)
            ingest(pcm)
            syncGaps()
        case .clock, .ack:
            _ = assembler.push(p)
        }
    }

    /// Tap made on the tablet (arrival button, nurse accept, manual mark).
    public func tabletTap(gesture: String, at date: Date = Date()) {
        work.async {
            let t = date.timeIntervalSince1970 * 1000
            let tMs = Int64(t) - self.clock.startEpochMs
            self.taps.append(PlacedTap(tMs: tMs, source: "tablet", gesture: gesture, clipMs: -1))
            self.remerge()
        }
    }

    /// A value the medic typed (recall screen). Labeled as theirs.
    public func medicEntry(type: EventType, fields: [String: String], forTapId: String? = nil, at tMs: Int64) {
        work.async {
            var e = EarshotEvent(id: "", callId: self.callId, time: self.clock.iso(tMs), tMs: tMs, type: type, fields: fields,
                                 source: .tablet, quote: nil, rawSpan: nil, confidence: 1,
                                 models: ModelInfo(asr: "none", extract: "medic"), enteredBy: "medic")
            if let t = forTapId { e.fields["labels_tap"] = t }
            self.tablet.append(e)
            self.remerge()
        }
    }

    private func addTap(_ t: TapPayload, _ h: PacketHeader) {
        let base = firstClip ?? Int64(t.pressClipMs)
        if firstClip == nil { firstClip = base }
        taps.append(PlacedTap(tMs: Int64(t.pressClipMs) - base, source: t.source.name, gesture: t.gesture.name, clipMs: Int64(t.pressClipMs)))
        remerge()
    }

    private func ingest(_ pcm: [Int16]) {
        guard !pcm.isEmpty else { return }
        ring.append(pcm)
        sampleCursor += Int64(pcm.count)
        for chunk in vad.push(pcm) { transcribe(chunk) }
        audioSecondsHeld = Double(ring.endSample - ring.baseSample) / 16000
    }

    private func finishAudio() {
        ingest(assembler.finish())
        for chunk in vad.finish() { transcribe(chunk) }
        asrQueue.async { self.work.async { self.flushClean(force: true) } }
    }

    private func syncGaps() {
        guard let base = firstClip else { return }
        let g = assembler.gaps.map { ($0.startClipMs - base, $0.endClipMs - base, $0.missingFrames) }
        if g.count != gapList.count { gapList = g; remerge() }
    }

    private func transcribe(_ c: SpeechChunk) {
        let audio = ring.read(from: c.startSample, to: c.endSample).map { Float($0) / 32768 }
        ring.discard(before: c.endSample)            // free audio as soon as it is handed to ASR
        guard let tr = transcriber else { return }
        let prompt = config.asr.useInitialPrompt ? (config.asr.prompt ?? dict.initialPrompt()) : nil
        asrQueue.async {
            let pieces = (try? tr.transcribe(audio, prompt: prompt)) ?? []
            self.work.async {
                for p in pieces {
                    if ASRFilter.isHallucination(p.text) { continue }
                    guard let seg = p.rawSegment(id: "s\(self.segCounter + 1)", chunkStartMs: c.startMs, chunkEndMs: c.endMs) else { continue }
                    self.segCounter += 1
                    self.rawSegments.append(seg)
                    self.pendingClean.append(seg)
                }
                self.flushClean(force: false)
            }
        }
    }

    /// Cleanup runs in ~30 s batches (or on every new segment when the call is
    /// quiet), then extraction; merge reruns over everything (cheap).
    private func flushClean(force: Bool) {
        guard !pendingClean.isEmpty else { return }
        let spanMs = (pendingClean.last!.endMs - pendingClean.first!.startMs)
        guard force || spanMs >= 30000 || Date().timeIntervalSince(lastCleanFlush) > 3 || pendingClean.count >= 1 else { return }
        for s in pendingClean {
            let (c, _) = cleaner.clean(s)
            clean[s.id] = c
            var f = rules.extract(c)
            if let tg = tagger, let extra = try? TaggerMerge(dict: dict, tagger: tg).findings([c], existing: f) { f += extra }
            findings[s.id] = f
        }
        pendingClean.removeAll()
        lastCleanFlush = Date()
        remerge()
    }

    private func remerge() {
        let models = ModelInfo(asr: transcriber?.modelName ?? "none", extract: RulesExtractor.version + (tagger.map { "+" + $0.name } ?? ""))
        let merger = TapMerger(cfg: config.merge, callId: callId, clock: clock, models: models)
        var times: [String: (Int64, Int64)] = [:]
        for s in rawSegments { times[s.id] = (s.startMs, s.endMs) }
        let all = rawSegments.flatMap { findings[$0.id] ?? [] }
        var ev = merger.merge(findings: all, segments: times, taps: taps, gaps: gapList, extra: [])
        // medic-typed entries: labels for taps replace the unlabeled tap event
        for m in tablet {
            if let t = m.fields["labels_tap"], let i = ev.firstIndex(where: { $0.id == t && $0.isUnlabeledTap }) {
                var e = m; e.tMs = ev[i].tMs; e.time = ev[i].time; e.tapSource = ev[i].tapSource; e.fields.removeValue(forKey: "labels_tap")
                ev[i] = e
            } else {
                var e = m; e.fields.removeValue(forKey: "labels_tap"); ev.append(e)
            }
        }
        ev.sort { ($0.tMs, $0.id) < ($1.tMs, $1.id) }
        for k in ev.indices where ev[k].source == .tablet && ev[k].enteredBy != nil { ev[k].id = "m\(k + 1)" }
        events = ev
        let snapshot = ev
        callbackQueue.async { self.onEvents?(snapshot) }
    }

    // MARK: outputs

    public func chartModel() -> ChartModel { ChartModel(events: events, callId: callId, clock: clock) }
    public func render() -> [RenderedDoc] {
        let m = chartModel()
        return [Renderers.soap(m), Renderers.chart(m), Renderers.imistAmbo(m), NEMSISExport.render(m, events: events, dict: dict)]
    }
    public func cleanSegment(_ id: String) -> CleanSegment? { work.sync { clean[id] } }
    /// Transcript context around a time (recall screen), from raw segments.
    public func transcriptAround(_ tMs: Int64, windowMs: Int64 = 8000) -> [RawSegment] {
        work.sync { rawSegments.filter { $0.endMs >= tMs - windowMs && $0.startMs <= tMs + windowMs } }
    }

    /// Medic signed: wipe everything (audio, transcript, events).
    public func wipe() {
        work.sync {
            ring.wipe(); rawSegments.removeAll(); clean.removeAll(); findings.removeAll(); events.removeAll()
            taps.removeAll(); tablet.removeAll(); pendingClean.removeAll()
        }
    }

    /// Wait until queued work is done (tests).
    public func drain() { asrQueue.sync {}; work.sync {}; asrQueue.sync {}; work.sync {} }
}
