import Foundation

/// Optional writing help from a language model: the narrative and fields the rules may have missed.
/// Nothing depends on it. The chart, vitals, treatments, allergies and handoff lines all come from
/// the pipeline's rules and work on any device. When no writer is available, those parts are left
/// for the medic and drafting carries on.
///
/// Any model can sit behind this: Apple's on-device model (AppleNoteWriter), a different on-device
/// model, or none. Whatever it returns is checked by `Grounding` in the pipeline before it is shown:
/// suggestions must quote the transcript, and narrative sentences that mention a number or drug not
/// in the record are dropped.
protocol NoteWriter {
    var name: String { get }
    /// Why it cannot run on this device right now, or nil if it can. Not an error: drafting goes on without it.
    var unavailableReason: String? { get }
    /// - transcript: the record (Whisper), one line per segment with its clock time
    /// - record: what the rules already found, one fact per line
    func write(transcript: String, record: String) async throws -> WrittenNotes
}

struct WrittenNotes {
    var narrative = ""
    var dispatchAndScene = ""
    var suggestions: [Suggested] = []

    struct Suggested {
        var field: String   // one of Grounding.suggestableFields: a vital sign key, or "allergy"
        var value: String
        var quote: String   // the medic's words, copied from the transcript
    }
}

/// Picks the first writer that can run here, or none.
enum NoteWriters {
    static func available() -> NoteWriter? {
        var all: [NoteWriter] = []
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { all.append(AppleNoteWriter()) }
        #endif
        return all.first { $0.unavailableReason == nil }
    }
}
