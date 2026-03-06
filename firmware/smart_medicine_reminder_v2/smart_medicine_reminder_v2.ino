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
constexpr uint8_t kModeDaily = 0;
constexpr uint8_t kModeOneTime = 1;
constexpr int kDefaultLockAngles[3] = {45, 45, 45};
constexpr int kDefaultUnlockAngles[3] = {160, 160, 160};
constexpr int kDefaultScheduleMinutes[3] = {8 * 60, 13 * 60, 20 * 60};
constexpr size_t kMaxInboundLineLength = 128;
constexpr uint8_t kLcdI2cAddress =
    0x27; // Common LCD backpack address (use 0x3F if needed).
constexpr uint32_t kDisplayRefreshMs = 1000;
constexpr uint32_t kSchedulerIntervalMs = 100;
constexpr uint32_t kLcdRecoverIntervalMs = 30000;
constexpr int kScheduleLateToleranceSec = 5;
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
uint8_t slotModes[3] = {kModeDaily, kModeDaily, kModeDaily};
int oneTimeYear[3] = {0, 0, 0};
int oneTimeMonth[3] = {0, 0, 0};
int oneTimeDay[3] = {0, 0, 0};
bool oneTimeConsumed[3] = {false, false, false};
int dailyTakenDateKey[3] = {0, 0, 0};
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
int lastSecondOfDay = -1;
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

String formatDateYMD(int year, int month, int day) {
  char buffer[11];
  snprintf(buffer, sizeof(buffer), "%04d-%02d-%02d", year, month, day);
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

bool hasValidOneTimeDate(int index) {
  return oneTimeYear[index] >= 2000 && oneTimeMonth[index] >= 1 &&
         oneTimeMonth[index] <= 12 && oneTimeDay[index] >= 1 &&
         oneTimeDay[index] <= 31;
}

DateTime slotNextDateTime(int index, const DateTime &now) {
  if (slotModes[index] == kModeOneTime) {
    if (!hasValidOneTimeDate(index) || oneTimeConsumed[index]) {
      return DateTime(2099, 12, 31, 23, 59, 59);
    }
    const DateTime target = DateTime(oneTimeYear[index], oneTimeMonth[index],
                                     oneTimeDay[index],
                                     scheduleMinutes[index] / 60,
                                     scheduleMinutes[index] % 60, 0);
    if (target.unixtime() <= now.unixtime()) {
      return DateTime(2099, 12, 31, 23, 59, 59);
    }
    return target;
  }

  DateTime scheduled = DateTime(now.year(), now.month(), now.day(),
                                scheduleMinutes[index] / 60,
                                scheduleMinutes[index] % 60, 0);
  if (scheduled.unixtime() <= now.unixtime()) {
    scheduled = scheduled + TimeSpan(1, 0, 0, 0);
  }
  return scheduled;
}

int nextSlotIndexFor(const DateTime &now) {
  int chosenIndex = 0;
  DateTime chosenDateTime = DateTime(2099, 12, 31, 23, 59, 59);

  for (int i = 0; i < 3; i++) {
    const DateTime candidate = slotNextDateTime(i, now);
    if (candidate.unixtime() < chosenDateTime.unixtime()) {
      chosenDateTime = candidate;
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
  preferences.putUChar("m1_mode", slotModes[0]);
  preferences.putUChar("m2_mode", slotModes[1]);
  preferences.putUChar("m3_mode", slotModes[2]);
  preferences.putInt("m1_y", oneTimeYear[0]);
  preferences.putInt("m1_mo", oneTimeMonth[0]);
  preferences.putInt("m1_d", oneTimeDay[0]);
  preferences.putInt("m2_y", oneTimeYear[1]);
  preferences.putInt("m2_mo", oneTimeMonth[1]);
  preferences.putInt("m2_d", oneTimeDay[1]);
  preferences.putInt("m3_y", oneTimeYear[2]);
  preferences.putInt("m3_mo", oneTimeMonth[2]);
  preferences.putInt("m3_d", oneTimeDay[2]);
  preferences.putBool("m1_done", oneTimeConsumed[0]);
  preferences.putBool("m2_done", oneTimeConsumed[1]);
  preferences.putBool("m3_done", oneTimeConsumed[2]);
  preferences.putInt("m1_tk", dailyTakenDateKey[0]);
  preferences.putInt("m2_tk", dailyTakenDateKey[1]);
  preferences.putInt("m3_tk", dailyTakenDateKey[2]);
}

void loadScheduleFromNvs() {
  scheduleMinutes[0] = preferences.getInt("med1", kDefaultScheduleMinutes[0]);
  scheduleMinutes[1] = preferences.getInt("med2", kDefaultScheduleMinutes[1]);
  scheduleMinutes[2] = preferences.getInt("med3", kDefaultScheduleMinutes[2]);
  slotModes[0] = preferences.getUChar("m1_mode", kModeDaily);
  slotModes[1] = preferences.getUChar("m2_mode", kModeDaily);
  slotModes[2] = preferences.getUChar("m3_mode", kModeDaily);
  for (int i = 0; i < 3; i++) {
    if (slotModes[i] != kModeDaily && slotModes[i] != kModeOneTime) {
      slotModes[i] = kModeDaily;
    }
  }
  oneTimeYear[0] = preferences.getInt("m1_y", 0);
  oneTimeMonth[0] = preferences.getInt("m1_mo", 0);
  oneTimeDay[0] = preferences.getInt("m1_d", 0);
  oneTimeYear[1] = preferences.getInt("m2_y", 0);
  oneTimeMonth[1] = preferences.getInt("m2_mo", 0);
  oneTimeDay[1] = preferences.getInt("m2_d", 0);
  oneTimeYear[2] = preferences.getInt("m3_y", 0);
  oneTimeMonth[2] = preferences.getInt("m3_mo", 0);
  oneTimeDay[2] = preferences.getInt("m3_d", 0);
  oneTimeConsumed[0] = preferences.getBool("m1_done", false);
  oneTimeConsumed[1] = preferences.getBool("m2_done", false);
  oneTimeConsumed[2] = preferences.getBool("m3_done", false);
  dailyTakenDateKey[0] = preferences.getInt("m1_tk", 0);
  dailyTakenDateKey[1] = preferences.getInt("m2_tk", 0);
  dailyTakenDateKey[2] = preferences.getInt("m3_tk", 0);
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
  bool updatedTakenState = false;
  if (rtcAvailable && rtcConfigured) {
    DateTime now = rtc.now();
    int todayKey =
        (now.year() * 10000) + (now.month() * 100) + now.day();
    for (int i = 0; i < 3; i++) {
      if (dueActive[i] && slotModes[i] == kModeDaily) {
        dailyTakenDateKey[i] = todayKey;
        updatedTakenState = true;
      }
    }
  }
  closeAllCompartments();
  clearAllDueState();
  updateBuzzerState();
  if (updatedTakenState) {
    saveScheduleToNvs();
  }
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

String slotDescriptor(int index) {
  if (slotModes[index] == kModeOneTime && hasValidOneTimeDate(index)) {
    return String("O@") +
           formatDateYMD(oneTimeYear[index], oneTimeMonth[index],
                         oneTimeDay[index]) +
           "@" + formatHHMM(scheduleMinutes[index]);
  }
  return String("D@") + formatHHMM(scheduleMinutes[index]);
}

void sendCurrentSchedule() {
  sendLine(String("SCHED2,1,") + slotDescriptor(0) + ",2," + slotDescriptor(1) +
           ",3," + slotDescriptor(2));
}

void handleGetCommand() { sendCurrentSchedule(); }

bool parseSyncDescriptor(const String &descriptor, uint8_t &modeOut,
                         int &minutesOut, int &yearOut, int &monthOut,
                         int &dayOut) {
  if (descriptor.startsWith("D@")) {
    int parsedMinutes = 0;
    if (!parseHHMM(descriptor.substring(2), parsedMinutes)) {
      return false;
    }
    modeOut = kModeDaily;
    minutesOut = parsedMinutes;
    yearOut = 0;
    monthOut = 0;
    dayOut = 0;
    return true;
  }

  if (descriptor.startsWith("O@")) {
    const int separator = descriptor.indexOf('@', 2);
    if (separator <= 2 || separator >= static_cast<int>(descriptor.length() - 1)) {
      return false;
    }

    const String datePart = descriptor.substring(2, separator);
    const String timePart = descriptor.substring(separator + 1);
    int parsedYear = 0;
    int parsedMonth = 0;
    int parsedDay = 0;
    int parsedMinutes = 0;
    if (!parseDate(datePart, parsedYear, parsedMonth, parsedDay) ||
        !parseHHMM(timePart, parsedMinutes)) {
      return false;
    }

    modeOut = kModeOneTime;
    minutesOut = parsedMinutes;
    yearOut = parsedYear;
    monthOut = parsedMonth;
    dayOut = parsedDay;
    return true;
  }

  return false;
}

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
    slotModes[i] = kModeDaily;
    oneTimeYear[i] = 0;
    oneTimeMonth[i] = 0;
    oneTimeDay[i] = 0;
    oneTimeConsumed[i] = false;
    dailyTakenDateKey[i] = 0;
  }
  resetDailyTriggerFlags();
  saveScheduleToNvs();
  setScheduleConfigured(true);
  sendLine("OK,SYNC");
}

void handleSync2Command(const String &line) {
  String parts[4];
  if (!splitCsvExact(line, parts, 4) || parts[0] != "SYNC2") {
    sendError("BAD_FORMAT");
    return;
  }

  for (int i = 0; i < 3; i++) {
    uint8_t parsedMode = kModeDaily;
    int parsedMinutes = 0;
    int parsedYear = 0;
    int parsedMonth = 0;
    int parsedDay = 0;
    if (!parseSyncDescriptor(parts[i + 1], parsedMode, parsedMinutes, parsedYear,
                             parsedMonth, parsedDay)) {
      sendError("BAD_FORMAT");
      return;
    }

    slotModes[i] = parsedMode;
    scheduleMinutes[i] = parsedMinutes;
    oneTimeYear[i] = parsedYear;
    oneTimeMonth[i] = parsedMonth;
    oneTimeDay[i] = parsedDay;
    oneTimeConsumed[i] = false;
    dailyTakenDateKey[i] = 0;
  }

  resetDailyTriggerFlags();
  saveScheduleToNvs();
  setScheduleConfigured(true);
  sendLine("OK,SYNC2");
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
  slotModes[slot - 1] = kModeDaily;
  oneTimeYear[slot - 1] = 0;
  oneTimeMonth[slot - 1] = 0;
  oneTimeDay[slot - 1] = 0;
  oneTimeConsumed[slot - 1] = false;
  dailyTakenDateKey[slot - 1] = 0;
  resetDailyTriggerFlags();
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
  lastSecondOfDay = -1;
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
  if (rtcAvailable && rtcConfigured && slotModes[slot - 1] == kModeDaily) {
    DateTime now = rtc.now();
    dailyTakenDateKey[slot - 1] =
        (now.year() * 10000) + (now.month() * 100) + now.day();
    saveScheduleToNvs();
  }
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
  if (line.startsWith("SYNC2,")) {
    handleSync2Command(line);
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
  lastSecondOfDay = -1;
  clearAllDueState();
  updateBuzzerState();
}

int dateKeyFor(const DateTime &dateTime) {
  return (dateTime.year() * 10000) + (dateTime.month() * 100) + dateTime.day();
}

int secondOfDayFor(const DateTime &dateTime) {
  return (dateTime.hour() * 3600) + (dateTime.minute() * 60) + dateTime.second();
}

bool shouldTriggerSlotNow(int scheduleSecondOfDay, int nowSecondOfDay,
                          int previousSecondOfDay) {
  const int latestAllowedSecond =
      scheduleSecondOfDay + kScheduleLateToleranceSec;
  if (nowSecondOfDay < scheduleSecondOfDay ||
      nowSecondOfDay > latestAllowedSecond) {
    return false;
  }

  if (previousSecondOfDay < 0) {
    return true;
  }

  // For same-day checks, trigger only if the schedule second was not already
  // observed before the previous tick.
  return previousSecondOfDay < scheduleSecondOfDay;
}

int dateKeyFromYMD(int year, int month, int day) {
  return (year * 10000) + (month * 100) + day;
}

void schedulerTick() {
  if (!rtcAvailable || !rtcConfigured || !scheduleConfigured) {
    return;
  }

  const DateTime now = rtc.now();
  const int todayKey = dateKeyFor(now);
  const int nowSecondOfDay = secondOfDayFor(now);
  if (todayKey != lastDateKey) {
    lastDateKey = todayKey;
    resetDailyTriggerFlags();
  }

  // If time is synced backward while staying in the same date, do not treat it
  // as a wrap trigger window.
  if (lastSecondOfDay >= 0 && todayKey == lastDateKey &&
      nowSecondOfDay + 2 < lastSecondOfDay) {
    debugLog(String("SCHED_TIME_ROLLBACK,prev=") + lastSecondOfDay + ",now=" +
             nowSecondOfDay);
    lastSecondOfDay = nowSecondOfDay;
    return;
  }

  if (refillMode) {
    lastSecondOfDay = nowSecondOfDay;
    return;
  }

  uint8_t newlyDueMask = 0;
  bool scheduleStateChanged = false;
  for (int i = 0; i < 3; i++) {
    const int scheduleSecondOfDay = scheduleMinutes[i] * 60;

    if (slotModes[i] == kModeOneTime) {
      if (oneTimeConsumed[i] || !hasValidOneTimeDate(i)) {
        continue;
      }

      const int slotDateKey =
          dateKeyFromYMD(oneTimeYear[i], oneTimeMonth[i], oneTimeDay[i]);
      if (todayKey < slotDateKey) {
        continue;
      }
      if (todayKey > slotDateKey) {
        oneTimeConsumed[i] = true;
        scheduleStateChanged = true;
        continue;
      }

      if (nowSecondOfDay >
          (scheduleSecondOfDay + kScheduleLateToleranceSec)) {
        oneTimeConsumed[i] = true;
        scheduleStateChanged = true;
        debugLog(String("SCHED_SKIP_ONCE,slot=") + (i + 1) + ",date=" +
                 formatDateYMD(oneTimeYear[i], oneTimeMonth[i], oneTimeDay[i]) +
                 ",time=" + formatHHMM(scheduleMinutes[i]) + ",now=" +
                 formatHHMMSS(now));
        continue;
      }

      if (!shouldTriggerSlotNow(scheduleSecondOfDay, nowSecondOfDay,
                                lastSecondOfDay)) {
        continue;
      }

      oneTimeConsumed[i] = true;
      dueActive[i] = true;
      openCompartment(i);
      newlyDueMask |= (1u << i);
      scheduleStateChanged = true;
      debugLog(String("SCHED_TRIGGER_ONCE,slot=") + (i + 1) + ",date=" +
               formatDateYMD(oneTimeYear[i], oneTimeMonth[i], oneTimeDay[i]) +
               ",time=" + formatHHMM(scheduleMinutes[i]) + ",now=" +
               formatHHMMSS(now));
      continue;
    }

    if (triggeredToday[i]) {
      continue;
    }

    if (nowSecondOfDay > (scheduleSecondOfDay + kScheduleLateToleranceSec)) {
      // Missed daily dose for today is skipped; no stale open after reboot/sync.
      triggeredToday[i] = true;
      debugLog(String("SCHED_SKIP_DAILY,slot=") + (i + 1) + ",time=" +
               formatHHMM(scheduleMinutes[i]) + ",now=" + formatHHMMSS(now));
      continue;
    }

    if (dailyTakenDateKey[i] == todayKey) {
      continue;
    }

    if (shouldTriggerSlotNow(scheduleSecondOfDay, nowSecondOfDay,
                             lastSecondOfDay)) {
      triggeredToday[i] = true;
      dueActive[i] = true;
      openCompartment(i);
      newlyDueMask |= (1u << i);
      debugLog(String("SCHED_TRIGGER_DAILY,slot=") + (i + 1) + ",time=" +
               formatHHMM(scheduleMinutes[i]) + ",now=" + formatHHMMSS(now));
    }
  }

  lastSecondOfDay = nowSecondOfDay;
  if (scheduleStateChanged) {
    saveScheduleToNvs();
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
  const uint32_t nowMs = millis();
  if ((nowMs - lastSchedulerTickMs) >= kSchedulerIntervalMs) {
    lastSchedulerTickMs = nowMs;
    schedulerTick();
  }

  serviceBuzzerPattern();
  readBluetoothInput();

  const bool btClientState = serialBt.hasClient();
  if (btClientState != lastBtClientState) {
    lastBtClientState = btClientState;
    debugLog(String("BT_CLIENT,") + (btClientState ? "1" : "0"));
  }

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

}
