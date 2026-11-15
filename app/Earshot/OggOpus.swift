import Foundation

/// The Ogg Opus file format (.opus, RFC 7845): Opus packets as they come off the clip, wrapped so that any player
/// can open the file. Nothing is re-encoded, so a call costs what the clip sent: about 4 KB a second, 15 MB an hour.
///
///   page 1: "OpusHead"    page 2: "OpusTags"    then pages of 50 packets, one second each
///
/// A page is written as soon as it is full, so a file cut off mid-call is still good up to its last second.
enum OggOpus {
    /// How long a packet lasts, in samples at 48 kHz (Ogg's clock for Opus). 0 for an empty packet.
    static func length(of packet: Data) -> Int {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let frame = config < 12 ? [480, 960, 1920, 2880][config % 4] : config < 16 ? [480, 960][config % 2] : [120, 240, 480, 960][config % 4]
        let frames = toc & 3 == 0 ? 1 : toc & 3 < 3 ? 2 : Int(packet.dropFirst().first ?? 0) & 0x3F
        return frame * frames
    }

    /// A packet that stands for one that never arrived: the same kind of frame, with nothing in it. A decoder
    /// fills its time with a guess, so everything after it keeps its place on the clock. One byte.
    static func gap(like packet: Data) -> Data { Data([(packet.first ?? 0) & 0xFC]) }

    /// The audio packets of a file, in order, without the two heading packets.
    static func packets(in file: Data) -> [Data] {
        var out: [Data] = [], open = Data(), at = file.startIndex
        while at + 27 <= file.endIndex, file[at..<at + 4].elementsEqual("OggS".utf8) {
            let count = Int(file[at + 26]), table = at + 27
            guard table + count <= file.endIndex else { break }
            var body = table + count
            for size in file[table..<table + count].map(Int.init) {
                guard body + size <= file.endIndex else { return out }
                open += file[body..<body + size]
                body += size
                guard size < 255 else { continue }   // 255 means the packet carries on in the next piece
                if !open.starts(with: "OpusHead".utf8), !open.starts(with: "OpusTags".utf8) { out.append(open) }
                open = Data()
            }
            at = body
        }
        return out
    }

    /// Writes a file a packet at a time.
    final class Writer {
        private let handle: FileHandle
        private let serial = UInt32.random(in: 0...UInt32.max)
        private var page: UInt32 = 0
        private var clock: UInt64 = 0    // samples written so far, at 48 kHz
        private var waiting: [Data] = [] // packets for the page being filled
        private var pieces = 0           // how many length bytes they need; a page holds 255

        /// - rate: the sample rate the audio was captured at, noted in the file for players.
        init(_ handle: FileHandle, rate: Int = 16000) throws {
            self.handle = handle
            // No samples are skipped at the start, so a time in the file is the same time in the transcript.
            var head = Data("OpusHead".utf8) + [1, 1, 0, 0]
            head += Self.bytes(UInt32(rate)) + [0, 0, 0]
            try write([head], flags: 2)
            try write([Data("OpusTags".utf8) + Self.bytes(UInt32(7)) + Data("Earshot".utf8) + Self.bytes(UInt32(0))], flags: 0)
        }

        func add(_ packet: Data) throws {
            let needs = packet.count / 255 + 1
            if pieces + needs > 255 { try flush() }
            waiting.append(packet)
            pieces += needs
            clock += UInt64(OggOpus.length(of: packet))
            if waiting.count >= 50 { try flush() }
        }

        /// Writes what is waiting and marks the end of the file.
        func close() throws {
            try write(waiting, flags: 4)
            waiting = []
            pieces = 0
            try handle.close()
        }

        private func flush() throws {
            guard !waiting.isEmpty else { return }
            try write(waiting, flags: 0)
            waiting = []
            pieces = 0
        }

        /// One page. `flags`: 2 on the first page of the file, 4 on the last.
        private func write(_ packets: [Data], flags: UInt8) throws {
            var out = Data("OggS".utf8) + [0, flags]
            out += Self.bytes(page < 2 ? UInt64(0) : clock) + Self.bytes(serial) + Self.bytes(page) + [0, 0, 0, 0]
            let table = packets.flatMap { [UInt8](repeating: 255, count: $0.count / 255) + [UInt8($0.count % 255)] }
            out.append(UInt8(table.count))
            out += table
            for packet in packets { out += packet }
            out.replaceSubrange(22..<26, with: Self.bytes(Self.checksum(out)))
            try handle.write(contentsOf: out)
            page += 1
        }

        private static func bytes<T: FixedWidthInteger>(_ value: T) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }

        /// Ogg's checksum of a page: CRC-32 with polynomial 04C11DB7, most significant bit first.
        static func checksum(_ data: Data) -> UInt32 {
            data.reduce(0) { ($0 << 8) ^ table[Int(($0 >> 24) ^ UInt32($1))] }
        }
        private static let table: [UInt32] = (0..<256).map { i in
            (0..<8).reduce(UInt32(i) << 24) { r, _ in r & 0x8000_0000 != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        }
    }
}
