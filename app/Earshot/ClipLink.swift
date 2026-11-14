import AVFoundation
import CoreBluetooth
import Opus

/// One message from the clip's events channel. A message only carries the fields that belong to its type.
struct ClipEvent: Decodable {
    var type: String        // hello | state | consent | marker
    var device: String?     // hello: the clip's name, like "Earshot-A3F2"
    var fw: String?         // hello: firmware version
    var listening: Bool?    // state
    var event: String?      // consent: granted | stopped
    var source: String?     // consent, marker: button | tablet
    var audio: Audio?       // hello
    struct Audio: Decodable { var codec: String }
}

/// The Bluetooth link to the clip. The clip advertises; this side scans, connects, subscribes, and then
/// receives one packet per message. IDs and packet layouts are the firmware's: see firmware/BLUETOOTH.md.
final class ClipLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum State: Equatable {
        case off(String)     // Bluetooth cannot be used; the text says why
        case idle            // not looking for a clip
        case searching       // scanning; clips in range are reported through onFound until one is chosen
        case connecting      // a clip is chosen or remembered; waiting for it to answer
        case ready(String)   // connected, subscribed, and the clip has said hello; the text is its name
    }

    /// A clip heard while searching.
    struct Found: Identifiable, Equatable {
        let id: UUID
        var name: String
        var bars: Int   // signal strength, 1 (far) to 4 (close)
    }

    var onState: (State) -> Void = { _ in }
    var onFound: ([Found]) -> Void = { _ in }            // every clip in range, in the order first heard
    var onEvent: (ClipEvent) -> Void = { _ in }
    var onAudio: (AVAudioPCMBuffer) -> Void = { _ in }   // 16 kHz mono, in the order it was captured

    private(set) var state = State.idle {
        didSet {
            guard state != oldValue else { return }
            log("\(state)")
            onState(state)
        }
    }
    private var found: [Found] = [] {
        didSet { if found != oldValue { onFound(found) } }
    }
    private var nearby: [UUID: CBPeripheral] = [:]   // the peripherals behind `found`; iOS drops any that nothing holds

    private static let service = CBUUID(string: "E5A70001-7C1B-4F0E-9D52-3A6B8C4D2E10")
    private static let audio = CBUUID(string: "E5A70002-7C1B-4F0E-9D52-3A6B8C4D2E10")
    private static let events = CBUUID(string: "E5A70003-7C1B-4F0E-9D52-3A6B8C4D2E10")
    private static let commands = CBUUID(string: "E5A70004-7C1B-4F0E-9D52-3A6B8C4D2E10")
    private static let format = AVAudioFormat(opusPCMFormat: .float32, sampleRate: 16000, channels: 1)!
    private static let frame = 320       // samples in one 20 ms audio packet
    private static let header = 8        // seq (4 bytes) + clip clock (4 bytes), before the Opus data
    private static let saved = "clipIdentifier"

    private var central: CBCentralManager?
    private var clip: CBPeripheral?      // must be held here: iOS silently drops a peripheral nothing refers to
    private var commands: CBCharacteristic?
    private var wanted = false
    private let decoder = try? Opus.Decoder(format: ClipLink.format)
    private var nextSeq: UInt32?
    private var packets = 0, lost = 0, counted = Date()

    /// At launch: goes back to the clip used last time. Does nothing (and asks for no permission) if there never was one.
    func resume() {
        if UserDefaults.standard.string(forKey: Self.saved) != nil { connect() }
    }

    func connect() {
        switch state {
        case .idle, .off: break
        default: return   // already looking, connecting or connected
        }
        wanted = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)   // reports its state, which starts the search
        } else {
            begin()
        }
    }

    /// Connects to one of the clips reported through onFound.
    func connect(to id: UUID) {
        guard state == .searching, let central, let peripheral = nearby[id] else { return }
        central.stopScan()
        clip = peripheral
        nearby = [:]
        found = []
        peripheral.delegate = self
        state = .connecting
        central.connect(peripheral)   // does not time out: it completes whenever the clip is in range and powered
    }

    /// Lets go of the clip and stops looking for it.
    func forget() {
        wanted = false
        UserDefaults.standard.removeObject(forKey: Self.saved)
        central?.stopScan()
        if let clip { central?.cancelPeripheralConnection(clip) }
        clip = nil
        commands = nil
        nearby = [:]
        found = []
        if case .off = state { return }
        state = .idle
    }

    /// Sends start, stop or marker. Ignored unless the clip is ready.
    func send(_ command: String) {
        guard case .ready = state, let clip, let commands else { return }
        log("sending \(command)")
        clip.writeValue(Data(#"{"cmd":"\#(command)"}"#.utf8), for: commands, type: .withResponse)
    }

    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("clip link: \(message())")
        #endif
    }

    private func begin() {
        guard wanted, let central, central.state == .poweredOn else { return }
        if clip == nil, let id = UserDefaults.standard.string(forKey: Self.saved).flatMap(UUID.init(uuidString:)) {
            clip = central.retrievePeripherals(withIdentifiers: [id]).first
        }
        if let clip {
            state = .connecting
            clip.delegate = self
            central.connect(clip)   // does not time out: it completes whenever the clip is in range and powered
        } else {
            nearby = [:]
            found = []
            state = .searching
            // Repeats are allowed so a clip's signal strength keeps up as it moves.
            central.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    // MARK: Finding and keeping the clip

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            begin()
        case .poweredOff:
            clip = nil   // a peripheral from before the radio went off is no longer valid
            commands = nil
            state = .off("Bluetooth is off. Turn it on to use the clip.")
        case .unauthorized:
            state = .off("Earshot is not allowed to use Bluetooth. Allow it in Settings.")
        case .unsupported:
            state = .off("This \(deviceName) cannot use Bluetooth, so calls record on its own mic.")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // The clip is only listed here. It is connected when the medic picks it, in connect(to:).
        let id = peripheral.identifier
        let heard = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let strength = RSSI.intValue   // dBm: about -50 beside the device, -90 at the edge of range
        let bars = strength > -55 ? 4 : strength > -68 ? 3 : strength > -80 ? 2 : 1
        if nearby[id] == nil { log("found \(heard ?? "a clip with no name yet") at \(strength) dBm") }
        nearby[id] = peripheral
        if let i = found.firstIndex(where: { $0.id == id }) {
            found[i].bars = bars
            if let heard { found[i].name = heard }   // the name arrives in a second packet, after the service ID
        } else {
            found.append(Found(id: id, name: heard ?? "Earshot clip", bars: bars))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("connected; up to \(peripheral.maximumWriteValueLength(for: .withoutResponse)) bytes per packet (the clip needs 160)")
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.saved)
        // Nothing carries over from the last connection, so the channels are looked up and subscribed every time.
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if wanted { central.connect(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        commands = nil
        log("disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        guard wanted else { return }
        state = .connecting
        central.connect(peripheral)   // the clip advertises again at once, so this returns by itself
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        log("services: \(peripheral.services?.count ?? 0)\(error.map { ", error: \($0.localizedDescription)" } ?? "")")
        for service in peripheral.services ?? [] where service.uuid == Self.service {
            peripheral.discoverCharacteristics([Self.audio, Self.events, Self.commands], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let channels = service.characteristics ?? []
        log("channels: \(channels.count) of 3\(error.map { ", error: \($0.localizedDescription)" } ?? "")")
        commands = channels.first { $0.uuid == Self.commands }
        // Audio first: the clip starts talking the moment events is subscribed.
        for id in [Self.audio, Self.events] {
            if let channel = channels.first(where: { $0.uuid == id }) { peripheral.setNotifyValue(true, for: channel) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let name = characteristic.uuid == Self.audio ? "audio" : "events"
        log("subscribed to \(name): \(characteristic.isNotifying)\(error.map { ", error: \($0.localizedDescription)" } ?? "")")
    }

    // MARK: Receiving

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        if characteristic.uuid == Self.audio {
            hear(data)
        } else if characteristic.uuid == Self.events, let event = try? JSONDecoder().decode(ClipEvent.self, from: data) {
            log("event: \(String(decoding: data, as: UTF8.self))")
            if event.type == "hello" { state = .ready(event.device ?? peripheral.name ?? "Earshot clip") }
            if event.type == "consent", event.event == "granted" { nextSeq = 0 }   // the frame counter restarts with every capture
            onEvent(event)
        }
    }

    /// One audio packet: frame counter, the clip's clock, then 20 ms of Opus.
    private func hear(_ data: Data) {
        guard data.count > Self.header, let decoder else { return }
        let seq = Self.frameNumber(of: data)
        if let next = nextSeq, seq > next {
            // Frames were lost on the way. Keep the timeline honest with silence, up to two seconds of it.
            let missing = Int(seq - next)
            lost += missing
            if let quiet = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(min(missing, 100) * Self.frame)) {
                quiet.frameLength = quiet.frameCapacity
                quiet.floatChannelData?[0].update(repeating: 0, count: Int(quiet.frameLength))
                onAudio(quiet)
            }
        }
        nextSeq = seq &+ 1
        packets += 1
        if let buffer = try? decoder.decode(data.dropFirst(Self.header)) { onAudio(buffer) }
        #if DEBUG
        if Date().timeIntervalSince(counted) >= 1 {
            print("clip audio: \(packets) packets in the last second, \(lost) frames lost since connecting")
            packets = 0
            counted = Date()
        }
        #endif
    }

    /// The frame counter at the start of an audio packet: four bytes, least significant first.
    static func frameNumber(of packet: Data) -> UInt32 {
        packet.prefix(4).reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }
}
