#include <Arduino.h>
#include <BluetoothSerial.h>
#include <ESP32Servo.h>
#include <Preferences.h>

#if !defined(CONFIG_BT_ENABLED) || !defined(CONFIG_BLUEDROID_ENABLED)
#error Bluetooth is not enabled. Please enable it in menuconfig.
#endif

namespace {
constexpr const char *kDeviceName = "SMR-Servo-Calib";
constexpr uint8_t kServoPins[3] = {25, 26, 27};
constexpr int kDefaultLockAngles[3] = {45, 45, 45};
constexpr int kDefaultUnlockAngles[3] = {160, 160, 160};
constexpr int kDefaultStartAngle = 90;
constexpr size_t kMaxInboundLineLength = 128;
constexpr uint32_t kDefaultTestDelayMs = 1500;
constexpr uint32_t kMinTestDelayMs = 100;
constexpr uint32_t kMaxTestDelayMs = 10000;
} // namespace

BluetoothSerial serialBt;
Preferences preferences;
Servo servos[3];

String btBuffer;
String serialBuffer;
int selectedSlotIndex = 0;
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
    kDefaultStartAngle,
    kDefaultStartAngle,
    kDefaultStartAngle,
};

void sendLine(const String &line) {
  Serial.println(line);
  serialBt.print(line);
  serialBt.print('\n');
}

void sendError(const char *code) { sendLine(String("ERR,") + code); }

bool parsePositiveInt(const String &token, int &value) {
  if (token.isEmpty()) {
    return false;
  }

  int parsed = 0;
  for (int i = 0; i < token.length(); i++) {
    if (!isDigit(token[i])) {
      return false;
    }
    parsed = (parsed * 10) + (token[i] - '0');
  }
  value = parsed;
  return true;
}

bool parseSignedInt(const String &token, int &value) {
  if (token.isEmpty()) {
    return false;
  }

  bool negative = false;
  int start = 0;
  if (token[0] == '-') {
    negative = true;
    start = 1;
  } else if (token[0] == '+') {
    start = 1;
  }

  if (start >= token.length()) {
    return false;
  }

  int parsed = 0;
  for (int i = start; i < token.length(); i++) {
    if (!isDigit(token[i])) {
      return false;
    }
    parsed = (parsed * 10) + (token[i] - '0');
  }

  value = negative ? -parsed : parsed;
  return true;
}

bool parseSlotToken(const String &token, int &slotIndex) {
  int slot = 0;
  if (!parsePositiveInt(token, slot) || slot < 1 || slot > 3) {
    return false;
  }
  slotIndex = slot - 1;
  return true;
}

bool parseAngleToken(const String &token, int &angle) {
  if (!parseSignedInt(token, angle)) {
    return false;
  }
  if (angle < 0 || angle > 180) {
    return false;
  }
  return true;
}

bool splitCsv(const String &line, String *parts, int maxParts, int &count) {
  count = 0;
  int start = 0;
  while (count < maxParts) {
    const int comma = line.indexOf(',', start);
    if (comma < 0) {
      parts[count++] = line.substring(start);
      break;
    }
    parts[count++] = line.substring(start, comma);
    start = comma + 1;
  }

  if (line.indexOf(',', start) != -1 && count == maxParts) {
    return false;
  }

  for (int i = 0; i < count; i++) {
    parts[i].trim();
  }
  return count > 0;
}

void writeServo(int slotIndex, int angle) {
  const int clamped = constrain(angle, 0, 180);
  servos[slotIndex].write(clamped);
  currentAngles[slotIndex] = clamped;
}

void moveSelectedServoTo(int angle) { writeServo(selectedSlotIndex, angle); }

void loadCalibration() {
  lockAngles[0] = preferences.getInt("lock1", kDefaultLockAngles[0]);
  lockAngles[1] = preferences.getInt("lock2", kDefaultLockAngles[1]);
  lockAngles[2] = preferences.getInt("lock3", kDefaultLockAngles[2]);
  unlockAngles[0] = preferences.getInt("unlock1", kDefaultUnlockAngles[0]);
  unlockAngles[1] = preferences.getInt("unlock2", kDefaultUnlockAngles[1]);
  unlockAngles[2] = preferences.getInt("unlock3", kDefaultUnlockAngles[2]);
}

void saveCalibration() {
  preferences.putInt("lock1", lockAngles[0]);
  preferences.putInt("lock2", lockAngles[1]);
  preferences.putInt("lock3", lockAngles[2]);
  preferences.putInt("unlock1", unlockAngles[0]);
  preferences.putInt("unlock2", unlockAngles[1]);
  preferences.putInt("unlock3", unlockAngles[2]);
}

void sendStatus() {
  sendLine(String("SELECTED,") + (selectedSlotIndex + 1));
  for (int i = 0; i < 3; i++) {
    sendLine(String("SLOT,") + (i + 1) + ",CUR," + currentAngles[i] + ",LOCK," +
             lockAngles[i] + ",UNLOCK," + unlockAngles[i]);
  }
}

void sendCalibrationSummary() {
  sendLine(String("CFG,LOCK,") + lockAngles[0] + "," + lockAngles[1] + "," +
           lockAngles[2] + ",UNLOCK," + unlockAngles[0] + "," +
           unlockAngles[1] + "," + unlockAngles[2]);
  sendLine(String("MAIN_FW,constexpr int kDefaultLockAngles[3] = {") +
           lockAngles[0] + ", " + lockAngles[1] + ", " + lockAngles[2] +
           "};");
  sendLine(String("MAIN_FW,constexpr int kDefaultUnlockAngles[3] = {") +
           unlockAngles[0] + ", " + unlockAngles[1] + ", " + unlockAngles[2] +
           "};");
}

void printHelp() {
  sendLine("READY,SERVO_ANGLE_CALIBRATION");
  sendLine("CMDS,HELP,PING,STATUS,PRINTCFG");
  sendLine("CMDS,SLOT,slot,ANGLE,deg,NUDGE,delta");
  sendLine("CMDS,MOVE,slot,deg,LOCK,slot,UNLOCK,slot");
  sendLine("CMDS,SAVELOCK,slot?,SAVEUNLOCK,slot?,RESETCFG");
  sendLine("CMDS,TEST,slot?,delayMs?");
  sendLine("NOTE,slot? means optional; default is selected slot");
}

int resolveSlotFromOptionalToken(const String *parts, int count, int tokenIndex,
                                 bool &ok) {
  ok = true;
  if (count <= tokenIndex) {
    return selectedSlotIndex;
  }

  int slotIndex = 0;
  if (!parseSlotToken(parts[tokenIndex], slotIndex)) {
    ok = false;
    return selectedSlotIndex;
  }
  return slotIndex;
}

void handleTest(const String *parts, int count) {
  bool ok = false;
  const int slotIndex = resolveSlotFromOptionalToken(parts, count, 1, ok);
  if (!ok) {
    sendError("BAD_FORMAT");
    return;
  }

  uint32_t delayMs = kDefaultTestDelayMs;
  if (count >= 3) {
    int parsedDelay = 0;
    if (!parsePositiveInt(parts[2], parsedDelay)) {
      sendError("BAD_FORMAT");
      return;
    }
    delayMs = static_cast<uint32_t>(parsedDelay);
  }
  delayMs = constrain(delayMs, kMinTestDelayMs, kMaxTestDelayMs);

  writeServo(slotIndex, unlockAngles[slotIndex]);
  delay(delayMs);
  writeServo(slotIndex, lockAngles[slotIndex]);
  sendLine("OK");
}

void handleCommand(const String &rawLine) {
  String line = rawLine;
  line.trim();
  if (line.isEmpty()) {
    return;
  }

  String parts[5];
  int count = 0;
  if (!splitCsv(line, parts, 5, count)) {
    sendError("BAD_FORMAT");
    return;
  }

  String command = parts[0];
  command.toUpperCase();

  if (command == "HELP") {
    printHelp();
    return;
  }
  if (command == "PING") {
    sendLine("PONG");
    return;
  }
  if (command == "STATUS") {
    sendStatus();
    return;
  }
  if (command == "PRINTCFG") {
    sendCalibrationSummary();
    return;
  }
  if (command == "SLOT" && count == 2) {
    int slotIndex = 0;
    if (!parseSlotToken(parts[1], slotIndex)) {
      sendError("BAD_FORMAT");
      return;
    }
    selectedSlotIndex = slotIndex;
    sendLine(String("OK,SLOT,") + (selectedSlotIndex + 1));
    return;
  }
  if (command == "ANGLE" && count == 2) {
    int angle = 0;
    if (!parseAngleToken(parts[1], angle)) {
      sendError("BAD_FORMAT");
      return;
    }
    moveSelectedServoTo(angle);
    sendLine(String("OK,SLOT,") + (selectedSlotIndex + 1) + ",ANGLE," +
             currentAngles[selectedSlotIndex]);
    return;
  }
  if (command == "NUDGE" && count == 2) {
    int delta = 0;
    if (!parseSignedInt(parts[1], delta)) {
      sendError("BAD_FORMAT");
      return;
    }
    moveSelectedServoTo(currentAngles[selectedSlotIndex] + delta);
    sendLine(String("OK,SLOT,") + (selectedSlotIndex + 1) + ",ANGLE," +
             currentAngles[selectedSlotIndex]);
    return;
  }
  if (command == "MOVE" && count == 3) {
    int slotIndex = 0;
    int angle = 0;
    if (!parseSlotToken(parts[1], slotIndex) || !parseAngleToken(parts[2], angle)) {
      sendError("BAD_FORMAT");
      return;
    }
    selectedSlotIndex = slotIndex;
    writeServo(slotIndex, angle);
    sendLine(String("OK,SLOT,") + (selectedSlotIndex + 1) + ",ANGLE," +
             currentAngles[selectedSlotIndex]);
    return;
  }
  if (command == "LOCK") {
    bool ok = false;
    const int slotIndex = resolveSlotFromOptionalToken(parts, count, 1, ok);
    if (!ok) {
      sendError("BAD_FORMAT");
      return;
    }
    selectedSlotIndex = slotIndex;
    writeServo(slotIndex, lockAngles[slotIndex]);
    sendLine("OK");
    return;
  }
  if (command == "UNLOCK") {
    bool ok = false;
    const int slotIndex = resolveSlotFromOptionalToken(parts, count, 1, ok);
    if (!ok) {
      sendError("BAD_FORMAT");
      return;
    }
    selectedSlotIndex = slotIndex;
    writeServo(slotIndex, unlockAngles[slotIndex]);
    sendLine("OK");
    return;
  }
  if (command == "SAVELOCK") {
    bool ok = false;
    const int slotIndex = resolveSlotFromOptionalToken(parts, count, 1, ok);
    if (!ok) {
      sendError("BAD_FORMAT");
      return;
    }
    lockAngles[slotIndex] = currentAngles[slotIndex];
    saveCalibration();
    sendLine(String("OK,LOCK,") + (slotIndex + 1) + "," + lockAngles[slotIndex]);
    return;
  }
  if (command == "SAVEUNLOCK") {
    bool ok = false;
    const int slotIndex = resolveSlotFromOptionalToken(parts, count, 1, ok);
    if (!ok) {
      sendError("BAD_FORMAT");
      return;
    }
    unlockAngles[slotIndex] = currentAngles[slotIndex];
    saveCalibration();
    sendLine(String("OK,UNLOCK,") + (slotIndex + 1) + "," +
             unlockAngles[slotIndex]);
    return;
  }
  if (command == "RESETCFG") {
    for (int i = 0; i < 3; i++) {
      lockAngles[i] = kDefaultLockAngles[i];
      unlockAngles[i] = kDefaultUnlockAngles[i];
      writeServo(i, lockAngles[i]);
    }
    selectedSlotIndex = 0;
    saveCalibration();
    sendLine("OK,RESETCFG");
    sendCalibrationSummary();
    return;
  }
  if (command == "TEST") {
    handleTest(parts, count);
    return;
  }

  sendError("BAD_FORMAT");
}

void readBufferFromStream(Stream &stream, String &buffer) {
  while (stream.available()) {
    const char incoming = static_cast<char>(stream.read());
    if (incoming == '\r') {
      continue;
    }

    if (incoming == '\n') {
      if (!buffer.isEmpty()) {
        handleCommand(buffer);
        buffer = "";
      }
      continue;
    }

    if (buffer.length() >= kMaxInboundLineLength) {
      buffer = "";
      sendError("BAD_FORMAT");
      continue;
    }

    buffer += incoming;
  }
}

void setup() {
  Serial.begin(115200);
  delay(250);

  preferences.begin("servo_calib", false);
  loadCalibration();

  for (int i = 0; i < 3; i++) {
    servos[i].setPeriodHertz(50);
    servos[i].attach(kServoPins[i], 500, 2400);
    writeServo(i, kDefaultStartAngle);
  }

  serialBt.begin(kDeviceName);
  printHelp();
  sendStatus();
}

void loop() {
  readBufferFromStream(Serial, serialBuffer);
  readBufferFromStream(serialBt, btBuffer);
}

