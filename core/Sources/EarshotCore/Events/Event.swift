import Foundation

public enum EventType: String, Codable, Sendable, CaseIterable {
    case vitals, medication, procedure, status, dispatch, transport, tap, consent, arrival, handoff
    case audioGap = "audio_gap"
}

/// Where an event came from. `tap+heard`: a tap labeled by nearby speech;
/// `tap`: a tap with no label; `heard`: speech only; `tablet`: typed/tapped
/// on the iPad by the medic or nurse (labeled as theirs).
public enum EventSource: String, Codable, Sendable {
    case tapHeard = "tap+heard", tap, heard, tablet
}

public struct ModelInfo: Codable, Equatable, Sendable {
    public var asr: String
    public var extract: String
    public init(asr: String, extract: String) { self.asr = asr; self.extract = extract }
}

/// Receipt for a single field: which raw span and exact quote it came from.
public struct FieldReceipt: Codable, Equatable, Sendable {
    public var rawSpan: String
    public var quote: String
    public var rawRange: [Int]?
    public var inferred: String?   // set when a value was not literally heard (e.g. unit from protocol); renderers flag it
    enum CodingKeys: String, CodingKey { case rawSpan = "raw_span", quote, rawRange = "raw_range", inferred }
}

/// The single source of truth. All outputs are rendered from these.
public struct EarshotEvent: Codable, Equatable, Sendable {
    public var id: String
    public var callId: String
    public var time: String             // ISO 8601 with offset
    public var tMs: Int64               // ms since call start (for sorting/merging)
    public var type: EventType
    public var fields: [String: String]
    public var source: EventSource
    public var quote: String?
    public var rawSpan: String?
    public var confidence: Double
    public var models: ModelInfo
    /// Per-field receipts (field name -> receipt). Optional extension.
    public var receipts: [String: FieldReceipt]?
    /// "confirm" = heard, please confirm; "unlabeled" = tap with no label.
    public var flags: [String]?
    public var tapSource: String?       // button | tablet
    public var tapClipMs: Int64?
    public var enteredBy: String?       // "medic" / "nurse" when typed on the tablet

    public init(id: String, callId: String, time: String, tMs: Int64, type: EventType, fields: [String: String],
                source: EventSource, quote: String?, rawSpan: String?, confidence: Double, models: ModelInfo,
                receipts: [String: FieldReceipt]? = nil, flags: [String]? = nil, tapSource: String? = nil,
                tapClipMs: Int64? = nil, enteredBy: String? = nil) {
        self.id = id; self.callId = callId; self.time = time; self.tMs = tMs; self.type = type; self.fields = fields
        self.source = source; self.quote = quote; self.rawSpan = rawSpan; self.confidence = confidence; self.models = models
        self.receipts = receipts; self.flags = flags; self.tapSource = tapSource; self.tapClipMs = tapClipMs; self.enteredBy = enteredBy
    }

    enum CodingKeys: String, CodingKey {
        case id, callId = "call_id", time, tMs = "t_ms", type, fields, source, quote, rawSpan = "raw_span", confidence, models
        case receipts, flags, tapSource = "tap_source", tapClipMs = "tap_clip_ms", enteredBy = "entered_by"
    }

    public var needsConfirm: Bool { flags?.contains("confirm") ?? false }
    public var isUnlabeledTap: Bool { type == .tap && (flags?.contains("unlabeled") ?? false) }
}

/// Call clock: maps call-relative ms to wall-clock ISO strings.
public struct CallClock: Sendable {
    public var startEpochMs: Int64
    public var tzOffsetSeconds: Int
    public init(startEpochMs: Int64, tzOffsetSeconds: Int) { self.startEpochMs = startEpochMs; self.tzOffsetSeconds = tzOffsetSeconds }

    /// Parse "2026-11-15T14:00:00-05:00".
    public init?(iso: String) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: iso) else { return nil }
        startEpochMs = Int64((d.timeIntervalSince1970 * 1000).rounded())
        // extract offset from the string
        var off = 0
        if iso.hasSuffix("Z") { off = 0 } else if let r = iso.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) {
            let s = iso[r]; let sign = s.first == "-" ? -1 : 1
            let parts = s.dropFirst().split(separator: ":").compactMap { Int($0) }
            off = sign * (parts[0] * 3600 + parts[1] * 60)
        }
        tzOffsetSeconds = off
    }

    public func iso(_ tMs: Int64) -> String { CallClock.format(epochMs: startEpochMs + tMs, offset: tzOffsetSeconds) }
    public func epochMs(_ tMs: Int64) -> Int64 { startEpochMs + tMs }

    public static func format(epochMs: Int64, offset: Int) -> String {
        let secs = Int(floor(Double(epochMs) / 1000)) + offset
        let days = Int(floor(Double(secs) / 86400))
        let rem = secs - days * 86400
        let (y, m, d) = civil(fromDays: days)
        let sign = offset < 0 ? "-" : "+"
        let ao = abs(offset)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d", y, m, d, rem / 3600, (rem % 3600) / 60, rem % 60,
                      sign, ao / 3600, (ao % 3600) / 60)
    }
    /// "14:13:05" local clock time.
    public func clock(_ tMs: Int64) -> String {
        let s = iso(tMs); let t = s.split(separator: "T")[1]
        return String(t.prefix(8))
    }
    static func civil(fromDays z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }
}
