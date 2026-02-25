#include <Arduino.h>
#include <BluetoothSerial.h>
#include <ESP32Servo.h>
#include <LiquidCrystal_I2C.h>
#include <Preferences.h>
#include <RTClib.h>
#include <Wire.h>

#if !defined(CONFIG_BT_ENABLED) || !defined(CONFIG_BLUEDROID_ENABLED)
#error Bluetooth is not enabled. Please enable it in menuconfig.
#endif

namespace {
constexpr const char *kDeviceName = "Smart-Medicine-Reminder";
constexpr uint8_t kServoPins[3] = {25, 26, 27};
constexpr uint8_t kBuzzerPin = 14;
constexpr uint8_t kAckButtonPin = 32;
constexpr uint8_t kRefillButtonPin = 33;
constexpr int kDefaultLockAngles[3] = {45, 45, 45};
constexpr int kDefaultUnlockAngles[3] = {160, 160, 160};
constexpr int kDefaultScheduleMinutes[3] = {8 * 60, 13 * 60, 20 * 60};
constexpr size_t kMaxInboundLineLength = 128;
constexpr uint8_t kLcdI2cAddress =
    0x27; // Common LCD backpack address (use 0x3F if needed).
constexpr uint32_t kDisplayRefreshMs = 1000;
constexpr uint32_t kLcdRecoverIntervalMs = 30000;
constexpr uint32_t kI2cClockHz = 50000;
constexpr uint32_t kButtonDebounceMs = 35;
constexpr uint32_t kRefillLongPressMs = 2000;
constexpr bool kUsePassiveBuzzer = true;
constexpr uint16_t kPassiveBuzzerFrequencyHz = 4000;
constexpr uint32_t kBuzzerPatternOnMs = 180;
constexpr uint32_t kBuzzerPatternOffMs = 220;
constexpr bool kEnableSerialDebug = true;
} // namespace

BluetoothSerial serialBt;
Preferences preferences;
RTC_DS3231 rtc;
Servo servos[3];
LiquidCrystal_I2C lcd(kLcdI2cAddress, 16, 2);

int scheduleMinutes[3] = {
    kDefaultScheduleMinutes[0],
    kDefaultScheduleMinutes[1],
    kDefaultScheduleMinutes[2],
};
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
bool triggeredToday[3] = {false, false, false};
bool dueActive[3] = {false, false, false};
bool compartmentOpen[3] = {false, false, false};
bool refillMode = false;
bool buzzerOn = false;
bool buzzerAlertRequested = false;
bool buzzerPatternOnPhase = false;
uint32_t buzzerPatternTickMs = 0;
bool scheduleConfigured = false;
bool rtcAvailable = false;
bool rtcConfigured = false;
int lastDateKey = -1;
uint32_t lastSchedulerTickMs = 0;
uint32_t lastDisplayTickMs = 0;
uint32_t lastLcdRecoverMs = 0;
String inputBuffer;
bool lastBtClientState = false;
String lastLcdLines[2] = {"", ""};

struct ButtonState {
  uint8_t pin;
  bool rawPressed;
  bool stablePressed;
  uint32_t lastRawChangeMs;
  uint32_t pressedSinceMs;
  bool longPressHandled;
};

ButtonState ackButton = {kAckButtonPin, false, false, 0, 0, false};
ButtonState refillButton = {kRefillButtonPin, false, false, 0, 0, false};

void debugLog(const String &line) {
  if (!kEnableSerialDebug) {
    return;
  }
  Serial.println(line);
}

void sendLine(const String &line) {
  serialBt.print(line);
  serialBt.print('\n');
  debugLog(String("BT_TX,") + line);
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

bool parseHHMM(const String &value, int &minutesFromMidnight) {
  if (value.length() != 5 || value[2] != ':') {
    return false;
  }

  int hour = 0;
  int minute = 0;
  if (!parseDigits(value.substring(0, 2), 2, hour) ||
      !parseDigits(value.substring(3, 5), 2, minute)) {
    return false;
  }

  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
    return false;
  }

  minutesFromMidnight = (hour * 60) + minute;
  return true;
}

String formatHHMM(int minutesFromMidnight) {
  const int hour = minutesFromMidnight / 60;
  const int minute = minutesFromMidnight % 60;
  char buffer[6];
  snprintf(buffer, sizeof(buffer), "%02d:%02d", hour, minute);
  return String(buffer);
}

String formatHHMMSS(const DateTime &dateTime) {
  char buffer[9];
  snprintf(buffer, sizeof(buffer), "%02d:%02d:%02d", dateTime.hour(),
           dateTime.minute(), dateTime.second());
  return String(buffer);
}

String formatTimeAmPm(int minutesFromMidnight) {
  const int hour24 = (minutesFromMidnight / 60) % 24;
  const int minute = minutesFromMidnight % 60;
  const bool pm = hour24 >= 12;
  int hour12 = hour24 % 12;
  if (hour12 == 0) {
    hour12 = 12;
  }

  char buffer[10];
  snprintf(buffer, sizeof(buffer), "%d:%02d%s", hour12, minute,
           pm ? "PM" : "AM");
  return String(buffer);
}

String toLcdLine(const String &value) {
  if (value.length() >= 16) {
    return value.substring(0, 16);
  }

  String padded = value;
  while (padded.length() < 16) {
    padded += ' ';
  }
  return padded;
}

void lcdPrintLine(uint8_t row, const String &value) {
  if (row > 1) {
    return;
  }
  const String formatted = toLcdLine(value);
  if (lastLcdLines[row] == formatted) {
    return;
  }
  lcd.setCursor(0, row);
  lcd.print(formatted);
  lastLcdLines[row] = formatted;
}

void invalidateLcdCache() {
  lastLcdLines[0] = "";
  lastLcdLines[1] = "";
}

void initLcd() {
  lcd.init();
  lcd.backlight();
  invalidateLcdCache();
}

int nextSlotIndexFor(const DateTime &now) {
  const int minutesNow = (now.hour() * 60) + now.minute();
  int chosenIndex = 0;
  int smallestDelta = (24 * 60) + 1;

  for (int i = 0; i < 3; i++) {
    int delta = scheduleMinutes[i] - minutesNow;
    if (delta < 0 || (delta == 0 && now.second() > 0)) {
      delta += (24 * 60);
    }
    if (delta < smallestDelta) {
      smallestDelta = delta;
      chosenIndex = i;
    }
  }

  return chosenIndex;
}

int dueActiveCount() {
  int count = 0;
  for (int i = 0; i < 3; i++) {
    if (dueActive[i]) {
      count++;
    }
  }
  return count;
}

int firstDueActiveIndex() {
  for (int i = 0; i < 3; i++) {
    if (dueActive[i]) {
      return i;
    }
  }
  return -1;
}

void updateDisplay() {
  if (refillMode) {
    lcdPrintLine(0, "Refill Mode ON");
    lcdPrintLine(1, "Hold B to close");
    return;
  }

  if (!rtcAvailable || !rtcConfigured) {
    lcdPrintLine(0, "Clock not ready");
    lcdPrintLine(1, "Call caregiver");
    return;
  }

  if (!scheduleConfigured) {
    lcdPrintLine(0, "Set times in app");
    lcdPrintLine(1, "Ask for help");
    return;
  }

  const int dueCount = dueActiveCount();
  if (dueCount > 1) {
    lcdPrintLine(0, "Time for meds");
    lcdPrintLine(1, "Press A to close");
    return;
  }
  if (dueCount == 1) {
    const int dueIndex = firstDueActiveIndex();
    lcdPrintLine(0, "Time for Med " + String(dueIndex + 1));
    lcdPrintLine(1, "Press A to close");
    return;
  }

  const DateTime now = rtc.now();
  const int nextIndex = nextSlotIndexFor(now);

  lcdPrintLine(0, "Time " + formatHHMMSS(now));
  lcdPrintLine(1, "Next M" + String(nextIndex + 1) + " " +
                     formatTimeAmPm(scheduleMinutes[nextIndex]));
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

bool parseSlot(const String &token, int &slot) {
  if (token.length() != 1 || token[0] < '1' || token[0] > '3') {
    return false;
  }
  slot = token[0] - '0';
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

void saveScheduleToNvs() {
  preferences.putInt("med1", scheduleMinutes[0]);
  preferences.putInt("med2", scheduleMinutes[1]);
  preferences.putInt("med3", scheduleMinutes[2]);
}

void loadScheduleFromNvs() {
  scheduleMinutes[0] = preferences.getInt("med1", kDefaultScheduleMinutes[0]);
  scheduleMinutes[1] = preferences.getInt("med2", kDefaultScheduleMinutes[1]);
  scheduleMinutes[2] = preferences.getInt("med3", kDefaultScheduleMinutes[2]);
  scheduleConfigured = preferences.getBool("sched_set", false);
  rtcConfigured = preferences.getBool("rtc_set", false);
}

void setRtcConfigured(bool configured) {
  rtcConfigured = configured;
  preferences.putBool("rtc_set", configured);
}

void setScheduleConfigured(bool configured) {
  scheduleConfigured = configured;
  preferences.putBool("sched_set", configured);
}

String bitFlag(bool value) { return value ? "1" : "0"; }

void sendEvent(const String &eventType, uint8_t mask = 0) {
  if (eventType == "TAKEN" || eventType == "DUE") {
    sendLine(String("EVT,") + eventType + "," + bitFlag((mask & 0x01) != 0) +
             "," + bitFlag((mask & 0x02) != 0) + "," +
             bitFlag((mask & 0x04) != 0));
    return;
  }

  sendLine(String("EVT,") + eventType);
}

uint8_t dueMask() {
  uint8_t mask = 0;
  for (int i = 0; i < 3; i++) {
    if (dueActive[i]) {
      mask |= (1u << i);
    }
  }
  return mask;
}

bool hasAnyDueActive() { return dueMask() != 0; }

void setBuzzer(bool enabled) {
  if (kUsePassiveBuzzer) {
    if (enabled) {
      tone(kBuzzerPin, kPassiveBuzzerFrequencyHz);
    } else {
      noTone(kBuzzerPin);
    }
  } else {
    digitalWrite(kBuzzerPin, enabled ? HIGH : LOW);
  }
  buzzerOn = enabled;
}

void updateBuzzerState() {
  const bool shouldAlert = hasAnyDueActive() && !refillMode;
  if (!shouldAlert) {
    buzzerAlertRequested = false;
    buzzerPatternOnPhase = false;
    setBuzzer(false);
    return;
  }

  if (!buzzerAlertRequested) {
    buzzerAlertRequested = true;
    buzzerPatternOnPhase = true;
    buzzerPatternTickMs = millis();
    setBuzzer(true);
  }
}

void serviceBuzzerPattern() {
  if (!buzzerAlertRequested) {
    return;
  }

  const uint32_t nowMs = millis();
  const uint32_t phaseDuration =
      buzzerPatternOnPhase ? kBuzzerPatternOnMs : kBuzzerPatternOffMs;
  if ((nowMs - buzzerPatternTickMs) < phaseDuration) {
    return;
  }

  buzzerPatternTickMs = nowMs;
  buzzerPatternOnPhase = !buzzerPatternOnPhase;
  setBuzzer(buzzerPatternOnPhase);
}

void clearDueState(int index) {
  if (index < 0 || index > 2) {
    return;
  }
  dueActive[index] = false;
}

void clearAllDueState() {
  for (int i = 0; i < 3; i++) {
    dueActive[i] = false;
  }
}

void lockAllCompartments() {
  for (int i = 0; i < 3; i++) {
    servos[i].write(lockAngles[i]);
    compartmentOpen[i] = false;
  }
}

void openCompartment(int index) {
  if (index < 0 || index > 2) {
    return;
  }

  servos[index].write(unlockAngles[index]);
  compartmentOpen[index] = true;
}

void closeCompartment(int index) {
  if (index < 0 || index > 2) {
    return;
  }

  servos[index].write(lockAngles[index]);
  compartmentOpen[index] = false;
}

void openAllCompartments() {
  for (int i = 0; i < 3; i++) {
    openCompartment(i);
  }
}

void closeAllCompartments() {
  for (int i = 0; i < 3; i++) {
    closeCompartment(i);
  }
}

void acknowledgeDueFromButton() {
  // Button A: acknowledge currently due medicines only, but close all slots.
  const uint8_t mask = dueMask();
  closeAllCompartments();
  clearAllDueState();
  updateBuzzerState();
  sendEvent("TAKEN", mask);
}

void toggleRefillMode() {
  if (!refillMode) {
    refillMode = true;
    clearAllDueState();
    setBuzzer(false);
    openAllCompartments();
    sendEvent("REFILL,ON");
    debugLog("REFILL_MODE,ON");
    return;
  }

  refillMode = false;
  closeAllCompartments();
  clearAllDueState();
  updateBuzzerState();
  sendEvent("REFILL,OFF");
  debugLog("REFILL_MODE,OFF");
}

void initButtonState(ButtonState &state) {
  pinMode(state.pin, INPUT_PULLUP);
  const bool pressed = (digitalRead(state.pin) == LOW);
  state.rawPressed = pressed;
  state.stablePressed = pressed;
  state.lastRawChangeMs = millis();
  state.pressedSinceMs = 0;
  state.longPressHandled = false;
}

void serviceButtons() {
  const uint32_t nowMs = millis();
  ButtonState *buttons[2] = {&ackButton, &refillButton};
  for (int i = 0; i < 2; i++) {
    ButtonState &button = *buttons[i];
    const bool rawPressed = (digitalRead(button.pin) == LOW);
    if (rawPressed != button.rawPressed) {
      button.rawPressed = rawPressed;
      button.lastRawChangeMs = nowMs;
    }

    if ((nowMs - button.lastRawChangeMs) < kButtonDebounceMs) {
      continue;
    }

    if (button.stablePressed != button.rawPressed) {
      button.stablePressed = button.rawPressed;
      if (button.stablePressed) {
        button.pressedSinceMs = nowMs;
        button.longPressHandled = false;
        if (button.pin == kAckButtonPin && !refillMode) {
          acknowledgeDueFromButton();
        }
      } else {
        button.pressedSinceMs = 0;
        button.longPressHandled = false;
      }
    }
  }

  if (refillButton.stablePressed && !refillButton.longPressHandled &&
      (nowMs - refillButton.pressedSinceMs) >= kRefillLongPressMs) {
    refillButton.longPressHandled = true;
    toggleRefillMode();
  }
}

void sendCurrentSchedule() {
  sendLine(String("SCHED,1,") + formatHHMM(scheduleMinutes[0]) + ",2," +
           formatHHMM(scheduleMinutes[1]) + ",3," +
           formatHHMM(scheduleMinutes[2]));
}

void handleGetCommand() { sendCurrentSchedule(); }

void handleSyncCommand(const String &line) {
  String parts[4];
  if (!splitCsvExact(line, parts, 4) || parts[0] != "SYNC") {
    sendError("BAD_FORMAT");
    return;
  }

  int parsedMinutes[3];
  if (!parseHHMM(parts[1], parsedMinutes[0]) ||
      !parseHHMM(parts[2], parsedMinutes[1]) ||
      !parseHHMM(parts[3], parsedMinutes[2])) {
    sendError("BAD_FORMAT");
    return;
  }

  for (int i = 0; i < 3; i++) {
    scheduleMinutes[i] = parsedMinutes[i];
  }
  saveScheduleToNvs();
  setScheduleConfigured(true);
  sendLine("OK,SYNC");
}

void handleSetCommand(const String &line) {
  String parts[3];
  if (!splitCsvExact(line, parts, 3) || parts[0] != "SET") {
    sendError("BAD_FORMAT");
    return;
  }

  int slot = 0;
  if (!parseSlot(parts[1], slot)) {
    sendError("BAD_FORMAT");
    return;
  }

  int parsedMinutes = 0;
  if (!parseHHMM(parts[2], parsedMinutes)) {
    sendError("BAD_FORMAT");
    return;
  }

  scheduleMinutes[slot - 1] = parsedMinutes;
  saveScheduleToNvs();
  setScheduleConfigured(true);
  sendLine("OK,SET");
}

void handleTimeCommand(const String &line) {
  if (!rtcAvailable) {
    sendError("RTC_NOT_SET");
    return;
  }

  String parts[3];
  if (!splitCsvExact(line, parts, 3) || parts[0] != "TIME") {
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
  setRtcConfigured(true);
  sendLine("OK,TIME");
}

void handleTestCommand(const String &line) {
  String parts[2];
  if (!splitCsvExact(line, parts, 2) || parts[0] != "TEST") {
    sendError("BAD_FORMAT");
    return;
  }

  int slot = 0;
  if (!parseSlot(parts[1], slot)) {
    sendError("BAD_FORMAT");
    return;
  }

  openCompartment(slot - 1);
  sendLine("OK,TEST");
}

void handleAcknowledgeCommand(const String &line) {
  String parts[2];
  if (!splitCsvExact(line, parts, 2) || parts[0] != "ACK") {
    sendError("BAD_FORMAT");
    return;
  }

  int slot = 0;
  if (!parseSlot(parts[1], slot)) {
    sendError("BAD_FORMAT");
    return;
  }

  closeCompartment(slot - 1);
  clearDueState(slot - 1);
  updateBuzzerState();
  sendLine("OK,ACK");
}

void processCommand(const String &rawLine) {
  String line = rawLine;
  line.trim();
  if (line.isEmpty()) {
    return;
  }
  debugLog(String("BT_RX,") + line);

  if (line == "GET") {
    handleGetCommand();
    return;
  }
  if (line.startsWith("SYNC,")) {
    handleSyncCommand(line);
    return;
  }
  if (line.startsWith("SET,")) {
    handleSetCommand(line);
    return;
  }
  if (line.startsWith("TIME,")) {
    handleTimeCommand(line);
    return;
  }
  if (line.startsWith("TEST,")) {
    handleTestCommand(line);
    return;
  }
  if (line.startsWith("ACK,")) {
    handleAcknowledgeCommand(line);
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
      if (inputBuffer.length() > 0) {
        processCommand(inputBuffer);
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

void resetDailyTriggerFlags() {
  for (int i = 0; i < 3; i++) {
    triggeredToday[i] = false;
  }
  clearAllDueState();
  updateBuzzerState();
}

int dateKeyFor(const DateTime &dateTime) {
  return (dateTime.year() * 10000) + (dateTime.month() * 100) + dateTime.day();
}

void schedulerTick() {
  if (!rtcAvailable || !rtcConfigured) {
    return;
  }

  const DateTime now = rtc.now();
  const int todayKey = dateKeyFor(now);
  if (todayKey != lastDateKey) {
    lastDateKey = todayKey;
    resetDailyTriggerFlags();
  }

  if (refillMode) {
    return;
  }

  const int minutesNow = (now.hour() * 60) + now.minute();
  uint8_t newlyDueMask = 0;
  for (int i = 0; i < 3; i++) {
    if (triggeredToday[i]) {
      continue;
    }
    if (scheduleMinutes[i] == minutesNow) {
      triggeredToday[i] = true;
      dueActive[i] = true;
      openCompartment(i);
      newlyDueMask |= (1u << i);
    }
  }

  if (newlyDueMask != 0) {
    updateBuzzerState();
    sendEvent("DUE", newlyDueMask);
  }
}

void setup() {
  Serial.begin(115200);
  delay(200);

  Wire.begin();
  Wire.setClock(kI2cClockHz);
  Wire.setTimeOut(50);

  initLcd();
  lcdPrintLine(0, "Medicine Box");
  lcdPrintLine(1, "Starting...");

  preferences.begin("smr", false);
  loadScheduleFromNvs();

  rtcAvailable = rtc.begin();
  if (rtcAvailable && rtc.lostPower()) {
    setRtcConfigured(false);
  }

  for (int i = 0; i < 3; i++) {
    servos[i].setPeriodHertz(50);
    servos[i].attach(kServoPins[i], 500, 2400);
  }
  lockAllCompartments();
  pinMode(kBuzzerPin, OUTPUT);
  if (kUsePassiveBuzzer) {
    noTone(kBuzzerPin);
  }
  setBuzzer(false);
  initButtonState(ackButton);
  initButtonState(refillButton);

  serialBt.begin(kDeviceName);
  updateDisplay();
  debugLog("Smart Medicine Reminder started");
}

void loop() {
  serviceButtons();
  serviceBuzzerPattern();
  readBluetoothInput();

  const bool btClientState = serialBt.hasClient();
  if (btClientState != lastBtClientState) {
    lastBtClientState = btClientState;
    debugLog(String("BT_CLIENT,") + (btClientState ? "1" : "0"));
  }

  const uint32_t nowMs = millis();
  if ((nowMs - lastDisplayTickMs) >= kDisplayRefreshMs) {
    lastDisplayTickMs = nowMs;
    updateDisplay();
  }

  if ((nowMs - lastLcdRecoverMs) >= kLcdRecoverIntervalMs) {
    lastLcdRecoverMs = nowMs;
    initLcd();
    updateDisplay();
    debugLog("LCD_RECOVER");
  }

  if ((nowMs - lastSchedulerTickMs) >= 200) {
    lastSchedulerTickMs = nowMs;
    schedulerTick();
  }
}
