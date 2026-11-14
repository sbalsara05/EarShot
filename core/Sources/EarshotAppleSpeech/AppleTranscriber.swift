import Foundation
import EarshotCore
#if canImport(Speech)
import AVFoundation
import Speech

/// Apple's on-device recogniser as a record `Transcriber`: the same chunk-in, pieces-out slot as
/// whisper.cpp, so cleanup, rules and every output work unchanged.
///
/// Differences from Whisper that matter downstream:
/// - No BiasTrie: vocabulary goes in as `contextualStrings` instead.
/// - Word confidences are Apple's (`SFTranscriptionSegment.confidence`), not token probabilities,
///   so `minWordConfidence` tuned on Whisper may not suit them.
/// - The model is Apple's and changes with iOS updates; `modelName` records the OS version.
/// - Patient audio: on-device only. If the device cannot, `unavailableReason` says so and the
///   selector moves on; it never falls back to Apple's servers.
///
/// `transcribe` blocks until the chunk is final, so call it off the main thread (LiveSession's ASR
/// queue does). Results arrive on a private queue, so a caller on the main thread cannot deadlock it.
public final class AppleTranscriber: Transcriber {
    public let modelName: String
    /// Words to listen for (drug names, EMS terms).
    public var vocabulary: [String] = []
    /// Longest wait for one chunk's final result.
    public var timeout: TimeInterval = 60

    private let recognizer: SFSpeechRecognizer
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    /// Nil when this device can recognise speech on the device and the app may; otherwise why not.
    public static func unavailableReason(locale: Locale = Locale(identifier: "en-US")) -> String? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return "speech recognition is not allowed" }
        guard let r = SFSpeechRecognizer(locale: locale) else { return "no recogniser for \(locale.identifier)" }
        guard r.supportsOnDeviceRecognition else { return "this device cannot recognise speech on the device" }
        guard r.isAvailable else { return "speech recognition is not available right now" }
        return nil
    }

    public init(locale: Locale = Locale(identifier: "en-US")) throws {
        if let why = Self.unavailableReason(locale: locale) { throw AppleSpeechError(why) }
        recognizer = SFSpeechRecognizer(locale: locale)!
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        recognizer.queue = q
        modelName = "apple-speech on-device \(locale.identifier) (OS \(ProcessInfo.processInfo.operatingSystemVersionString))"
    }

    public func transcribe(_ pcm: [Float]) throws -> [ASRPiece] {
        guard !pcm.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count)) else { return [] }
        buffer.frameLength = AVAudioFrameCount(pcm.count)
        pcm.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: pcm.count) }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true      // never send patient audio to Apple's servers
        request.shouldReportPartialResults = false
        request.addsPunctuation = true                  // cleanup and joinUnfinished read sentence ends
        request.contextualStrings = vocabulary
        request.append(buffer)
        request.endAudio()

        let done = DispatchSemaphore(value: 0)
        var final: SFSpeechRecognitionResult?
        var failure: Error?
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal { final = result; done.signal() }
            else if let error { failure = error; done.signal() }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw AppleSpeechError("no result within \(Int(timeout)) s")
        }
        if let failure {
            // Silence or noise only: Apple reports "no speech detected" as an error; that is an empty chunk.
            if (failure as NSError).code == 1110 { return [] }
            throw failure
        }
        guard let t = final?.bestTranscription, !t.formattedString.isEmpty else { return [] }
        return [Self.piece(t, chunkMs: Int64(pcm.count) / 16)]
    }

    /// One piece per chunk; Apple's word segments become the token timings and confidences.
    static func piece(_ t: SFTranscription, chunkMs: Int64) -> ASRPiece {
        let text = t.formattedString
        let tokens = t.segments.map { s in
            ASRToken(charOffset: s.substringRange.location,
                     startMs: Int64(s.timestamp * 1000),
                     endMs: Int64((s.timestamp + s.duration) * 1000),
                     p: s.confidence > 0 ? Double(s.confidence) : nil)   // 0 means "not given"
        }
        let start = tokens.first?.startMs ?? 0
        let end = max(tokens.last?.endMs ?? chunkMs, start)
        return ASRPiece(startMs: start, endMs: end, text: text, avgLogprob: nil, tokens: tokens)
    }
}

public struct AppleSpeechError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}
#endif
