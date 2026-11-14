#include "ble_link.h"
#if LINK_BLUETOOTH

#include "protocol.h"

namespace {
const size_t kMaxCommandBytes = 96;
struct Command {
  char text[kMaxCommandBytes];
};
}  // namespace

BleLink::BleLink()
    : server_(nullptr),
      audio_(nullptr),
      events_(nullptr),
      commands_(nullptr),
      rx_(nullptr),
      connected_(false),
      events_subscribed_(false),
      audio_subscribed_(false),
      conn_handle_(0),
      interval_units_(0),
      session_(0),
      lost_(false),
      open_(false),
      seen_session_(0),
      payload_(0),
      subscribed_since_(0),
      warned_small_(false),
      failed_sends_(0) {}

bool BleLink::begin(const char* name) {
  rx_ = xQueueCreate(8, sizeof(Command));
  if (!rx_ || !NimBLEDevice::init(name)) return false;
  NimBLEDevice::setMTU(247);  // the most we accept per packet; iOS settles on 185
  NimBLEDevice::setPower(9);  // dBm: full power, the clip is worn under clothing and kit

  server_ = NimBLEDevice::createServer();
  server_->setCallbacks(this, false);
  server_->advertiseOnDisconnect(false);  // done by hand in onDisconnect, so it is visible here

  NimBLEService* service = server_->createService(earshot::kBleServiceUuid);
  audio_ = service->createCharacteristic(earshot::kBleAudioUuid, NIMBLE_PROPERTY::NOTIFY);
  events_ = service->createCharacteristic(earshot::kBleEventUuid, NIMBLE_PROPERTY::NOTIFY);
  commands_ = service->createCharacteristic(earshot::kBleCommandUuid,
                                            NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  audio_->setCallbacks(this);
  events_->setCallbacks(this);
  commands_->setCallbacks(this);
  if (!server_->start()) return false;

  // The advertising packet carries the service ID (what the tablet scans for). The name does
  // not fit beside it, so it goes in the scan response, which a scanning tablet asks for
  // automatically. The scan response must be switched on before the name is set: otherwise the
  // library tries the main packet, finds no room and drops the name.
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->enableScanResponse(true);
  if (!adv->addServiceUUID(earshot::kBleServiceUuid) || !adv->setName(name)) return false;
  adv->setMinInterval(160);  // 100 ms (units of 0.625 ms): found within a second or two
  adv->setMaxInterval(240);  // 150 ms
  return adv->start();
}

// ---------------------------------------------------------------- Bluetooth task callbacks

void BleLink::onConnect(NimBLEServer* server, NimBLEConnInfo& info) {
  lost_ = false;
  conn_handle_ = info.getConnHandle();
  interval_units_ = info.getConnInterval();
  events_subscribed_ = false;
  audio_subscribed_ = false;
  connected_ = true;
  // Ask for the shortest interval iOS grants an accessory: 15 to 30 ms (units of 1.25 ms),
  // no skipped turns, and call the link lost after 4 s of silence. The tablet decides.
  server->updateConnParams(info.getConnHandle(), 12, 24, 0, 400);
  Serial.printf("[clip] bluetooth: connected to %s\n", info.getAddress().toString().c_str());
}

void BleLink::onDisconnect(NimBLEServer*, NimBLEConnInfo&, int reason) {
  // Why the connection ended. "Remote user terminated" is the tablet hanging up on purpose
  // (the app's Disconnect button, the app closing, Bluetooth switched off). Anything else,
  // most often a timeout, means the tablet simply stopped answering: out of range or dead.
  bool deliberate = reason == (BLE_HS_ERR_HCI_BASE + BLE_ERR_REM_USER_CONN_TERM);
  lost_ = !deliberate;
  connected_ = false;
  events_subscribed_ = false;
  audio_subscribed_ = false;
  ++session_;
  NimBLEDevice::startAdvertising();  // be findable again straight away
  Serial.printf("[clip] bluetooth: %s (reason 0x%x), advertising again\n",
                deliberate ? "the tablet disconnected" : "connection lost", reason);
}

void BleLink::onConnParamsUpdate(NimBLEConnInfo& info) { interval_units_ = info.getConnInterval(); }

void BleLink::onSubscribe(NimBLECharacteristic* chr, NimBLEConnInfo&, uint16_t sub_value) {
  bool on = (sub_value & 1) != 0;  // bit 0 = notifications
  if (chr == events_) {
    events_subscribed_ = on;
    ++session_;  // a new listener: the clip must say hello again
  } else if (chr == audio_) {
    audio_subscribed_ = on;
  }
}

void BleLink::onWrite(NimBLECharacteristic* chr, NimBLEConnInfo&) {
  if (chr != commands_) return;
  NimBLEAttValue value = chr->getValue();
  Command c;
  size_t n = value.size() < kMaxCommandBytes - 1 ? value.size() : kMaxCommandBytes - 1;
  memcpy(c.text, value.data(), n);
  c.text[n] = '\0';
  xQueueSend(rx_, &c, 0);
}

// ---------------------------------------------------------------- main loop side

void BleLink::service(uint32_t now) {
  uint32_t session = session_;
  if (session != seen_session_) {
    // Someone new subscribed, or the tablet went away. Read as closed for this pass so the
    // clip introduces itself again on the next one.
    seen_session_ = session;
    open_ = false;
    subscribed_since_ = now;
    warned_small_ = false;
    return;
  }
  if (!connected_ || !events_subscribed_) {
    open_ = false;
    return;
  }
  uint16_t mtu = server_->getPeerMTU(conn_handle_);
  payload_ = mtu > 3 ? mtu - 3 : 0;
  open_ = payload_ >= earshot::kBleMaxMessage;
  if (!open_ && !warned_small_ && (uint32_t)(now - subscribed_since_) > 2000) {
    warned_small_ = true;
    Serial.printf("[clip] bluetooth: the tablet allows only %u bytes per packet; %u are needed. "
                  "Not sending.\n", (unsigned)payload_, (unsigned)earshot::kBleMaxMessage);
  }
}

bool BleLink::poll(std::string& out) {
  Command c;
  if (!rx_ || xQueueReceive(rx_, &c, 0) != pdTRUE) return false;
  out = c.text;
  return true;
}

bool BleLink::sendText(const std::string& text) {
  if (!open_ || text.size() > payload_) return false;
  // Events must not be dropped. If the stack is momentarily out of buffers, wait briefly; the
  // clip's event queue retries on later passes if this still fails.
  for (int attempt = 0; attempt < 5; ++attempt) {
    if (events_->notify((const uint8_t*)text.data(), text.size(), conn_handle_)) return true;
    if (!connected_) break;
    delay(4);
  }
  ++failed_sends_;
  return false;
}

bool BleLink::sendBinary(const uint8_t* head, size_t head_len, const uint8_t* body, size_t body_len) {
  uint8_t packet[earshot::kBleMaxMessage];
  if (!open_ || !audio_subscribed_ || head_len + body_len > sizeof packet) return false;
  memcpy(packet, head, head_len);
  memcpy(packet + head_len, body, body_len);
  // Audio is never retried: a late frame is worth less than the next one. The frame counter in
  // the header shows the tablet what was lost.
  if (audio_->notify(packet, head_len + body_len, conn_handle_)) return true;
  ++failed_sends_;
  return false;
}

#endif  // LINK_BLUETOOTH
