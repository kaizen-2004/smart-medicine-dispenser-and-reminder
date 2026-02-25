#include <Arduino.h>
#include <BluetoothSerial.h>
#include <esp_system.h>

#if !defined(CONFIG_BT_ENABLED) || !defined(CONFIG_BLUEDROID_ENABLED)
#error Bluetooth is not enabled. Please enable it in menuconfig.
#endif

namespace {
constexpr const char *kDeviceName = "SMR-BT-DIAG";
constexpr size_t kMaxLineLength = 80;
constexpr uint32_t kHeartbeatIntervalMs = 2000;
} // namespace

BluetoothSerial serialBt;
String btBuffer;
uint32_t lastHeartbeatMs = 0;

void sendBt(const String &line) {
  serialBt.print(line);
  serialBt.print('\n');
}

void sendBoth(const String &line) {
  Serial.println(line);
  sendBt(line);
}

void sendInfo() {
  sendBoth(
      String("INFO,uptime_ms=") + millis() + ",free_heap=" + ESP.getFreeHeap() +
      ",bt_client=" + (serialBt.hasClient() ? "1" : "0"));
}

void handleCommand(const String &rawLine) {
  String line = rawLine;
  line.trim();
  line.toUpperCase();
  if (line.isEmpty()) {
    return;
  }

  if (line == "PING") {
    sendBoth("PONG");
    return;
  }

  if (line == "INFO") {
    sendInfo();
    return;
  }

  if (line == "RESET") {
    sendBoth("OK,RESETTING");
    delay(100);
    ESP.restart();
    return;
  }

  sendBoth("ERR,BAD_FORMAT");
}

void readBtInput() {
  while (serialBt.available()) {
    const char incoming = static_cast<char>(serialBt.read());
    if (incoming == '\r') {
      continue;
    }
    if (incoming == '\n') {
      if (!btBuffer.isEmpty()) {
        handleCommand(btBuffer);
        btBuffer = "";
      }
      continue;
    }
    if (btBuffer.length() >= kMaxLineLength) {
      btBuffer = "";
      sendBoth("ERR,BAD_FORMAT");
      continue;
    }
    btBuffer += incoming;
  }
}

void readSerialInput() {
  while (Serial.available()) {
    const String line = Serial.readStringUntil('\n');
    handleCommand(line);
  }
}

void setup() {
  Serial.begin(115200);
  delay(300);

  serialBt.begin(kDeviceName);
  Serial.println("READY,BLUETOOTH_ONLY_STABILITY_TEST");
  Serial.printf("BT_DEVICE_NAME,%s\n", kDeviceName);
  sendInfo();
}

void loop() {
  readBtInput();
  readSerialInput();

  const uint32_t nowMs = millis();
  if ((nowMs - lastHeartbeatMs) >= kHeartbeatIntervalMs) {
    lastHeartbeatMs = nowMs;
    sendBoth(
        String("HB,uptime_ms=") + nowMs + ",bt_client=" +
        (serialBt.hasClient() ? "1" : "0"));
  }
}
