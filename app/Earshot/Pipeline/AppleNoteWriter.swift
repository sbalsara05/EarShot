#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Apple's on-device language model, used only when the device has Apple Intelligence turned on.
/// One NoteWriter among possible others; the app works without it.
@available(iOS 26.0, *)
struct AppleNoteWriter: NoteWriter {
    let name = "Apple on-device model"

    var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is off"
        case .unavailable(.modelNotReady): return "the on-device model is still downloading"
        case .unavailable: return "this device has no on-device model"
        }
    }

    @Generable
    struct Notes {
        @Guide(description: "Why the crew was called and what they found on arrival, in one or two sentences. Empty if not said.")
        var dispatchAndScene: String
        @Guide(description: "A short factual account of the call in plain sentences. Only facts in the transcript.")
        var narrative: String
        @Guide(description: "Vital signs or allergies that were said but are missing from the record. Each must quote the transcript.")
        var missing: [Missing]
    }

    @Generable
    struct Missing {
        @Guide(description: "One of: bp_systolic, bp_diastolic, heart_rate, spo2, resp_rate, gcs, glucose, etco2, temperature, allergy")
        var field: String
        @Guide(description: "The value, as digits for numbers")
        var value: String
        @Guide(description: "The exact words from the transcript that say it")
        var quote: String
    }

    func write(transcript: String, record: String) async throws -> WrittenNotes {
        // ponytail: the on-device model reads about 4,000 tokens. Very long calls are cut to their last part here.
        let text = String(transcript.suffix(9_000))
        let session = LanguageModelSession(instructions: """
            You help an ambulance crew with paperwork. You get the transcript of a call (each line starts with its \
            clock time) and the facts already in the record. Use only facts that were said. Never guess, and never \
            fill in typical values. Write spoken numbers as digits. Keep everything short.
            """)
        let prompt = "Transcript:\n\(text)\n\nAlready in the record:\n\(record)"
        let n = try await session.respond(to: prompt, generating: Notes.self).content
        return WrittenNotes(narrative: n.narrative, dispatchAndScene: n.dispatchAndScene,
                            suggestions: n.missing.map { .init(field: $0.field, value: $0.value, quote: $0.quote) })
    }
}
#endif
