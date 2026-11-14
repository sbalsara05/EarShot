import Foundation

/// The connection to the clip, whatever carries it. The Bluetooth implementation is not in this
/// file and is being written separately; it only has to pass packets through untouched
/// (firmware/BLUETOOTH.md):
///
///   events channel  (notify)  -> onText     one JSON message per packet, as UTF-8 text
///   audio channel   (notify)  -> onAudio    one audio frame per packet, the raw bytes
///                                           (8-byte header + one Opus packet)
///   commands channel (write)  <- send(_:)   one JSON command per write, e.g. {"cmd":"start"}
///   connection changes        -> onConnected
///
/// Everything else (parsing, Opus decoding, consent, markers, lost frames, reconnects, timing) is
/// done by `CallEngine`, so the link stays a thin pipe. Callbacks may come on any queue.
/// Set `Model.link` (or `CallEngine.link`) to the implementation once it exists.
protocol ClipLink: AnyObject {
    var onText: ((String) -> Void)? { get set }
    var onAudio: (([UInt8]) -> Void)? { get set }
    var onConnected: ((Bool) -> Void)? { get set }
    var isConnected: Bool { get }
    /// The clip's name, e.g. "Earshot-A3F2", once known.
    var name: String? { get }
    func send(_ json: String)
}
