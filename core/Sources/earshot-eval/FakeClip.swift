import Foundation
import EarshotCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Reference clip over TCP, following docs/FIRMWARE_CONTRACT.md: the same
/// length-prefixed framing the real clip uses on its Wi-Fi fallback. It plays
/// a generated, contract-conformant stream in real time, resends each tap
/// every 500 ms until the iPad acks it, honours a force-OFF state write and
/// logs clock sync. Point the app's Wi-Fi transport (or `nc`) at it.
final class FakeClip {
    let port: UInt16
    let packets: [Packet]
    let loop: Bool
    init(port: UInt16, packets: [Packet], loop: Bool) { self.port = port; self.packets = packets; self.loop = loop }

    func log(_ s: String) { FileHandle.standardError.write(("[fake-clip] " + s + "\n").data(using: .utf8)!) }

    func run() throws {
        let srv = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard srv >= 0 else { throw NSError(domain: "fake-clip", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket failed"]) }
        var yes: Int32 = 1
        setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let b = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(srv, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard b == 0, listen(srv, 1) == 0 else { throw NSError(domain: "fake-clip", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot listen on \(port)"]) }
        log("listening on 0.0.0.0:\(port) (\(packets.count) packets)")
        repeat {
            let c = accept(srv, nil, nil)
            guard c >= 0 else { continue }
            log("client connected")
            serve(c)
            close(c)
            log("client gone")
        } while loop
        close(srv)
    }

    private func send(_ fd: Int32, _ p: Packet) -> Bool {
        let bytes = Wire.frame(p)
        return bytes.withUnsafeBufferPointer { buf in
            var off = 0
            while off < buf.count {
                #if canImport(Glibc)
                let n = Glibc.send(fd, buf.baseAddress! + off, buf.count - off, Int32(MSG_NOSIGNAL))
                #else
                let n = Darwin.send(fd, buf.baseAddress! + off, buf.count - off, 0)
                #endif
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    private func serve(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var deframer = StreamDeframer()
        var pendingTaps: [UInt16: (Packet, Date)] = [:]
        var forcedOff = false
        let t0 = Date()
        let base = packets.first?.header.clipMs ?? 0
        var readBuf = [UInt8](repeating: 0, count: 512)
        func pollIncoming() {
            while true {
                let n = recv(fd, &readBuf, readBuf.count, 0)
                if n <= 0 { return }
                for p in deframer.push(Array(readBuf[0..<n])) {
                    switch p {
                    case .ack(_, let s): if pendingTaps.removeValue(forKey: s) != nil { log("tap \(s) acked") }
                    case .clock(_, let e): log("clock sync: iPad epoch \(e)")
                    case .state(_, let st) where st.state == .off: log("iPad forced OFF"); forcedOff = true
                    default: break
                    }
                }
            }
        }
        for p in packets {
            if forcedOff { break }
            let due = Double(p.header.clipMs &- base) / 1000
            while Date().timeIntervalSince(t0) < due {
                pollIncoming()
                for (s, v) in pendingTaps where Date().timeIntervalSince(v.1) >= 0.5 {   // resend until acked
                    if !send(fd, v.0) { return }
                    pendingTaps[s] = (v.0, Date())
                }
                usleep(2000)
            }
            if !send(fd, p) { return }
            if case .tap(let h, _) = p { pendingTaps[h.seq] = (p, Date()) }
        }
        if forcedOff {
            _ = send(fd, .state(PacketHeader(type: .state, seq: 999, clipMs: 0), StatePayload(state: .off, flags: 1, version: Wire.protocolVersion)))
        }
        // give unacked taps a last chance
        let end = Date()
        while !pendingTaps.isEmpty && Date().timeIntervalSince(end) < 2 {
            pollIncoming()
            for (s, v) in pendingTaps where Date().timeIntervalSince(v.1) >= 0.5 { _ = send(fd, v.0); pendingTaps[s] = (v.0, Date()) }
            usleep(5000)
        }
        if !pendingTaps.isEmpty { log("\(pendingTaps.count) tap(s) never acked") }
    }
}
