import Foundation

/// ASR engine slot. whisper.cpp (EarshotWhisper) is the default; tests use
/// scripted transcribers.
public protocol Transcriber: AnyObject {
    var modelName: String { get }
    /// Transcribe one speech chunk (16 kHz mono float). Times are relative to
    /// the chunk start, in ms.
    func transcribe(_ pcm: [Float], prompt: String?) throws -> [ASRPiece]
}

public struct ASRPiece: Equatable, Sendable {
    public var startMs: Int64
    public var endMs: Int64
    public var text: String
    public var avgLogprob: Double?
    /// Token timings when the engine provides them: (character offset in `text`, start ms, end ms), relative to the chunk.
    public var tokens: [ASRToken]
    public init(startMs: Int64, endMs: Int64, text: String, avgLogprob: Double? = nil, tokens: [ASRToken] = []) {
        self.startMs = startMs; self.endMs = endMs; self.text = text; self.avgLogprob = avgLogprob; self.tokens = tokens
    }
}

public struct ASRToken: Equatable, Sendable {
    public var charOffset: Int
    public var startMs: Int64
    public var endMs: Int64
    public init(charOffset: Int, startMs: Int64, endMs: Int64) { self.charOffset = charOffset; self.startMs = startMs; self.endMs = endMs }
}

extension ASRPiece {
    /// Raw segment with call-relative times taken from the first/last token when available
    /// (VAD chunks can start well before the speech), and per-token times for findings.
    public func rawSegment(id: String, chunkStartMs: Int64, chunkEndMs: Int64) -> RawSegment? {
        let lead = text.prefix { $0.isWhitespace }.count
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var start = chunkStartMs + startMs, end = min(chunkEndMs, chunkStartMs + endMs)
        var wt: [[Int64]]? = nil
        let toks = tokens.filter { $0.endMs >= $0.startMs }
        if let f = toks.first, let l = toks.last {
            start = max(start, chunkStartMs + f.startMs)
            end = max(start, min(chunkEndMs, chunkStartMs + max(l.endMs, l.startMs)))
            wt = toks.map { [Int64(max(0, $0.charOffset - lead)), chunkStartMs + $0.startMs] }
        }
        return RawSegment(id: id, startMs: start, endMs: end, text: t, avgLogprob: avgLogprob, wordTimes: wt)
    }
}

/// Token tagger slot (EMSTagger Core ML model when present).
public struct TaggedSpan: Equatable, Sendable {
    public var label: String       // DRUG DOSE UNIT ROUTE VITAL
    public var start: Int          // clean token index (inclusive)
    public var end: Int            // inclusive
    public init(label: String, start: Int, end: Int) { self.label = label; self.start = start; self.end = end }
}
public protocol TokenTagger: AnyObject {
    var name: String { get }
    func tag(_ tokens: [String]) throws -> [TaggedSpan]
}

public struct PipelineConfig: Codable, Sendable {
    public struct ASR: Codable, Sendable {
        public var engine: String = "whisper.cpp"
        public var model: String? = nil
        public var name: String = "whisper.cpp small.en"
        public var threads: Int = 4
        public var useInitialPrompt: Bool = true
        /// Prompt text; nil = the dictionary's sentence-style prompt.
        public var prompt: String? = nil
        /// 1 = greedy. Beam search is slower but more accurate on noisy audio (review R3-4).
        public var beamSize: Int = 5
        /// Re-decode low-confidence windows at higher temperature (whisper.cpp fallback; deterministic seed).
        public var temperatureFallback: Bool = true
        public init() {}
        enum CodingKeys: String, CodingKey { case engine, model, name, threads, useInitialPrompt = "use_initial_prompt", prompt, beamSize = "beam_size", temperatureFallback = "temperature_fallback" }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? "whisper.cpp"
            model = try c.decodeIfPresent(String.self, forKey: .model)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "whisper.cpp small.en"
            threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? 4
            useInitialPrompt = try c.decodeIfPresent(Bool.self, forKey: .useInitialPrompt) ?? true
            prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
            beamSize = try c.decodeIfPresent(Int.self, forKey: .beamSize) ?? 5
            temperatureFallback = try c.decodeIfPresent(Bool.self, forKey: .temperatureFallback) ?? true
        }
    }
    public var callId: String = "c1"
    public var startTime: String? = nil   // nil: use clip clock sync, else an assumed start (flagged in outputs)
    public static let assumedStart = "2026-11-15T14:00:00-05:00"
    public var asr = ASR()
    public var tagger: String? = nil
    public var vad = VADConfig()
    public var merge = MergeConfig()
    public var agency = NEMSISAgency()
    public var piiScrub: Bool = false   // PII kept by default (ePCR needs it); scrub is opt-in
    public init() {}
    enum CodingKeys: String, CodingKey { case callId = "call_id", startTime = "start_time", asr, tagger, vad, merge, piiScrub = "pii_scrub", agency }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        callId = try c.decodeIfPresent(String.self, forKey: .callId) ?? "c1"
        startTime = try c.decodeIfPresent(String.self, forKey: .startTime)
        asr = try c.decodeIfPresent(ASR.self, forKey: .asr) ?? ASR()
        tagger = try c.decodeIfPresent(String.self, forKey: .tagger)
        vad = try c.decodeIfPresent(VADConfig.self, forKey: .vad) ?? VADConfig()
        merge = try c.decodeIfPresent(MergeConfig.self, forKey: .merge) ?? MergeConfig()
        piiScrub = try c.decodeIfPresent(Bool.self, forKey: .piiScrub) ?? false
        agency = try c.decodeIfPresent(NEMSISAgency.self, forKey: .agency) ?? NEMSISAgency()
    }
}

public enum PipelineInput {
    /// 16 kHz mono PCM; tap clip_ms are ms from the start of the audio.
    case pcm([Int16], taps: [TapInput])
    /// Replay packets; tap clip_ms (in packets or extra) are clip-boot ms.
    case packets([Packet], extraTaps: [TapInput])
    /// Pre-made raw transcript (skips audio + ASR). Tap clip_ms = call ms.
    case transcript(RawTranscript, taps: [TapInput])
}

public struct PipelineResult {
    public var raw: RawTranscript
    public var clean: CleanTranscript
    public var events: [EarshotEvent]
    public var docs: [RenderedDoc]
    public var timing: [String: Double]
    public var stats: [String: Int]
    public var notes: [String] = []
}

public enum PipelineError: Error, CustomStringConvertible {
    case noTranscriber, badStartTime(String)
    public var description: String {
        switch self {
        case .noTranscriber: return "audio input needs an ASR engine (build with whisper.cpp, or pass --transcript)"
        case .badStartTime(let s): return "bad start_time: \(s)"
        }
    }
}

/// Offline (batch) pipeline used by earshot-eval and tests. Same stages and
/// rendering code as the live app path.
public final class EarshotPipeline {
    public let dict: EMSDictionary
    public let config: PipelineConfig
    public let transcriber: Transcriber?
    public let tagger: TokenTagger?

    public init(dict: EMSDictionary, config: PipelineConfig, transcriber: Transcriber?, tagger: TokenTagger? = nil) {
        self.dict = dict; self.config = config; self.transcriber = transcriber; self.tagger = tagger
    }

    public func run(_ input: PipelineInput) throws -> PipelineResult {
        var clock: CallClock
        var clockSource = "explicit"
        if let st = config.startTime {
            guard let c = CallClock(iso: st) else { throw PipelineError.badStartTime(st) }
            clock = c
        } else { clock = CallClock(iso: PipelineConfig.assumedStart)!; clockSource = "assumed" }
        var timing: [String: Double] = [:]
        var stats: [String: Int] = [:]
        func timed<T>(_ k: String, _ f: () throws -> T) rethrows -> T {
            let t0 = Date(); defer { timing[k, default: 0] += Date().timeIntervalSince(t0) }
            return try f()
        }
        var notes: [String] = []
        var taps: [PlacedTap] = []
        var gaps: [(Int64, Int64, Int)] = []
        var raw: RawTranscript
        let asrName = transcriber?.modelName ?? config.asr.name

        switch input {
        case .transcript(let t, let tp):
            taps = tp.map { PlacedTap(tMs: $0.clipMs, source: $0.source, gesture: $0.gesture, clipMs: $0.clipMs) }
            let windows = Consent.windows(taps, endMs: Int64.max)
            raw = t
            raw.segments = t.segments.filter { s in windows.contains { s.startMs >= $0.0 && s.startMs < $0.1 } }
            stats["segments_outside_consent"] = t.segments.count - raw.segments.count
        case .pcm(var pcm, let tp):
            taps = tp.map { PlacedTap(tMs: $0.clipMs, source: $0.source, gesture: $0.gesture, clipMs: $0.clipMs) }
            Consent.gate(&pcm, taps: taps)
            raw = try timed("asr_total") { try transcribeAll(pcm, &timing, &stats, asrName) }
        case .packets(let packets, let extra):
            let asm = AudioAssembler(reorderDepth: Int.max)
            var pcm: [Int16] = []
            try timed("decode") {
                for p in packets { pcm += asm.push(p) }
                pcm += asm.finish()
                _ = try Optional(0) // keep closure throwing-compatible
            }
            let base = asm.firstClipMs ?? 0
            for t in asm.taps + extra {
                taps.append(PlacedTap(tMs: t.clipMs - base, source: t.source, gesture: t.gesture, clipMs: t.clipMs))
            }
            gaps = asm.gaps.map { ($0.startClipMs - base, $0.endClipMs - base, $0.missingFrames) }
            stats["frames"] = asm.framesReceived; stats["duplicates"] = asm.duplicates; stats["gaps"] = asm.gaps.count
            // wall clock from the iPad's clock-sync packet: epoch at clip time c -> call start = epoch - (c - base)
            if config.startTime == nil, let c = asm.clockOffsets.first {
                clock = CallClock(startEpochMs: c.epochMs - (c.clipMs - base), tzOffsetSeconds: clock.tzOffsetSeconds)
                clockSource = "clip clock sync"
            }
            Consent.gate(&pcm, taps: taps)
            raw = try timed("asr_total") { try transcribeAll(pcm, &timing, &stats, asrName) }
            pcm.removeAll() // drop audio as soon as it is transcribed
        }
        raw.callId = config.callId

        // cleanup
        let cleaner = Cleanup(dict: dict)
        var cleanSegs: [CleanSegment] = []
        var corrections: [Correction] = []
        timed("cleanup") {
            for s in raw.segments {
                let (c, k) = cleaner.clean(s); cleanSegs.append(c); corrections += k
            }
        }
        // extraction
        let rules = RulesExtractor(dict: dict)
        var findings: [Finding] = []
        timed("extract_rules") { for c in cleanSegs { findings += rules.extract(c) } }
        if let tg = tagger {
            try timed("extract_tagger") { findings += try TaggerMerge(dict: dict, tagger: tg).findings(cleanSegs, existing: findings) }
        }
        // merge
        let models = ModelInfo(asr: asrName, extract: RulesExtractor.version + (tagger.map { "+" + $0.name } ?? ""))
        let merger = TapMerger(cfg: config.merge, callId: config.callId, clock: clock, models: models)
        var segTimes: [String: (Int64, Int64)] = [:]
        for s in raw.segments { segTimes[s.id] = (s.startMs, s.endMs) }
        var events = timed("merge") { merger.merge(findings: findings, segments: segTimes, taps: taps, gaps: gaps) }
        // PII scrub (quotes and field values; raw transcript stays raw)
        if config.piiScrub {
            timed("pii") {
                let pii = PIIScrubber()
                for s in raw.segments { pii.learn(s.text) }
                events = events.map(pii.scrub)
                stats["pii_tokens"] = pii.vault.count
            }
        }
        // render
        var docs: [RenderedDoc] = []
        timed("render") {
            let m = ChartModel(events: events, callId: config.callId, clock: clock)
            docs = [Renderers.soap(m), Renderers.chart(m), Renderers.imistAmbo(m), NEMSISExport.render(m, events: events, dict: dict, agency: config.agency)]
        }
        if clockSource == "assumed" {
            let note = "> Clock: no start time given and no clip clock sync, so wall-clock times assume a start of \(PipelineConfig.assumedStart). Elapsed times are real.\n\n"
            docs = docs.map { $0.name.hasSuffix(".md") ? RenderedDoc(name: $0.name, text: note + $0.text) : RenderedDoc(name: $0.name, text: $0.text.replacingOccurrences(of: "<!-- Every element", with: "<!-- CLOCK ASSUMED: times are relative to an assumed start. -->\n<!-- Every element")) }
        }
        notes.append("clock: \(clockSource)")
        stats["segments"] = raw.segments.count; stats["events"] = events.count; stats["corrections"] = corrections.count
        stats["taps"] = taps.count
        let clean = CleanTranscript(segments: cleanSegs.map { .init(rawSpan: $0.rawSpan, text: $0.text) }, corrections: corrections)
        return PipelineResult(raw: raw, clean: clean, events: events, docs: docs, timing: timing, stats: stats, notes: notes)
    }

    func transcribeAll(_ pcm: [Int16], _ timing: inout [String: Double], _ stats: inout [String: Int], _ asrName: String) throws -> RawTranscript {
        guard let tr = transcriber else { throw PipelineError.noTranscriber }
        let vad = EnergyVAD(config.vad)
        var chunks: [SpeechChunk] = []
        let t0 = Date()
        // feed in 20 ms frames like the live path
        var i = 0
        while i < pcm.count {
            let j = min(pcm.count, i + 320 * 50)
            chunks += vad.push(Array(pcm[i..<j])); i = j
        }
        chunks += vad.finish()
        timing["vad"] = Date().timeIntervalSince(t0)
        stats["speech_chunks"] = chunks.count
        let prompt = config.asr.useInitialPrompt ? (config.asr.prompt ?? dict.initialPrompt()) : nil
        var segs: [RawSegment] = []
        var n = 0
        for c in chunks {
            let a = Int(c.startSample), b = Int(min(Int64(pcm.count), c.endSample))
            guard b > a else { continue }
            let f = pcm[a..<b].map { Float($0) / 32768 }
            for p in try tr.transcribe(f, prompt: prompt) {
                if ASRFilter.isHallucination(p.text) { continue }
                guard let seg = p.rawSegment(id: "s\(n + 1)", chunkStartMs: c.startMs, chunkEndMs: c.endMs) else { continue }
                n += 1
                segs.append(seg)
            }
        }
        return RawTranscript(callId: config.callId, asrModel: asrName, initialPrompt: prompt, segments: segs)
    }
}

/// Drops well-known Whisper non-speech hallucinations.
public enum ASRFilter {
    static let junk: Set<String> = ["you", "thank you.", "thank you", "thanks for watching!", "."]
    static let tagRx = try! NSRegularExpression(pattern: #"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*"#)
    /// Text with Whisper's non-speech tags removed ("[beep]", "(siren)", "*cough*").
    public static func stripTags(_ s: String) -> String {
        tagRx.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
            .split(separator: " ").joined(separator: " ")
    }
    /// True when a segment holds no speech once tags are removed. A segment
    /// that keeps real words is kept whole (raw stays raw; cleanup drops the tags).
    public static func isHallucination(_ s: String) -> Bool {
        let rest = stripTags(s).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // "♪♪♪", "🎵", "..." : no letters or digits at all is not speech (review R4-2)
        return rest.isEmpty || junk.contains(rest) || !rest.contains(where: { $0.isLetter || $0.isNumber })
    }
}

/// Consent windows from the clip's gestures. With no consent gestures at all
/// (plain eval audio) everything counts. Otherwise audio counts only from a
/// "yes" until the next "stop" (or the end); a "no" captures nothing.
public enum Consent {
    public static func windows(_ taps: [PlacedTap], endMs: Int64) -> [(Int64, Int64)] {
        let g = taps.filter { ["yes", "no", "stop"].contains($0.gesture) }.sorted { $0.tMs < $1.tMs }
        guard !g.isEmpty else { return [(Int64.min, Int64.max)] }
        var out: [(Int64, Int64)] = []
        var open: Int64? = nil
        for t in g {
            switch t.gesture {
            case "yes": if open == nil { open = t.tMs }
            case "stop", "no": if let o = open { out.append((o, t.tMs)); open = nil }
            default: break
            }
        }
        if let o = open { out.append((o, endMs)) }
        return out
    }
    /// Zero audio outside consent windows (in memory) so it is never transcribed.
    public static func gate(_ pcm: inout [Int16], taps: [PlacedTap]) {
        let w = windows(taps, endMs: Int64(pcm.count) / 16)
        if w.count == 1 && w[0].0 == Int64.min { return }
        var keep = [Bool](repeating: false, count: pcm.count)
        for (a, b) in w {
            let s = Int(max(0, a) * 16), e = Int(min(Int64(pcm.count), b * 16))
            if e > s { for i in s..<e { keep[i] = true } }
        }
        for i in pcm.indices where !keep[i] { pcm[i] = 0 }
    }
}

/// Merges tagger spans into findings. The formulary has the final say on
/// drug names: a DRUG span with no formulary match becomes "heard, please
/// confirm", never a drug.
public struct TaggerMerge {
    let dict: EMSDictionary
    let tagger: TokenTagger
    public init(dict: EMSDictionary, tagger: TokenTagger) { self.dict = dict; self.tagger = tagger }

    public func findings(_ segs: [CleanSegment], existing: [Finding]) throws -> [Finding] {
        var out: [Finding] = []
        let covered = Set(existing.filter { $0.type == .medication || $0.fields["drug"] != nil }.flatMap { f in
            f.receipts.values.map { "\($0.rawSpan):\($0.rawRange?.first ?? -1)" }
        })
        for seg in segs where !seg.tokens.isEmpty {
            let tt = TokText(seg)
            for sp in try tagger.tag(seg.tokens.map(\.text)) where sp.label == "DRUG" {
                guard sp.start >= 0, sp.end < seg.tokens.count, sp.start <= sp.end else { continue }
                let r = sp.start...sp.end
                let key = "\(seg.rawSpan):\(seg.tokens[sp.start].rawStart)"
                if covered.contains(key) { continue }
                let phrase = seg.tokens[r].map(\.text).joined(separator: " ")
                let match = dict.aliasIndex[phrase] ?? dict.variantIndex[phrase] ?? {
                    let ds = dict.phoneticIndex[Phonetic.key(phrase.replacingOccurrences(of: " ", with: ""))] ?? []
                    return ds.count == 1 ? ds[0] : nil
                }()
                if let di = match {
                    out.append(Finding(type: .status, fields: ["kind": "drug_mention", "drug": dict.drug(di).generic, "heard_as": tt.seg.quote(sp.start, sp.end)],
                                       receipts: ["drug": tt.receipt(r)], tMs: seg.timeOf(token: sp.start), rawSpan: seg.rawSpan,
                                       quote: seg.quote(sp.start, sp.end), confidence: 0.6, flags: ["confirm"], extractor: tagger.name))
                } else {
                    out.append(Finding(type: .status, fields: ["kind": "drug_mention", "heard_as": tt.seg.quote(sp.start, sp.end), "note": "heard, please confirm — not in formulary"],
                                       receipts: ["heard_as": tt.receipt(r)], tMs: seg.timeOf(token: sp.start), rawSpan: seg.rawSpan,
                                       quote: seg.quote(sp.start, sp.end), confidence: 0.4, flags: ["confirm"], extractor: tagger.name))
                }
            }
        }
        return out
    }
}
