#include <Arduino.h>
#include <BluetoothSerial.h>
#include <ESP32Servo.h>

#if !defined(CONFIG_BT_ENABLED) || !defined(CONFIG_BLUEDROID_ENABLED)
#error Bluetooth is not enabled. Please enable it in menuconfig.
#endif

namespace {
constexpr const char *kDeviceName = "SMR-Servo-Test";
constexpr uint8_t kServoPins[3] = {25, 26, 27};
constexpr int kDefaultLockAngles[3] = {45, 45, 45};
constexpr int kDefaultUnlockAngles[3] = {160, 160, 160};
constexpr size_t kMaxInboundLineLength = 128;
constexpr uint32_t kDefaultTestDelayMs = 1500;
} // namespace

BluetoothSerial serialBt;
Servo servos[3];
String inputBuffer;
int lockAngles[3] = {
    kDefaultLockAngles[0],
    kDefaultLockAngles[1],
    kDefaultLockAngles[2],
};
int unlockAngles[3] = {
    kDefaultUnlockAngles[0],
    kDefaultUnlockAngles[1],
    kDefaultUnlockAngles[2],
};
int currentAngles[3] = {
    kDefaultLockAngles[0],
    kDefaultLockAngles[1],
    kDefaultLockAngles[2],
};

void sendLine(const String &line) {
  serialBt.print(line);
  serialBt.print('\n');
  Serial.println(line);
}

void sendError(const char *errorCode) { sendLine(String("ERR,") + errorCode); }

bool parsePositiveInt(const String &token, int &value) {
  if (token.isEmpty()) {
    return false;
  }

  int result = 0;
  for (int i = 0; i < token.length(); i++) {
    if (!isDigit(token[i])) {
      return false;
    }
    result = (result * 10) + (token[i] - '0');
  }

  value = result;
  return true;
}

bool parseSlot(const String &token, int &slotIndex) {
  int slot = 0;
  if (!parsePositiveInt(token, slot) || slot < 1 || slot > 3) {
    return false;
  }
  slotIndex = slot - 1;
  return true;
}

bool parseAngle(const String &token, int &angle) {
  if (!parsePositiveInt(token, angle)) {
    return false;
  }
  return angle >= 0 && angle <= 180;
}

bool splitCsvExact(const String &line, String *parts, int expectedCount) {
  int start = 0;
  for (int i = 0; i < expectedCount - 1; i++) {
    const int comma = line.indexOf(',', start);
    if (comma < 0) {
      return false;
    }
    parts[i] = line.substring(start, comma);
    start = comma + 1;
  }

  if (line.indexOf(',', start) != -1) {
    return false;
  }

  parts[expectedCount - 1] = line.substring(start);
  for (int i = 0; i < expectedCount; i++) {
    parts[i].trim();
  }
  return true;
}

void moveServoTo(int slotIndex, int angle) {
  servos[slotIndex].write(angle);
  currentAngles[slotIndex] = angle;
}

void sendStatus() {
  for (int i = 0; i < 3; i++) {
    sendLine(String("SLOT,") + (i + 1) + ",CUR," + currentAngles[i] + ",LOCK," +
             lockAngles[i] + ",UNLOCK," + unlockAngles[i]);
  }
}

void handleMove(const String &line) {
  String parts[3];
  if (!splitCsvExact(line, parts, 3) || parts[0] != "MOVE") {
    sendError("BAD_FORMAT");
    return;
  }

  int slotIndex = 0;
  int angle = 0;
  if (!parseSlot(parts[1], slotIndex) || !parseAngle(parts[2], angle)) {
    sendError("BAD_FORMAT");
    return;
  }

  moveServoTo(slotIndex, angle);
  sendLine("OK");
}

void handleLock(const String &line) {
  String parts[2];
  if (!splitCsvExact(line, parts, 2) || parts[0] != "LOCK") {
    sendError("BAD_FORMAT");
    return;
  }

  int slotIndex = 0;
  if (!parseSlot(parts[1], slotIndex)) {
    sendError("BAD_FORMAT");
    return;
  }

  moveServoTo(slotIndex, lockAngles[slotIndex]);
  sendLine("OK");
}

void handleUnlock(const String &line) {
  String parts[2];
  if (!splitCsvExact(line, parts, 2) || parts[0] != "UNLOCK") {
    sendError("BAD_FORMAT");
    return;
  }

  int slotIndex = 0;
  if (!parseSlot(parts[1], slotIndex)) {
    sendError("BAD_FORMAT");
    return;
  }

  moveServoTo(slotIndex, unlockAngles[slotIndex]);
  sendLine("OK");
}

void handleSetLock(const String &line) {
  String parts[3];
  if (!splitCsvExact(line, parts, 3) || parts[0] != "SETLOCK") {
    sendError("BAD_FORMAT");
    return;
  }

  int slotIndex = 0;
  int angle = 0;
  if (!parseSlot(parts[1], slotIndex) || !parseAngle(parts[2], angle)) {
    sendError("BAD_FORMAT");
    return;
  }

  lockAngles[slotIndex] = angle;
  sendLine("OK");
}

void handleSetUnlock(const String &line) {
  String parts[3];
  if (!splitCsvExact(line, parts, 3) || parts[0] != "SETUNLOCK") {
    sendError("BAD_FORMAT");
    return;
  }

  int slotIndex = 0;
  int angle = 0;
  if (!parseSlot(parts[1], slotIndex) || !parseAngle(parts[2], angle)) {
    sendError("BAD_FORMAT");
    return;
  }

  unlockAngles[slotIndex] = angle;
  sendLine("OK");
}

void handleTest(const String &line) {
  String parts[2];
  if (!splitCsvExact(line, parts, 2) || parts[0] != "TEST") {
    sendError("BAD_FORMAT");
    return;
  }

  int slotIndex = 0;
  if (!parseSlot(parts[1], slotIndex)) {
    sendError("BAD_FORMAT");
    return;
  }

  moveServoTo(slotIndex, unlockAngles[slotIndex]);
  delay(kDefaultTestDelayMs);
  moveServoTo(slotIndex, lockAngles[slotIndex]);
  sendLine("OK");
}

void handleSweep(const String &line) {
  String parts[6];
  if (!splitCsvExact(line, parts, 6) || parts[0] != "SWEEP") {
    sendError("BAD_FORMAT");
    return;
  }

  int slotIndex = 0;
  int fromAngle = 0;
  int toAngle = 0;
  int step = 0;
  int delayMs = 0;
  if (!parseSlot(parts[1], slotIndex) || !parseAngle(parts[2], fromAngle) ||
      !parseAngle(parts[3], toAngle) || !parsePositiveInt(parts[4], step) ||
      !parsePositiveInt(parts[5], delayMs)) {
    sendError("BAD_FORMAT");
    return;
  }
  if (step < 1 || delayMs < 1 || delayMs > 5000) {
    sendError("BAD_FORMAT");
    return;
  }

  if (fromAngle <= toAngle) {
    for (int angle = fromAngle; angle <= toAngle; angle += step) {
      moveServoTo(slotIndex, angle);
      delay(delayMs);
    }
  } else {
    for (int angle = fromAngle; angle >= toAngle; angle -= step) {
      moveServoTo(slotIndex, angle);
      delay(delayMs);
    }
  }

  sendLine("OK");
}

void handleCommand(const String &rawLine) {
  String line = rawLine;
  line.trim();
  if (line.isEmpty()) {
    return;
  }

  if (line == "HELP") {
    sendLine("CMDS,HELP,PING,STATUS,LOCK,slot,UNLOCK,slot,MOVE,slot,angle");
    sendLine("CMDS,SETLOCK,slot,angle,SETUNLOCK,slot,angle,TEST,slot");
    sendLine("CMDS,SWEEP,slot,from,to,step,delayMs");
    return;
  }

  if (line == "PING") {
    sendLine("OK");
    return;
  }

  if (line == "STATUS") {
    sendStatus();
    return;
  }

  if (line.startsWith("MOVE,")) {
    handleMove(line);
    return;
  }

  if (line.startsWith("LOCK,")) {
    handleLock(line);
    return;
  }

  if (line.startsWith("UNLOCK,")) {
    handleUnlock(line);
    return;
  }

  if (line.startsWith("SETLOCK,")) {
    handleSetLock(line);
    return;
  }

  if (line.startsWith("SETUNLOCK,")) {
    handleSetUnlock(line);
    return;
  }

  if (line.startsWith("TEST,")) {
    handleTest(line);
    return;
  }

  if (line.startsWith("SWEEP,")) {
    handleSweep(line);
    return;
  }

  sendError("BAD_FORMAT");
}

void readBluetoothInput() {
  while (serialBt.available()) {
    const char incoming = static_cast<char>(serialBt.read());

    if (incoming == '\r') {
      continue;
    }

    if (incoming == '\n') {
      if (!inputBuffer.isEmpty()) {
        handleCommand(inputBuffer);
        inputBuffer = "";
      }
      continue;
    }

    if (inputBuffer.length() >= kMaxInboundLineLength) {
      inputBuffer = "";
      sendError("BAD_FORMAT");
      continue;
    }

    inputBuffer += incoming;
  }
}

void setup() {
  Serial.begin(115200);
  delay(200);

  for (int i = 0; i < 3; i++) {
    servos[i].setPeriodHertz(50);
    servos[i].attach(kServoPins[i], 500, 2400);
    moveServoTo(i, lockAngles[i]);
  }

  serialBt.begin(kDeviceName);

  Serial.println("Servo Bluetooth test ready");
  sendLine("READY,SERVO_TEST");
  sendStatus();
}

void loop() { readBluetoothInput(); }
