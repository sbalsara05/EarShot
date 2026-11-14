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
///
/// The link only reports `ready` once every step has been confirmed by the clip. Anything short of that
/// is `connecting`, or `trouble` with the reason, so the app never shows a connection that cannot carry a call.
final class ClipLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum State: Equatable {
        case off(String)       // Bluetooth cannot be used; the text says why
        case idle              // not looking for a clip
        case searching         // scanning; clips in range are reported through onFound until one is chosen
        case connecting        // a clip is chosen or remembered; not usable yet
        case trouble(String)   // the radio link is up but the clip cannot be used; the text says why
        case ready(String)     // channels found, both subscriptions confirmed, and the clip has said hello; the text is its name
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
    var onProblem: (String) -> Void = { _ in }           // something failed while ready: a command, or the audio
    var onSignal: (Signal?) -> Void = { _ in }           // the connected clip's signal, every two seconds; nil when not connected

    /// How strongly the connected clip is heard.
    struct Signal: Equatable {
        var dBm: Int    // about -50 beside the device, -90 at the edge of range
        var bars: Int   // 1 (weak) to 4 (strong)
    }

    private(set) var state = State.idle {
        didSet {
            guard state != oldValue else { return }
            log("\(state)")
            onState(state)
            // Bluetooth does not report signal strength by itself: it has to be asked for. Ask while the clip is ready.
            signalTimer?.invalidate()
            signalTimer = nil
            smoothed = nil
            if case .ready = state {
                clip?.readRSSI()
                signalTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.clip?.readRSSI() }
            } else {
                onSignal(nil)
            }
        }
    }
    private var signalTimer: Timer?
    private var smoothed: Double?   // single readings jump by several dBm, so the shown value is an average that leans on recent ones

    private static func bars(for dBm: Int) -> Int {
        dBm > -55 ? 4 : dBm > -68 ? 3 : dBm > -80 ? 2 : 1
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
    private static let needed = 160      // bytes per packet the clip insists on before it sends anything
    private static let patience = 8.0    // seconds a connected clip gets to finish setting up
    private static let saved = "clipIdentifier"

    private var central: CBCentralManager?
    private var clip: CBPeripheral?      // must be held here: iOS silently drops a peripheral nothing refers to
    private var commands: CBCharacteristic?
    private var wanted = false
    private let decoder = try? Opus.Decoder(format: ClipLink.format)

    // What the clip has confirmed on this connection. All four are needed before the link is ready.
    private var audioOn = false, eventsOn = false
    private var hello: String?           // the clip's name, once it has said hello
    private var attempt = 0              // bumps on every connect and disconnect, so an old timeout cannot fire late

    private var sent: [String] = []      // commands written and not yet acknowledged, oldest first
    private var nextSeq: UInt32?
    private var packets = 0, lost = 0, undecoded = 0, counted = Date()

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
        attempt += 1
        UserDefaults.standard.removeObject(forKey: Self.saved)
        central?.stopScan()
        if let clip { central?.cancelPeripheralConnection(clip) }
        clip = nil
        reset()
        nearby = [:]
        found = []
        if case .off = state { return }
        state = .idle
    }

    /// Sends start, stop, marker or find. Returns false, and sends nothing, unless the clip is ready.
    /// A true result means the command was handed to Bluetooth; `onProblem` reports it if the clip never takes it.
    @discardableResult func send(_ command: String) -> Bool {
        guard case .ready = state, let clip, let commands, clip.state == .connected else {
            log("not sent, the clip is not ready: \(command)")
            return false
        }
        log("sending \(command)")
        sent.append(command)
        clip.writeValue(Data(#"{"cmd":"\#(command)"}"#.utf8), for: commands, type: .withResponse)
        return true
    }

    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("clip link: \(message())")
        #endif
    }

    /// Forgets everything the last connection confirmed.
    private func reset() {
        commands = nil
        audioOn = false
        eventsOn = false
        hello = nil
        sent = []
        nextSeq = nil
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

    /// The link is ready only when all of it is confirmed: the commands channel, both subscriptions, and hello.
    private func settle() {
        guard commands != nil, audioOn, eventsOn, let hello else { return }
        state = .ready(hello)
    }

    /// Stops short of ready, and says why. The radio link stays up so the reason can be read from the clip's log too.
    private func fail(_ why: String) {
        attempt += 1   // the setup timeout has nothing left to add
        state = .trouble(why)
    }

    // MARK: Finding and keeping the clip

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            begin()
        case .poweredOff:
            attempt += 1
            clip = nil   // a peripheral from before the radio went off is no longer valid
            reset()
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
        let bars = Self.bars(for: strength)
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
        log("radio link up; setting up channels")
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.saved)
        reset()
        attempt += 1
        let this = attempt
        state = .connecting   // not ready: nothing has been confirmed on this connection yet
        // Nothing carries over from the last connection, so the channels are looked up and subscribed every time.
        peripheral.discoverServices([Self.service])
        // A clip that connects but never finishes setting up must not sit on "connecting" for ever.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.patience) { [weak self] in
            guard let self, self.attempt == this, self.state == .connecting else { return }
            let room = peripheral.maximumWriteValueLength(for: .withoutResponse)
            let missing = [self.commands == nil ? "the commands channel" : nil, self.audioOn ? nil : "the audio subscription",
                           self.eventsOn ? nil : "the events subscription", self.hello == nil ? "its hello" : nil].compactMap { $0 }
            self.fail(room < Self.needed
                ? "The clip connected but cannot send: this \(deviceName) allows \(room) bytes per packet and the clip needs \(Self.needed)."
                : "The clip connected but did not finish setting up. Still waiting for \(missing.joined(separator: ", ")).")
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("could not connect\(error.map { ": \($0.localizedDescription)" } ?? "")")
        if wanted { central.connect(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        attempt += 1
        reset()
        guard wanted else { return }
        state = .connecting
        central.connect(peripheral)   // the clip advertises again at once, so this returns by itself
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        log("services: \(peripheral.services?.count ?? 0)\(error.map { ", error: \($0.localizedDescription)" } ?? "")")
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            fail(error.map { "The clip's channels could not be read. \($0.localizedDescription)" } ?? "This device does not offer the Earshot service. Its firmware may be out of date.")
            return
        }
        peripheral.discoverCharacteristics([Self.audio, Self.events, Self.commands], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let channels = service.characteristics ?? []
        log("channels: \(channels.count) of 3\(error.map { ", error: \($0.localizedDescription)" } ?? "")")
        let audio = channels.first { $0.uuid == Self.audio }, events = channels.first { $0.uuid == Self.events }
        commands = channels.first { $0.uuid == Self.commands }
        guard let audio, let events, commands != nil else {
            fail("The clip is missing one of its three channels. Its firmware may be out of date.")
            return
        }
        // Audio first: the clip starts talking the moment events is subscribed.
        peripheral.setNotifyValue(true, for: audio)
        peripheral.setNotifyValue(true, for: events)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let isAudio = characteristic.uuid == Self.audio, name = isAudio ? "audio" : "events"
        log("subscribed to \(name): \(characteristic.isNotifying)\(error.map { ", error: \($0.localizedDescription)" } ?? "")")
        guard error == nil, characteristic.isNotifying else {
            fail("Could not subscribe to the clip's \(name). \(error?.localizedDescription ?? "")")
            return
        }
        if isAudio { audioOn = true } else { eventsOn = true }
        settle()
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, case .ready = state else { return }
        let reading = RSSI.doubleValue
        smoothed = smoothed.map { $0 * 0.6 + reading * 0.4 } ?? reading
        let dBm = Int((smoothed ?? reading).rounded())
        onSignal(Signal(dBm: dBm, bars: Self.bars(for: dBm)))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let command = sent.isEmpty ? "a command" : sent.removeFirst()
        guard let error else {
            log("the clip took \(command)")
            return
        }
        log("the clip did not take \(command): \(error.localizedDescription)")
        onProblem("The clip did not get “\(command)”. \(error.localizedDescription)")
    }

    // MARK: Receiving

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log("a packet arrived with an error: \(error.localizedDescription)") }
        guard let data = characteristic.value else { return }
        if characteristic.uuid == Self.audio {
            hear(data)
        } else if characteristic.uuid == Self.events {
            log("event: \(String(decoding: data, as: UTF8.self))")
            guard let event = try? JSONDecoder().decode(ClipEvent.self, from: data) else {
                log("that event could not be read")
                return
            }
            if event.type == "hello" {
                hello = event.device ?? peripheral.name ?? "Earshot clip"
                settle()
            }
            if event.type == "consent", event.event == "granted" { nextSeq = 0 }   // the frame counter restarts with every capture
            onEvent(event)
        }
    }

    /// One audio packet: frame counter, the clip's clock, then 20 ms of Opus.
    private func hear(_ data: Data) {
        guard data.count > Self.header else { return }
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
        do {
            guard let decoder else { throw Problem("The audio decoder could not be created.") }
            onAudio(try decoder.decode(data.dropFirst(Self.header)))
        } catch {
            // Packets that arrive but cannot be turned into sound are not a working link, so say so once.
            undecoded += 1
            if undecoded == 1 {
                log("audio could not be decoded: \(error)")
                onProblem("Audio is arriving from the clip but cannot be decoded, so nothing is being transcribed.")
            }
        }
        #if DEBUG
        if Date().timeIntervalSince(counted) >= 1 {
            print("clip audio: \(packets) packets in the last second, \(lost) frames lost and \(undecoded) undecodable since connecting")
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
