import Foundation

/// Picks the speech recogniser that writes the record, from whatever this device can run.
///
/// Each backend (Apple's on-device recogniser, a fine-tuned Whisper, stock Whisper) is offered as a
/// `RecognizerOption`: it says whether it can run here and how to build it. `RecognizerPolicy.rank`
/// decides the order to try them in; the first one that is available and builds is used, and every
/// option passed over is kept with its reason so the app and eval can say why.

/// What kind of recogniser an option is. The policy ranks by this.
public enum RecognizerKind: String, Sendable, CaseIterable {
    /// Apple's on-device recogniser (Speech framework, `EarshotAppleSpeech`). No model file to ship;
    /// Apple's model, which changes with iOS updates.
    case appleOnDevice = "apple-on-device"
    /// Whisper fine-tuned on EMS speech (whisper-ems-*.bin).
    case whisperFineTuned = "whisper-fine-tuned"
    /// Stock Whisper (ggml-small.en, base.en, tiny.en).
    case whisperStock = "whisper-stock"

    /// Whisper reads its own logits, so the BiasTrie and token confidences apply. Apple's does not.
    public var isWhisper: Bool { self != .appleOnDevice }
}

public struct RecognizerOption {
    public let kind: RecognizerKind
    /// For logs and the "models" field of the outputs, e.g. "ggml-small.en" or "apple-speech".
    public let name: String
    /// Nil when it can run on this device; otherwise why not (no model file, not authorised, ...).
    public let unavailableReason: () -> String?
    /// Builds it. Only called for the option that is chosen, so heavy models load once.
    public let make: () throws -> Transcriber

    public init(kind: RecognizerKind, name: String,
                unavailableReason: @escaping () -> String?, make: @escaping () throws -> Transcriber) {
        self.kind = kind; self.name = name; self.unavailableReason = unavailableReason; self.make = make
    }
}

public struct RecognizerChoice {
    public let transcriber: Transcriber
    public let kind: RecognizerKind
    public let name: String
    /// Options tried before this one, with why each was passed over.
    public let skipped: [(name: String, reason: String)]
}

public struct RecognizerSelectionFailure: Error, LocalizedError {
    public let skipped: [(name: String, reason: String)]
    public var errorDescription: String? {
        "No speech recogniser can run on this device: " + skipped.map { "\($0.name) (\($0.reason))" }.joined(separator: "; ")
    }
}

public enum RecognizerSelector {
    /// Tries the options in the policy's order; returns the first that is available and builds.
    /// `whisper` is the app's Whisper setting (see `RecognizerPolicy.rank`).
    public static func choose(from options: [RecognizerOption], whisper: Bool = true) throws -> RecognizerChoice {
        var skipped: [(name: String, reason: String)] = []
        for o in RecognizerPolicy.rank(options, whisper: whisper) {
            if let why = o.unavailableReason() { skipped.append((o.name, why)); continue }
            do {
                return RecognizerChoice(transcriber: try o.make(), kind: o.kind, name: o.name, skipped: skipped)
            } catch {
                skipped.append((o.name, "failed to load: \(error.localizedDescription)"))
            }
        }
        throw RecognizerSelectionFailure(skipped: skipped)
    }
}

public enum RecognizerPolicy {
    /// The order to try recognisers in, given the Whisper setting. An option left out is never tried.
    /// Options of the same kind keep the order they were given in (so small.en before base.en before tiny.en).
    ///
    /// - `whisper: true`: only Whisper models, the fine-tuned EMS one before stock.
    /// - `whisper: false`: only Apple's on-device recogniser, so a call can be compared with and
    ///   without Whisper.
    public static func rank(_ options: [RecognizerOption], whisper: Bool) -> [RecognizerOption] {
        // No fallback across the setting: if the chosen side cannot run, nothing writes the record,
        // so a call is never recorded by the recogniser the test meant to leave out.
        guard whisper else { return options.filter { $0.kind == .appleOnDevice } }
        return options.filter { $0.kind == .whisperFineTuned } + options.filter { $0.kind == .whisperStock }
    }
}
