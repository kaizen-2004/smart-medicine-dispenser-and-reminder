#include <Arduino.h>
#include <BluetoothSerial.h>
#include <RTClib.h>
#include <Wire.h>

#if !defined(CONFIG_BT_ENABLED) || !defined(CONFIG_BLUEDROID_ENABLED)
#error Bluetooth is not enabled. Please enable it in menuconfig.
#endif

namespace {
constexpr const char *kDeviceName = "SMR-RTC-Test";
constexpr size_t kMaxInboundLineLength = 96;
constexpr uint32_t kStreamIntervalMs = 1000;
} // namespace

BluetoothSerial serialBt;
RTC_DS3231 rtc;
String inputBuffer;
bool rtcAvailable = false;
bool streamEnabled = false;
uint32_t lastStreamMs = 0;

void sendLine(const String &line) {
  serialBt.print(line);
  serialBt.print('\n');
  Serial.println(line);
}

void sendError(const char *errorCode) { sendLine(String("ERR,") + errorCode); }

bool parseDigits(const String &token, int digits, int &value) {
  if (static_cast<int>(token.length()) != digits) {
    return false;
  }

  int result = 0;
  for (int i = 0; i < digits; i++) {
    if (!isDigit(token[i])) {
      return false;
    }
    result = (result * 10) + (token[i] - '0');
  }

  value = result;
  return true;
}

bool parseDate(const String &dateValue, int &year, int &month, int &day) {
  if (dateValue.length() != 10 || dateValue[4] != '-' || dateValue[7] != '-') {
    return false;
  }

  if (!parseDigits(dateValue.substring(0, 4), 4, year) ||
      !parseDigits(dateValue.substring(5, 7), 2, month) ||
      !parseDigits(dateValue.substring(8, 10), 2, day)) {
    return false;
  }

  if (month < 1 || month > 12 || day < 1 || day > 31) {
    return false;
  }

  return true;
}

bool parseClock(const String &clockValue, int &hour, int &minute, int &second) {
  if (clockValue.length() != 8 || clockValue[2] != ':' || clockValue[5] != ':') {
    return false;
  }

  if (!parseDigits(clockValue.substring(0, 2), 2, hour) ||
      !parseDigits(clockValue.substring(3, 5), 2, minute) ||
      !parseDigits(clockValue.substring(6, 8), 2, second)) {
    return false;
  }

  if (hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 ||
      second > 59) {
    return false;
  }

  return true;
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

String formatDateTime(const DateTime &dateTime) {
  char buffer[20];
  snprintf(buffer, sizeof(buffer), "%04d-%02d-%02d,%02d:%02d:%02d", dateTime.year(),
           dateTime.month(), dateTime.day(), dateTime.hour(), dateTime.minute(),
           dateTime.second());
  return String(buffer);
}

void sendNow() {
  if (!rtcAvailable) {
    sendError("RTC_NOT_FOUND");
    return;
  }
  sendLine(String("NOW,") + formatDateTime(rtc.now()));
}

void handleSet(const String &line) {
  if (!rtcAvailable) {
    sendError("RTC_NOT_FOUND");
    return;
  }

  String parts[3];
  if (!splitCsvExact(line, parts, 3) || parts[0] != "SET") {
    sendError("BAD_FORMAT");
    return;
  }

  int year = 0;
  int month = 0;
  int day = 0;
  int hour = 0;
  int minute = 0;
  int second = 0;

  if (!parseDate(parts[1], year, month, day) ||
      !parseClock(parts[2], hour, minute, second)) {
    sendError("BAD_FORMAT");
    return;
  }

  rtc.adjust(DateTime(year, month, day, hour, minute, second));
  sendLine("OK");
  sendNow();
}

void handleCommand(const String &rawLine) {
  String line = rawLine;
  line.trim();
  if (line.isEmpty()) {
    return;
  }

  if (line == "HELP") {
    sendLine("CMDS,HELP,PING,NOW,LOST,SET,YYYY-MM-DD,HH:MM:SS,STREAM,ON/OFF");
    return;
  }

  if (line == "PING") {
    sendLine("OK");
    return;
  }

  if (line == "NOW") {
    sendNow();
    return;
  }

  if (line == "LOST") {
    if (!rtcAvailable) {
      sendError("RTC_NOT_FOUND");
      return;
    }
    sendLine(String("LOST,") + (rtc.lostPower() ? "1" : "0"));
    return;
  }

  if (line == "STREAM,ON") {
    streamEnabled = true;
    sendLine("OK");
    return;
  }

  if (line == "STREAM,OFF") {
    streamEnabled = false;
    sendLine("OK");
    return;
  }

  if (line.startsWith("SET,")) {
    handleSet(line);
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

  Wire.begin();
  rtcAvailable = rtc.begin();

  serialBt.begin(kDeviceName);

  Serial.println("RTC Bluetooth test ready");
  sendLine("READY,RTC_TEST");
  sendLine(String("RTC,") + (rtcAvailable ? "FOUND" : "NOT_FOUND"));
}

void loop() {
  readBluetoothInput();

  const uint32_t nowMs = millis();
  if (streamEnabled && (nowMs - lastStreamMs) >= kStreamIntervalMs) {
    lastStreamMs = nowMs;
    sendNow();
  }
}
