# Smart Medicine Reminder (3-Compartment Pillbox) — Project Plan

## 1. Project Overview

This project is an **offline-first smart medicine reminder** consisting of:

- A **3-compartment pill box** (Compartment 1 / 2 / 3).
- An **ESP32-based pillbox device** that automatically **opens the correct compartment** on schedule using **SG90 servo motors**.
- An **Android app (admin UI)** that displays the **current time** and lets the administrator **set the schedule** for each compartment.
- **Phone-side notifications/alerts** (the reminders happen on the **Android phone**, not on the device), with **no Wi‑Fi required**.

**Core design decision (path of least resistance, no Wi‑Fi):**

- Use **Bluetooth Classic (SPP / Serial)** for phone ↔ device communication.
- Use **Android Local Notifications** for alerts.
- Use an **RTC module (DS3231)** + **local schedule storage** on ESP32 so the device can still open compartments even when the phone is not connected.

---

## 2. Goals and Non-Goals

### Goals

1. Android app shows **current time** and allows setting **3 daily intake times** (one per compartment).
2. Android app triggers **local notifications** at those times (phone-side alert).
3. Pillbox device automatically **opens the correct compartment** at the scheduled time.
4. Device works **without Wi‑Fi** (indoor offline operation).
5. Setup/updates are simple: **pair → connect → sync schedule → done**.

### Non-Goals (out of scope for “least headache” build)

- Cloud backend (Firebase), remote monitoring, caregiver push notifications over the internet.
- Multi-user authentication and per-user security.
- GPS/location features.

---

## 3. System Architecture

### High-level modules

**Android App (Admin)**

- UI (matches reference): current time + “SET” for Medicine 1/2/3.
- Local notifications scheduler.
- Bluetooth Classic (SPP) communicator for syncing schedule.
- Optional: test open commands, read-back schedule.

**Pillbox Device (ESP32)**

- Bluetooth Classic SPP server (advertises as a discoverable device name).
- RTC timekeeping (DS3231 recommended).
- Schedule storage in NVS/flash (survives power loss).
- Servo control for 3 compartments.
- LCD display for device name / status (optional but recommended).
- Optional: physical ACK button for local “taken” confirmation.

---

## 4. Hardware Plan

### Required hardware

- **ESP32-WROOM-32** (DevKit recommended for easiest programming)
- **3× SG90 servo motors** (one per compartment latch)
- **DS3231 RTC module** (highly recommended for reliable timekeeping)
- **I2C LCD**
- Power supply:
  - **5V 2A minimum** (recommended 5V 3A for stability)
  - Servos powered from **separate 5V rail**, with **common ground** to ESP32

### Optional hardware (quality-of-life)

- **Buttons**: Pair Mode, ACK, Manual open/test
- LED status indicator
- Small spring/magnet latch assist for “pop-open” door action

### Mechanical concept

- Each compartment uses a **servo-actuated latch**.
- At unlock time: servo rotates to release latch, door opens (assisted by spring/magnet).
- Latch design reduces torque requirements vs pushing the lid directly.

---

## 5. Software Plan

### 5.1 Android App — Features

#### Primary features

- **Home/Schedule screen** (reference UI):
  - Current time displayed continuously.
  - Medicine 1/2/3 time set via Time Picker.
  - “SYNC / SAVE TO DEVICE” button.
- **Phone notifications**:
  - Local notification for each schedule time.
  - Optional: repeating daily alarms.

#### Secondary/optional features

- Connect Device screen:
  - Scan and select `Smart-Medicine-Reminder` (or chosen name).
  - Connection status indicator.
- “READ FROM DEVICE” button:
  - Fetch and display schedule currently stored on ESP32.
- “TEST OPEN 1/2/3”:
  - For demo/testing servo movement.

---

### 5.2 ESP32 Device — Features

#### Primary features

- Bluetooth Classic (SPP) discoverable device name: e.g., `Smart-Medicine-Reminder`.
- Receive schedule from phone and store locally.
- Keep accurate time via DS3231 RTC.
- Open correct compartment using servo at scheduled time.
- Optional: device display shows:
  - device name
  - paired/connected status
  - next scheduled event

#### Optional features

- **ACK button**:
  - Press after medicine is taken.
  - Can log simple counters (taken/missed) and allow phone to read them later.
- “Pair Mode” timed discoverability (60–120 seconds) for cleaner UX.

---

## 6. Communication (Bluetooth SPP) — Simple Command Contract

**Design goal:** human-readable, easy to debug with a Bluetooth terminal.

### Commands (phone → ESP32)

- `GET` — request current stored schedule
- `SET,1,HH:MM` — set schedule for compartment 1
- `SET,2,HH:MM`
- `SET,3,HH:MM`
- `SYNC,HH:MM,HH:MM,HH:MM` — (optional) one-shot set all three times
- `TIME,YYYY-MM-DD,HH:MM:SS` — (optional) set RTC from phone once during setup
- `TEST,1` / `TEST,2` / `TEST,3` — (optional) servo test

### Responses (ESP32 → phone)

- `OK`
- `SCHED,1,HH:MM,2,HH:MM,3,HH:MM`
- `ERR,BAD_FORMAT`
- `ERR,RTC_NOT_SET`

---

## 7. User Experience Flow

### 7.1 First-time setup

1. Power on pillbox → device shows `PAIR MODE` and name `Smart-Medicine-Reminder`.
2. Phone opens Bluetooth settings or app “Connect Device”.
3. User sees device name in the list, taps to pair/connect.
4. App opens schedule UI, sets times for Medicine 1/2/3.
5. User taps **SYNC**.
6. App:
   - schedules **local phone notifications**
   - sends schedule to ESP32
7. ESP32 stores schedule and confirms `OK`.

### 7.2 Daily operation (no constant connection needed)

1. Phone issues notification at scheduled time (sound/vibration on phone).
2. ESP32 checks RTC and opens the correct compartment at the same time.
3. Optional: user presses ACK on device.

### 7.3 Updating schedule

1. Open app → connect via Bluetooth.
2. Change times → tap SYNC.
3. Both phone notifications and device schedule update.

---

## 8. Timing Strategy (Important Design Choice)

To avoid Android background/Bluetooth reliability issues:

- The **device opens compartments autonomously** (RTC + stored schedule).
- The **phone alerts autonomously** (local notifications).
- Bluetooth is used primarily for **configuration/sync**, not for real-time “open now” commands.

This ensures the pillbox works even if the phone is far away or Bluetooth is off temporarily.

---

## 9. Device State Machine (ESP32)

### Core states

1. **BOOT** — initialize RTC, load schedule, init servos, init Bluetooth
2. **IDLE** — show next schedule, wait
3. **TRIGGER** — when RTC time matches schedule (and not already triggered today)
4. **OPEN_COMPARTMENT** — move servo to unlock position
5. **POST_ACTION** — optional: wait for ACK for N minutes, then return to IDLE

### Key rules

- One trigger per slot per day (prevent repeated opens).
- Store “triggered today” flags and reset at midnight.

---

## 10. Acceptance Criteria (Definition of Done)

1. Android app can set 3 times and shows them correctly.
2. Android app generates phone notifications at those times (daily).
3. ESP32 stores the same times and opens correct compartment reliably.
4. System operates without Wi‑Fi.
5. Schedule persists across power cycle.
6. Pairing/connection works by seeing the device name (e.g., `Smart-Medicine-Reminder`) in scan results.

---

## 11. Test Plan

### Functional tests

- **Bluetooth discovery**: device name visible in Android scan list.
- **Sync schedule**: change times → device reports correct schedule via `GET`.
- **Timekeeping**: set RTC → verify device time matches phone.
- **Servo action**: each compartment opens correctly at scheduled time.
- **Persistence**: power cycle → schedule retained.

### Reliability tests

- Servo opening repeated daily for multiple cycles.
- Power stability: no ESP32 resets when servos actuate (ensure separate 5V servo power + common ground).

### UX tests

- Setup takes under 2 minutes: pair → set times → sync.
- Notifications appear even when app is closed.

---

## 12. Project Milestones

1. Hardware prototype (ESP32 + RTC + one servo latch)
2. Expand to 3 servos + stable power + latch mechanics
3. Android UI (schedule screen) + local notifications
4. Bluetooth SPP sync (SET/GET/SYNC) + schedule persistence
5. Integration + testing + polish (pair mode, test open, read-back)

---

## 13. Risks and Mitigations

- **Servo brownout resets** → use dedicated 5V supply and capacitor; common ground.
- **Android notification timing variance** → use local notifications; enable exact alarms if needed (optional).
- **Bluetooth pairing confusion** → allow pairing via Android Settings + simple connect screen in app.
- **RTC not set** → allow app to set device time once (`TIME` command); show warning until set.

---

## 14. Final Recommended Build Variant (Summary)

- **Connectivity:** Bluetooth Classic (SPP), offline.
- **Alerts:** Android local notifications (phone-side).
- **Dispensing action:** ESP32 uses DS3231 RTC + stored schedule to open 1/2/3 compartments.
- **UI:** matches reference screen (current time + 3 schedule rows + SYNC).
