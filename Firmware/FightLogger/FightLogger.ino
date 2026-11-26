// FIGHT Logger
// A tiny box that rides on your heart-rate band. It connects to the band (any standard
// Bluetooth heart-rate strap or armband), keeps every reading in memory, and passes heart rate
// through to the FIGHT app live. When the phone has been out of range, FIGHT asks for the
// seconds it missed and fills the gap with real data.
//
// Board: Seeed Studio XIAO nRF52840 ("Seeed nRF52 Boards" core, Adafruit Bluefruit library).
//
// Bluetooth layout (what the phone sees):
//   Heart Rate service 0x180D   - live heart rate, forwarded unchanged from the band
//   Battery service 0x180F      - the logger's own battery
//   FIGHT Logger service        - clock, missed-seconds download, status
//
// Commands written to the control characteristic:
//   0x01 <uint32 unix seconds>  set the clock
//   0x02 <uint32 unix seconds>  send every reading after this time
//   0x03                        forget the band (pair with the closest one again)
//   0x04                        clear the stored readings
// Data notifications:
//   0xD1 <count> then count x (<uint32 unix seconds> <uint8 bpm>)
//   0xD2 <uint16 total sent>    end of download
// Status (read / notify): band connected, battery %, stored readings (uint16), clock set, band RSSI

#include <bluefruit.h>
#include <Adafruit_LittleFS.h>
#include <InternalFileSystem.h>
#include <nrf_wdt.h>

using namespace Adafruit_LittleFS_Namespace;

#ifndef LED_GREEN
#define LED_RED 0
#define LED_GREEN 0
#define LED_BLUE 0
#define NO_LEDS 1
#endif

#define LOGGER_SERVICE_UUID "6f0a0001-5a3e-4d6b-9c1f-46494748540a"
#define LOGGER_CONTROL_UUID "6f0a0002-5a3e-4d6b-9c1f-46494748540a"
#define LOGGER_DATA_UUID    "6f0a0003-5a3e-4d6b-9c1f-46494748540a"
#define LOGGER_STATUS_UUID  "6f0a0004-5a3e-4d6b-9c1f-46494748540a"

// Only a band this close is adopted when pairing (it should be centimetres away).
static const int8_t PAIR_RSSI = -62;
// Readings kept in memory: one per second, about 4.4 hours.
static const uint32_t LOG_CAPACITY = 16000;
// Flush ring buffer to flash this often so a battery cutoff loses at most this much.
static const uint32_t FLUSH_INTERVAL_MS = 60000;

struct __attribute__((packed)) Reading {
  uint32_t uptime;   // seconds since the logger started
  uint8_t bpm;
};

static Reading readings[LOG_CAPACITY];
static uint32_t logHead = 0;    // next slot to write
static uint32_t logCount = 0;

static int64_t unixOffset = 0;  // unix time = uptime + offset
static bool clockSet = false;

// Flash persistence
static const char* LOG_FILE = "/workout";
static uint32_t lastFlushedHead = UINT32_MAX;  // forces first flush
static uint32_t lastFlushedCount = 0;
static uint32_t lastFlushMs = 0;

// Band (we are the central)
BLEClientService bandService(UUID16_SVC_HEART_RATE);
BLEClientCharacteristic bandMeasurement(UUID16_CHR_HEART_RATE_MEASUREMENT);
static uint16_t bandConn = BLE_CONN_HANDLE_INVALID;
static uint8_t savedBand[6];
static bool haveSavedBand = false;
static int8_t bandRssi = 0;

// Phone (we are the peripheral)
BLEService hrService(UUID16_SVC_HEART_RATE);
BLECharacteristic hrMeasurement(UUID16_CHR_HEART_RATE_MEASUREMENT);
BLECharacteristic hrLocation(UUID16_CHR_BODY_SENSOR_LOCATION);
BLEBas battery;
BLEService loggerService(LOGGER_SERVICE_UUID);
BLECharacteristic loggerControl(LOGGER_CONTROL_UUID);
BLECharacteristic loggerData(LOGGER_DATA_UUID);
BLECharacteristic loggerStatus(LOGGER_STATUS_UUID);
static uint16_t phoneConn = BLE_CONN_HANDLE_INVALID;

// Download in progress (sent from loop(), not from the Bluetooth callback)
static bool sending = false;
static uint32_t sendSince = 0;    // unix seconds
static uint32_t sendIndex = 0;    // 0..sendCount
static uint32_t sendCount = 0;    // snapshot of logCount at download start
static uint32_t sendStart = 0;    // snapshot of ring-buffer start index at download start
static uint16_t sentTotal = 0;
static uint16_t txRetryCount = 0; // consecutive failed notifies; abort after threshold

static bool flushRequested = false; // set from BLE callbacks; executed in loop()

static uint8_t batteryPercent = 100;
static uint32_t lastBatteryCheck = 0;
static uint32_t lastStatus = 0;

// ---------------------------------------------------------------- helpers

static uint32_t uptimeSeconds() { return millis() / 1000; }

static void led(int pin, bool on) {
#ifndef NO_LEDS
  digitalWrite(pin, on ? LOW : HIGH);  // XIAO LEDs are on when the pin is low
#else
  (void)pin;
  (void)on;
#endif
}

static void blink(int pin, int times) {
  for (int i = 0; i < times; i++) {
    led(pin, true);
    delay(60);
    led(pin, false);
    delay(120);
  }
}

static void storeReading(uint8_t bpm) {
  readings[logHead].uptime = uptimeSeconds();
  readings[logHead].bpm = bpm;
  logHead = (logHead + 1) % LOG_CAPACITY;
  if (logCount < LOG_CAPACITY) logCount++;
}

// i = 0 is the oldest reading kept
static const Reading& readingAt(uint32_t i) {
  uint32_t start = (logHead + LOG_CAPACITY - logCount) % LOG_CAPACITY;
  return readings[(start + i) % LOG_CAPACITY];
}

static uint32_t toUnix(uint32_t uptime) { return (uint32_t)(unixOffset + (int64_t)uptime); }

static void loadSavedBand() {
  File f(InternalFS);
  if (f.open("/band", FILE_O_READ)) {
    haveSavedBand = f.read(savedBand, 6) == 6;
    f.close();
  }
}

static void saveBand(const uint8_t* addr) {
  InternalFS.remove("/band");
  File f(InternalFS);
  if (f.open("/band", FILE_O_WRITE)) {
    f.write(addr, 6);
    f.close();
  }
  memcpy(savedBand, addr, 6);
  haveSavedBand = true;
}

static void forgetBand() {
  InternalFS.remove("/band");
  haveSavedBand = false;
  if (bandConn != BLE_CONN_HANDLE_INVALID) Bluefruit.disconnect(bandConn);
}

// File layout: 1-byte magic | 8-byte unixOffset | 1-byte clockSet | N x Reading
// Saving unixOffset means uptime-relative timestamps survive a reboot intact.
static const uint8_t LOG_MAGIC = 0x46;

static void flushToFlash() {
  if (logCount == 0) return;
  if (logCount == lastFlushedCount && logHead == lastFlushedHead) return;
  InternalFS.remove(LOG_FILE);
  File f(InternalFS);
  if (!f.open(LOG_FILE, FILE_O_WRITE)) return;
  uint8_t cs = clockSet ? 1 : 0;
  f.write(&LOG_MAGIC, 1);
  f.write((const uint8_t*)&unixOffset, sizeof(unixOffset));
  f.write(&cs, 1);
  // Write in 256-reading chunks to avoid 16000 single-record calls.
  static Reading chunk[256];
  uint32_t written = 0;
  while (written < logCount) {
    uint32_t n = logCount - written;
    if (n > 256) n = 256;
    for (uint32_t i = 0; i < n; i++) chunk[i] = readingAt(written + i);
    f.write((const uint8_t*)chunk, n * sizeof(Reading));
    written += n;
  }
  f.close();
  lastFlushedCount = logCount;
  lastFlushedHead = logHead;
}

// On boot, reload readings and the unixOffset saved before the last power cycle.
static void loadFromFlash() {
  File f(InternalFS);
  if (!f.open(LOG_FILE, FILE_O_READ)) return;
  uint8_t magic = 0;
  int64_t savedOffset = 0;
  uint8_t cs = 0;
  if (f.read(&magic, 1) != 1 || magic != LOG_MAGIC) { f.close(); return; }
  if (f.read((uint8_t*)&savedOffset, sizeof(savedOffset)) != (int)sizeof(savedOffset)) { f.close(); return; }
  if (f.read(&cs, 1) != 1) { f.close(); return; }
  unixOffset = savedOffset;
  clockSet = (cs == 1);
  logHead = 0;
  logCount = 0;
  Reading r;
  while (logCount < LOG_CAPACITY) {
    if (f.read((uint8_t*)&r, sizeof(Reading)) != (int)sizeof(Reading)) break;
    readings[logCount++] = r;
  }
  f.close();
  logHead = logCount % LOG_CAPACITY;
  lastFlushedCount = logCount;
  lastFlushedHead = logHead;
}

static void readBattery() {
#if defined(PIN_VBAT) && defined(VBAT_ENABLE)
  // Battery through a 1M / 510k divider; 10-bit reading against the 3.6 V reference.
  int raw = analogRead(PIN_VBAT);
  float volts = raw * 3.6f / 1023.0f * (1510.0f / 510.0f);
  int pct = (int)((volts - 3.3f) / (4.15f - 3.3f) * 100.0f);
  if (pct < 0) pct = 0;
  if (pct > 100) pct = 100;
  batteryPercent = (uint8_t)pct;
#endif
  battery.write(batteryPercent);
}

static void pushStatus() {
  uint8_t s[6];
  s[0] = bandConn != BLE_CONN_HANDLE_INVALID ? 1 : 0;
  s[1] = batteryPercent;
  uint16_t n = logCount > 65535 ? 65535 : (uint16_t)logCount;
  s[2] = n & 0xFF;
  s[3] = n >> 8;
  s[4] = clockSet ? 1 : 0;
  s[5] = (uint8_t)bandRssi;
  loggerStatus.write(s, sizeof(s));
  if (phoneConn != BLE_CONN_HANDLE_INVALID) loggerStatus.notify(phoneConn, s, sizeof(s));
}

// ---------------------------------------------------------------- band side

static bool sameAddress(const uint8_t* a, const uint8_t* b) { return memcmp(a, b, 6) == 0; }

static void scanCallback(ble_gap_evt_adv_report_t* report) {
  const uint8_t* addr = report->peer_addr.addr;
  bool ours = haveSavedBand ? sameAddress(addr, savedBand) : report->rssi >= PAIR_RSSI;
  if (ours) {
    bandRssi = report->rssi;
    Bluefruit.Central.connect(report);
  } else {
    Bluefruit.Scanner.resume();
  }
}

static void bandMeasurementCallback(BLEClientCharacteristic* chr, uint8_t* data, uint16_t len) {
  if (len < 2) return;
  uint16_t bpm = (data[0] & 0x01) ? (uint16_t)(data[1] | (data[2] << 8)) : data[1];
  if (bpm > 0 && bpm < 255) storeReading((uint8_t)bpm);
  // Pass the measurement through unchanged (heart rate and RR intervals).
  if (phoneConn != BLE_CONN_HANDLE_INVALID) hrMeasurement.notify(phoneConn, data, len);
}

static void bandConnected(uint16_t conn) {
  if (!bandService.discover(conn) || !bandMeasurement.discover()) {
    Bluefruit.disconnect(conn);
    return;
  }
  bandConn = conn;
  bandMeasurement.enableNotify();
  if (!haveSavedBand) {
    ble_gap_addr_t peer = Bluefruit.Connection(conn)->getPeerAddr();
    saveBand(peer.addr);
  }
  blink(LED_GREEN, 3);
  pushStatus();
}

static void bandDisconnected(uint16_t conn, uint8_t reason) {
  (void)conn;
  (void)reason;
  bandConn = BLE_CONN_HANDLE_INVALID;
  pushStatus();
  // The scanner restarts by itself (restartOnDisconnect).
}

// ---------------------------------------------------------------- phone side

static void phoneConnected(uint16_t conn) {
  phoneConn = conn;
  pushStatus();
}

static void phoneDisconnected(uint16_t conn, uint8_t reason) {
  (void)conn;
  (void)reason;
  phoneConn = BLE_CONN_HANDLE_INVALID;
  sending = false;
  flushRequested = true;  // flush in loop(); never block flash I/O inside a BLE callback
}

static uint32_t readU32(const uint8_t* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void controlWritten(uint16_t conn, BLECharacteristic* chr, uint8_t* data, uint16_t len) {
  (void)chr;
  if (len < 1) return;
  switch (data[0]) {
    case 0x01:
      if (len >= 5) {
        unixOffset = (int64_t)readU32(data + 1) - (int64_t)uptimeSeconds();
        clockSet = true;
        pushStatus();
      }
      break;
    case 0x02:
      if (len >= 5) {
        sendSince = readU32(data + 1);
        sendIndex = 0;
        sendCount = logCount;
        sendStart = (logHead + LOG_CAPACITY - logCount) % LOG_CAPACITY;
        sentTotal = 0;
        txRetryCount = 0;
        sending = clockSet;
        if (!clockSet) {
          uint8_t end[3] = {0xD2, 0, 0};
          loggerData.notify(conn, end, sizeof(end));
        }
      }
      break;
    case 0x03:
      forgetBand();
      pushStatus();
      break;
    case 0x04:
      sending = false;  // abort any in-progress download before wiping
      logHead = 0;
      logCount = 0;
      lastFlushedHead = 0;
      lastFlushedCount = 0;
      InternalFS.remove(LOG_FILE);
      pushStatus();
      break;
  }
}

// Sends a few packets of the download each time round the loop.
static void continueSending() {
  if (!sending || phoneConn == BLE_CONN_HANDLE_INVALID) return;
  BLEConnection* c = Bluefruit.Connection(phoneConn);
  uint16_t room = c ? c->getMtu() - 3 : 20;
  if (room > 240) room = 240;
  uint8_t perPacket = (room - 2) / 5;
  if (perPacket < 1) perPacket = 1;

  for (int burst = 0; burst < 4 && sending; burst++) {
    uint8_t buf[242];
    uint8_t n = 0;
    uint32_t startIndex = sendIndex;
    while (sendIndex < sendCount && n < perPacket) {
      // Use snapshotted sendStart so incoming beats can't shift the walk.
      const Reading& r = readings[(sendStart + sendIndex++) % LOG_CAPACITY];
      uint32_t t = toUnix(r.uptime);
      if (t <= sendSince) continue;
      uint8_t* p = buf + 2 + n * 5;
      p[0] = t & 0xFF;
      p[1] = (t >> 8) & 0xFF;
      p[2] = (t >> 16) & 0xFF;
      p[3] = (t >> 24) & 0xFF;
      p[4] = r.bpm;
      n++;
    }
    if (n > 0) {
      buf[0] = 0xD1;
      buf[1] = n;
      if (!loggerData.notify(phoneConn, buf, 2 + n * 5)) {
        sendIndex = startIndex;
        // Abort if the phone is stalled (out of range but not disconnected).
        if (++txRetryCount > 100) { sending = false; }
        return;
      }
      txRetryCount = 0;
      sentTotal += n;
    }
    if (sendIndex >= sendCount) {
      uint8_t end[3] = {0xD2, (uint8_t)(sentTotal & 0xFF), (uint8_t)(sentTotal >> 8)};
      // Retry the end-of-download marker next tick if the queue is momentarily full.
      if (!loggerData.notify(phoneConn, end, sizeof(end))) return;
      sending = false;
    }
  }
}

// ---------------------------------------------------------------- setup / loop

void setup() {
#ifndef NO_LEDS
  pinMode(LED_RED, OUTPUT);
  pinMode(LED_GREEN, OUTPUT);
  pinMode(LED_BLUE, OUTPUT);
  led(LED_RED, false);
  led(LED_GREEN, false);
  led(LED_BLUE, false);
#endif
#if defined(PIN_VBAT) && defined(VBAT_ENABLE)
  pinMode(VBAT_ENABLE, OUTPUT);
  digitalWrite(VBAT_ENABLE, LOW);  // keep low: enables the battery reading safely
#endif

  InternalFS.begin();
  loadSavedBand();
  loadFromFlash();

  Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);
  Bluefruit.configCentralBandwidth(BANDWIDTH_MAX);
  Bluefruit.begin(1, 1);
  Bluefruit.autoConnLed(false);
  Bluefruit.setTxPower(4);
  Bluefruit.setName("FIGHT Logger");

  // Band side
  bandService.begin();
  bandMeasurement.setNotifyCallback(bandMeasurementCallback);
  bandMeasurement.begin();
  Bluefruit.Central.setConnectCallback(bandConnected);
  Bluefruit.Central.setDisconnectCallback(bandDisconnected);
  Bluefruit.Scanner.setRxCallback(scanCallback);
  Bluefruit.Scanner.restartOnDisconnect(true);
  Bluefruit.Scanner.filterUuid(bandService.uuid);
  Bluefruit.Scanner.setInterval(1600, 160);  // every 1 s, listen 100 ms: easy on the battery
  Bluefruit.Scanner.useActiveScan(false);
  Bluefruit.Scanner.start(0);

  // Phone side
  Bluefruit.Periph.setConnectCallback(phoneConnected);
  Bluefruit.Periph.setDisconnectCallback(phoneDisconnected);

  hrService.begin();
  hrMeasurement.setProperties(CHR_PROPS_NOTIFY);
  hrMeasurement.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  hrMeasurement.setMaxLen(20);
  hrMeasurement.begin();
  hrLocation.setProperties(CHR_PROPS_READ);
  hrLocation.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  hrLocation.setFixedLen(1);
  hrLocation.begin();
  hrLocation.write8(1);  // chest

  battery.begin();

  loggerService.begin();
  loggerControl.setProperties(CHR_PROPS_WRITE | CHR_PROPS_WRITE_WO_RESP);
  loggerControl.setPermission(SECMODE_NO_ACCESS, SECMODE_OPEN);
  loggerControl.setMaxLen(20);
  loggerControl.setWriteCallback(controlWritten);
  loggerControl.begin();
  loggerData.setProperties(CHR_PROPS_NOTIFY);
  loggerData.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  loggerData.setMaxLen(244);
  loggerData.begin();
  loggerStatus.setProperties(CHR_PROPS_READ | CHR_PROPS_NOTIFY);
  loggerStatus.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  loggerStatus.setFixedLen(6);
  loggerStatus.begin();

  readBattery();
  pushStatus();

  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addService(hrService);
  Bluefruit.Advertising.addService(loggerService);
  Bluefruit.ScanResponse.addName();
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(160, 800);  // 100 ms for 30 s, then every 500 ms
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);

  blink(LED_BLUE, 2);

  // Start watchdog last: LittleFS init or loadFromFlash() can be slow on first boot.
  nrf_wdt_behaviour_set(NRF_WDT, NRF_WDT_BEHAVIOUR_RUN_SLEEP_HALT);
  nrf_wdt_reload_value_set(NRF_WDT, 8 * 32768);  // 8 s at 32 kHz LFCLK
  nrf_wdt_reload_request_enable(NRF_WDT, NRF_WDT_RR0);
  nrf_wdt_task_trigger(NRF_WDT, NRF_WDT_TASK_START);
}

void loop() {
  nrf_wdt_reload_request_set(NRF_WDT, NRF_WDT_RR0);  // feed watchdog
  continueSending();

  uint32_t now = millis();
  if (now - lastBatteryCheck > 60000) {
    lastBatteryCheck = now;
    readBattery();
  }
  if (now - lastStatus > 10000) {
    lastStatus = now;
    pushStatus();
    // A short green flash every 10 s while the band is recording; nothing otherwise.
    if (bandConn != BLE_CONN_HANDLE_INVALID) blink(LED_GREEN, 1);
  }
  if (flushRequested || now - lastFlushMs > FLUSH_INTERVAL_MS) {
    lastFlushMs = now;
    flushRequested = false;
    flushToFlash();
  }
  delay(sending ? 5 : 50);
}
