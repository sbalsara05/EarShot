import Foundation
import EarshotCore
#if canImport(EarshotWhisper)
import EarshotWhisper
#endif

let usage = """
earshot-eval — run the Earshot pipeline offline (same code as the iPad app).

USAGE
  earshot-eval run <input> [options]
  earshot-eval make-replay <in.wav> <out.replay> [--taps taps.json]
  earshot-eval check-stream <capture.replay> [--json out.json]
                          check a clip capture against docs/FIRMWARE_CONTRACT.md (exit 1 on failure)
  earshot-eval fake-clip [--port 7070] [--wav call.wav] [--taps taps.json] [--loop]
                          reference clip over TCP (Wi-Fi framing) for testing the app without hardware
  earshot-eval version

INPUT (by extension)
  .wav                16 kHz mono 16-bit PCM (other rates/channels are converted in memory)
  .replay / .bin      Earshot replay packet file (length-prefixed packets, docs/WIRE_FORMAT.md)
  .json               a raw transcript (skips audio + ASR): either transcript.raw.json from a
                      previous run, or a list [{"start_ms":0,"end_ms":2000,"text":"..."}]

OPTIONS
  --out <dir>             output folder (default: ./out/<input name>)
  --taps <file.json>      taps: [{"clip_ms": 12000, "source": "button"|"tablet",
                          "gesture": "mark"|"yes"|"no"|"arrival"|"handoff"}]  (gesture optional, default mark)
                          clip_ms = ms from audio start (wav/json) or clip-boot ms (replay)
  --config <file.json>    pipeline config (see docs/PIPELINE_READY.md)
  --asr-model <path>      whisper.cpp ggml model (stock: ggml-small.en.bin; fine-tuned: models/whisper-ems-small.en-q5.bin)
  --tagger <path|none>    EMSTagger.mlpackage (Core ML; macOS/iOS only) or none (default)
  --dict <dir>            folder with formulary.json + ems_terms.json (default: find ../shared)
  --threads <n>           whisper threads (default 4; keep fixed for repeatable output)
  --call-id <id>          default c1
  --start <iso8601>       call start wall time. Without it: replay clock-sync packet, else an assumed start that is flagged in every output
  --no-prompt             disable the EMS initial prompt for whisper
  --prompt-file <f>       use this initial prompt instead of the dictionary's
  --beam <n>              beam size (default 5); --greedy = beam 1, no temperature fallback (fastest)
  --pii-scrub             replace names/DOB/addresses/phones in quotes and fields with tokens (off by default)
"""

func fail(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(2)
}

func writeJSON<T: Encodable>(_ v: T, _ url: URL) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try (enc.encode(v) + Data("\n".utf8)).write(to: url)
}

struct SimpleSeg: Codable { var start_ms: Int64; var end_ms: Int64; var text: String; var id: String? }

func loadTranscript(_ url: URL) throws -> RawTranscript {
    let d = try Data(contentsOf: url)
    if let t = try? JSONDecoder().decode(RawTranscript.self, from: d) { return t }
    let segs = try JSONDecoder().decode([SimpleSeg].self, from: d)
    return RawTranscript(callId: "c1", asrModel: "provided transcript",
                         segments: segs.enumerated().map { RawSegment(id: $1.id ?? "s\($0 + 1)", startMs: $1.start_ms, endMs: $1.end_ms, text: $1.text) })
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { print(usage); exit(0) }
args.removeFirst()

func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i); return true
}

switch cmd {
case "version", "--version":
    print("earshot-eval 0.1.0 (EarshotCore \(RulesExtractor.version))")
    #if canImport(EarshotWhisper)
    print("whisper.cpp: linked")
    #else
    print("whisper.cpp: not linked (transcript input only)")
    #endif
    exit(0)
case "help", "--help", "-h":
    print(usage); exit(0)
case "make-replay":
    let tapsPath = opt("--taps")
    guard args.count >= 2 else { fail("make-replay <in.wav> <out.replay> [--taps taps.json]") }
    let pcm = try WAVReader.read(URL(fileURLWithPath: args[0]))
    var taps: [TapInput] = []
    if let t = tapsPath { taps = try JSONDecoder().decode([TapInput].self, from: Data(contentsOf: URL(fileURLWithPath: t))) }
    // tap file clip_ms are relative to audio start; the replay stream starts at clip 1000 ms.
    // Only clip gestures travel on the wire; tablet gestures (arrival/handoff) stay in the tap file.
    let wire = taps.filter { TapGesture(name: $0.gesture) != nil }
    let tablet = taps.filter { TapGesture(name: $0.gesture) == nil }
    if !tablet.isEmpty { print("note: \(tablet.count) tablet tap(s) (arrival/handoff) are not clip packets; pass them with --taps when running the replay (clip_ms + 1000)") }
    let shifted = wire.map { TapInput(clipMs: $0.clipMs + 1000, source: $0.source, gesture: $0.gesture) }
    let packets = ReplayFile.packets(fromPCM: pcm, taps: shifted, startClipMs: 1000)
    try ReplayFile.write(packets, to: URL(fileURLWithPath: args[1]))
    print("wrote \(packets.count) packets (\(pcm.count / 16000) s audio, \(taps.count) taps) to \(args[1])")
    exit(0)
case "check-stream":
    let jsonOut = opt("--json")
    guard let path = args.first else { fail("check-stream <capture.replay> [--json out.json]") }
    guard let capture = try? Data(contentsOf: URL(fileURLWithPath: path)) else { fail("cannot read \(path)") }
    let r = StreamConformance.check(rawBytes: [UInt8](capture))
    for c in r.checks { print("\(c.pass ? "PASS" : "FAIL")  \(c.id)  \(c.detail)") }
    print(r.stats.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
    print(r.pass ? "CONFORMS" : "DOES NOT CONFORM")
    if let j = jsonOut { try writeJSON(r, URL(fileURLWithPath: j)) }
    exit(r.pass ? 0 : 1)
case "fake-clip":
    let port = UInt16(opt("--port") ?? "7070") ?? 7070
    let wav = opt("--wav"); let tapsFile = opt("--taps"); let loop = flag("--loop")
    var pcm: [Int16]
    if let w = wav { pcm = try WAVReader.read(URL(fileURLWithPath: w)) } else { pcm = [Int16](repeating: 0, count: 16000 * 10) }
    var ftaps: [TapInput] = []
    if let t = tapsFile { ftaps = try JSONDecoder().decode([TapInput].self, from: Data(contentsOf: URL(fileURLWithPath: t))) }
    try FakeClip(port: port, packets: ReplayFile.packets(fromPCM: pcm, taps: ftaps.map { TapInput(clipMs: $0.clipMs + 1000, source: $0.source, gesture: $0.gesture) }, startClipMs: 1000), loop: loop).run()
    exit(0)
case "run":
    break
default:
    // allow `earshot-eval <input>` as shorthand for run
    args.insert(cmd, at: 0)
}

var config = PipelineConfig()
if let c = opt("--config") {
    do { config = try JSONDecoder().decode(PipelineConfig.self, from: Data(contentsOf: URL(fileURLWithPath: c))) }
    catch { fail("bad config: \(error)") }
}
if let m = opt("--asr-model") { config.asr.model = m; config.asr.name = "whisper.cpp " + URL(fileURLWithPath: m).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "") }
if let t = opt("--tagger") { config.tagger = t == "none" ? nil : t }
if let t = opt("--threads"), let n = Int(t) { config.asr.threads = n }
if let c = opt("--call-id") { config.callId = c }
if let s = opt("--start") { config.startTime = s }
if flag("--no-prompt") { config.asr.useInitialPrompt = false }
if let pf = opt("--prompt-file") { config.asr.prompt = (try? String(contentsOfFile: pf, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
if flag("--greedy") { config.asr.beamSize = 1; config.asr.temperatureFallback = false }
if let b = opt("--beam"), let n = Int(b) { config.asr.beamSize = n }
if flag("--pii-scrub") { config.piiScrub = true }
_ = flag("--no-pii") // old flag, now the default
let tapsPath = opt("--taps")
let outOpt = opt("--out")
let dictOpt = opt("--dict")
guard let inputPath = args.first else { fail(usage) }
let inputURL = URL(fileURLWithPath: inputPath)

let dictDir = dictOpt.map { URL(fileURLWithPath: $0) }
    ?? EMSDictionary.findSharedDirectory(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    ?? EMSDictionary.findSharedDirectory(from: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
guard let dd = dictDir else { fail("cannot find shared/formulary.json; pass --dict <dir>") }
let dict: EMSDictionary
do { dict = try EMSDictionary(directory: dd) } catch { fail("cannot load dictionary from \(dd.path): \(error)") }

var taps: [TapInput] = []
if let t = tapsPath {
    do { taps = try JSONDecoder().decode([TapInput].self, from: Data(contentsOf: URL(fileURLWithPath: t))) }
    catch { fail("bad taps file: \(error)") }
}

let ext = inputURL.pathExtension.lowercased()
var transcriber: Transcriber? = nil
var notes: [String] = []
let t0 = Date()
if ext != "json" {
    #if canImport(EarshotWhisper)
    let model = config.asr.model ?? ProcessInfo.processInfo.environment["EARSHOT_ASR_MODEL"] ?? "models/ggml-small.en.bin"
    do { transcriber = try WhisperTranscriber(modelPath: model, name: config.asr.model == nil ? nil : config.asr.name, threads: config.asr.threads,
                                              beamSize: config.asr.beamSize, temperatureFallback: config.asr.temperatureFallback) }
    catch { fail("\(error.localizedDescription). Download: https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin and pass --asr-model") }
    #else
    fail("this build has no whisper.cpp; pass a transcript .json instead")
    #endif
}
let loadSecs = Date().timeIntervalSince(t0)

var tagger: TokenTagger? = nil
if let tp = config.tagger {
    #if canImport(CoreML)
    do { tagger = try CoreMLTagger(modelPath: tp) } catch { notes.append("tagger failed to load (\(error)); running rules only") }
    #else
    notes.append("tagger \(tp) requested but Core ML is not available on this platform; running rules only")
    #endif
}
for n in notes { FileHandle.standardError.write(("note: " + n + "\n").data(using: .utf8)!) }

let input: PipelineInput
do {
    switch ext {
    case "wav": input = .pcm(try WAVReader.read(inputURL), taps: taps)
    case "json": input = .transcript(try loadTranscript(inputURL), taps: taps)
    default: input = .packets(try ReplayFile.read(inputURL), extraTaps: taps)
    }
} catch { fail("cannot read input: \(error)") }

let pipeline = EarshotPipeline(dict: dict, config: config, transcriber: transcriber, tagger: tagger)
let result: PipelineResult
do { result = try pipeline.run(input) } catch { fail("pipeline failed: \(error)") }

let out = URL(fileURLWithPath: outOpt ?? "out/" + inputURL.deletingPathExtension().lastPathComponent)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try writeJSON(result.raw, out.appendingPathComponent("transcript.raw.json"))
try writeJSON(result.clean, out.appendingPathComponent("transcript.clean.json"))
try writeJSON(result.events, out.appendingPathComponent("events.json"))
for d in result.docs { try d.text.write(to: out.appendingPathComponent(d.name), atomically: true, encoding: .utf8) }

struct Timing: Encodable {
    var seconds: [String: Double]
    var stats: [String: Int]
    var model_load_s: Double
    var asr_model: String
    var extractor: String
    var tagger: String
    var dictionary: String
    var threads: Int
    var notes: [String]
}
notes += result.notes
var secs = result.timing.mapValues { ($0 * 1000).rounded() / 1000 }
secs["total"] = ((Date().timeIntervalSince(t0)) * 1000).rounded() / 1000
try writeJSON(Timing(seconds: secs, stats: result.stats, model_load_s: (loadSecs * 1000).rounded() / 1000,
                     asr_model: result.raw.asrModel, extractor: RulesExtractor.version, tagger: tagger?.name ?? "none",
                     dictionary: dict.version, threads: config.asr.threads, notes: notes),
              out.appendingPathComponent("timing.json"))
print("wrote \(out.path): \(result.raw.segments.count) segments, \(result.events.count) events")
