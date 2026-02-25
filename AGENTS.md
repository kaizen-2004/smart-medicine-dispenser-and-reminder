# AGENTS.md — Smart Medicine Reminder (Offline, Android-only, Bluetooth Classic SPP)

This file instructs an AI agent how to implement this project end-to-end with **minimum friction**:

- **Android-only Flutter app**
- **No Wi‑Fi / no cloud backend**
- **Phone-side notifications**
- **ESP32 autonomously opens the compartment** (RTC + stored schedule)
- **Bluetooth Classic (SPP)** used only for **sync/config**, not continuous operation

---

## 0) North Star (what “done” looks like)

A user can:

1. Power on the pillbox and see it advertised as `Smart-Medicine-Reminder` via Bluetooth.
2. Install the Android app.
3. Connect to `Smart-Medicine-Reminder`, set times for **Medicine 1/2/3**, and tap **SYNC**.
4. Phone shows **local notifications** at those times daily.
5. ESP32 opens the correct compartment at those times without needing Wi‑Fi or an always-on Bluetooth connection.
6. After power loss, schedule persists and the device continues normal operation.

---

## 1) Hard Constraints (do not violate)

- **Android only** (no iOS work).
- **No Wi‑Fi required** (do not add Firebase or internet features).
- **No login/auth** (avoid account systems).
- **Notifications must be phone-side** (device may remain silent).
- **Bluetooth Classic SPP** is preferred over BLE for simplicity.
- Keep the UI close to the provided reference (yellow background, time display, 3 rows with SET + time, SYNC button).

---

## 2) Key Design Decisions

### 2.1 Connectivity

- Use **Bluetooth Classic (SPP / RFCOMM Serial)** between Android and ESP32 for:
  - pairing/connecting
  - sending schedule (3 times)
  - reading schedule back (optional)
  - running test-open (optional)
- Avoid relying on Bluetooth being connected all day; Android background behavior is unpredictable.

**ESP32 reference (BluetoothSerial SPP docs/examples):**

- Arduino-ESP32 Bluetooth API docs: https://docs.espressif.com/projects/arduino-esp32/en/latest/api/bluetooth.html
- Example sketch (SerialToSerialBT): https://github.com/espressif/arduino-esp32/blob/master/libraries/BluetoothSerial/examples/SerialToSerialBT/SerialToSerialBT.ino

### 2.2 Notifications

- Use **Android local notifications** scheduled by the app.
- Recommended Flutter plugin: `flutter_local_notifications` (actively maintained).
  - Pub: https://pub.dev/packages/flutter_local_notifications

### 2.3 Timekeeping + Autonomy

- ESP32 must **open compartments autonomously** based on RTC + stored schedule.
- Use **DS3231 RTC** and store schedule in **NVS/Preferences** on ESP32.
- Provide a command to set RTC from phone once (`TIME,...`) to avoid NTP/Wi‑Fi.

---

## 3) Repo Layout (create if missing)

Create a clean mono-repo structure:

```
/app/                 # Flutter Android app
  /lib/
  /android/
  pubspec.yaml
/firmware/            # ESP32 firmware (Arduino)
/docs/
  description.md      # project plan (already created)
/tools/               # optional scripts, diagrams, test logs
README.md
```

---

## 4) Communication Contract (SPP Protocol)

Use a simple line-based ASCII protocol (easy to debug with any BT terminal).

### 4.1 Commands (App → ESP32)

- `GET\n`
- `SYNC,HH:MM,HH:MM,HH:MM\n` (med1, med2, med3)
- `SET,1,HH:MM\n` / `SET,2,HH:MM\n` / `SET,3,HH:MM\n` (optional)
- `TIME,YYYY-MM-DD,HH:MM:SS\n` (recommended, set RTC)
- `TEST,1\n` / `TEST,2\n` / `TEST,3\n` (optional)

### 4.2 Responses (ESP32 → App)

- `OK\n`
- `SCHED,1,HH:MM,2,HH:MM,3,HH:MM\n`
- `ERR,BAD_FORMAT\n`
- `ERR,RTC_NOT_SET\n`

### 4.3 Robustness rules

- Always end messages with `\n`.
- Reject malformed time strings.
- App should retry once on transient disconnect.
- ESP32 should not crash on unexpected input (ignore unknown commands with `ERR,...`).

---

## 5) Android App Implementation Guidance

### 5.1 Screens

**Screen A — Schedule (main)**

- Title: `MEDICINE REMINDER`
- Current time display (updates every second)
- 3 rows:
  - `SET` button
  - label `Medicine 1/2/3`
  - chosen time `HH:MM`
- Primary button: `SYNC / SAVE TO DEVICE`
- Status text: `Connected to Smart-Medicine-Reminder` / `Not connected` + last sync time

**Screen B — Connect Device**

- Bluetooth status (on/off)
- Scan button
- List discovered devices by name
- Tap to connect

### 5.2 Bluetooth on Android (practical requirements)

- Handle Android 12+ runtime permissions:
  - BLUETOOTH_SCAN / BLUETOOTH_CONNECT
- Provide a friendly fallback:
  - “Pair in Android Settings first” if in-app pairing is flaky.

### 5.3 Local Notifications (phone-side alert)

- Schedule 3 repeating daily notifications.
- Ensure each scheduled notification has a unique ID.
- If the OS requires additional permission (Android 13+ notification permission; exact alarms), show a simple in-app prompt and link to settings when needed.
- Notifications should include:
  - “Medicine 1 time” / “Compartment 1”
  - optionally show the chosen time

### 5.4 Flutter dependency choices

Pick **maintained** packages (check recency before locking).
Candidates for Bluetooth Classic:

- `bluetooth_classic` (serial-focused): https://pub.dev/packages/bluetooth_classic
- `flutter_bluetooth_serial` (classic SPP, widely used): https://pub.dev/packages/flutter_bluetooth_serial
- `spp_connection_plugin` (includes background service features): https://pub.dev/packages/spp_connection_plugin

**Rule:** If a package is outdated/broken with current Flutter/Android Gradle, replace it with a maintained alternative.

---

## 6) ESP32 Firmware Implementation Guidance (Arduino)

### 6.1 Core modules

- BluetoothSerial SPP server advertising name `Smart-Medicine-Reminder`
- DS3231 RTC read/write (set from phone via `TIME,...`)
- Schedule storage:
  - Save med1/med2/med3 in NVS/Preferences as strings or minutes-from-midnight ints
- Scheduler:
  - Every second: check if current time matches any slot and not already triggered today
  - Reset triggers at midnight
- Servo control:
  - 3 servos (one per compartment latch)
  - Keep angles configurable constants (LOCK_ANGLE/UNLOCK_ANGLE per compartment)
- Optional display:
  - show time + next slot + BT status

### 6.2 Power stability

- Servos MUST have a proper 5V rail; ESP32 must not brownout when servo moves.
- Common ground between ESP32 and servo PSU.
- Add decoupling capacitor near servo rail (implementation note; not code).

### 6.3 Functional behavior

- On scheduled trigger:
  - open the compartment (servo unlock)
  - optional: re-lock after N seconds OR remain unlocked until manually closed
- Device buzzer: optional; default OFF since phone provides alert.

---

## 7) Pairing UX Requirements (device discoverability)

- Device must appear as `Smart-Medicine-Reminder` in Android scan list.
- Recommended: “Pair mode” button:
  - hold 3 seconds → enable discoverability for 60–120 seconds
  - show on OLED/LCD
- Simpler fallback: always discoverable while powered on (acceptable for indoor demo).

---

## 8) Testing Checklist (must pass before declaring done)

### App

- Can scan and see `Smart-Medicine-Reminder`
- Can connect, SYNC, and show success state
- Notifications fire at the right times (test with near-future times)
- App works after reboot and retains chosen times

### Device

- Receives schedule and persists across reboot
- RTC time set from phone works
- Opens correct compartment at scheduled time
- Prevents re-triggering the same slot multiple times per day
- Does not reset when servos actuate (power rail check)

---

## 9) Deliverables the agent must produce

1. **Working Flutter Android app** with the reference UI + connect screen.
2. **ESP32 Arduino firmware** implementing SPP protocol, RTC, schedule storage, servo opening.
3. Updated **README.md** with:
   - wiring + power notes
   - setup steps
   - troubleshooting
4. Basic **test log** in `/docs/test_log.md`:
   - dates tested
   - observed results
   - known issues

---

## 10) Agent Operating Rules

- Prefer the simplest solution that satisfies constraints.
- Avoid scope creep (no cloud, no login, no remote caregiver system).
- Keep dependencies minimal and current.
- Write clear, defensive parsing for serial commands.
- Do not assume always-on Bluetooth; design for sync-then-disconnect.
- When uncertain, choose a pragmatic default and document it in README.
