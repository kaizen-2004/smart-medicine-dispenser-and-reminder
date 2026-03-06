# Test Log

## 2026-02-21

### Environment
- Workspace scaffold/build pass by Codex
- Local toolchain availability in this environment:
  - `flutter`: not installed
  - `dart`: not installed
  - `arduino-cli`: not installed

### Checks Performed
1. Repository structure scaffolded:
   - `app/`
   - `firmware/`
   - `docs/`
   - `tools/`
2. Flutter source files created for:
   - schedule screen UI
   - connect screen
   - Bluetooth SPP service
   - notification scheduling service
   - schedule persistence
3. ESP32 firmware created for:
   - Bluetooth Classic SPP command parser
   - DS3231 RTC time set
   - schedule persistence in NVS
   - autonomous servo schedule trigger
4. Documentation created/updated:
   - `README.md`
   - `docs/description.md`
   - `docs/test_log.md`

### Runtime Test Results
- Android app compile/run: **Not executed in this environment** (missing Flutter SDK)
- Firmware compile/flash: **Not executed in this environment** (missing Arduino toolchain)

### Known Issues / Follow-up
- Run full on-device tests from acceptance checklist once Flutter and Arduino toolchains are available.
- Verify exact Bluetooth plugin/API compatibility with your installed Flutter/Gradle versions.

## 2026-02-22

### Environment
- Flutter toolchain available:
  - `flutter`: 3.41.2
  - `dart`: 3.11.0 (via Flutter)
- Android release build executed from `app/`

### Checks Performed
1. Updated Android signing config to use `app/android/key.properties` when present.
2. Added keystore template file: `app/android/key.properties.example`.
3. Updated Kotlin Android plugin from `2.0.21` to `2.1.0`.
4. Built Android release artifacts:
   - `flutter build appbundle --release`
   - `flutter build apk --release`

### Runtime Test Results
- `app-release.aab` generated successfully:
  - `app/build/app/outputs/bundle/release/app-release.aab`
- `app-release.apk` generated successfully:
  - `app/build/app/outputs/flutter-apk/app-release.apk`
- Build sizes observed:
  - AAB: ~42.5 MB
  - APK: ~50.8 MB

### Known Issues / Follow-up
- `app/android/key.properties` is currently missing, so release signing falls back to debug key.
- Before Play Store upload, create `app/upload-keystore.jks` and `app/android/key.properties`, then rebuild.
- Physical-device validation for notifications, Bluetooth sync, and ESP32 scheduling is still pending.

## 2026-03-05

### Environment
- Workspace updated to use v2 firmware source:
  - `firmware/smart_medicine_reminder_v2/smart_medicine_reminder_v2.ino`

### Checks Performed
1. App sync flow updated to prefer `SYNC2` (date-aware descriptors).
2. Added automatic fallback to legacy `SYNC` for older firmware that returns `ERR,BAD_FORMAT` or no SYNC2 acknowledgement.
3. Updated README firmware upload target and protocol docs for `SYNC2`/`SCHED2`.
4. Updated Connect screen to allow direct connection attempts for paired/saved devices even when not discovered in the last scan window.
5. Simplified sync behavior to reduce false failures:
   - disabled auto-sync on reconnect
   - if `TIME` fails, app still attempts `SYNC2` / `SYNC` so schedule can still be sent.

### Runtime Test Results
- Flutter static analysis:
  - `flutter analyze` (from `app/`) -> **No issues found**
- Flutter build:
  - `flutter build apk --debug` (from `app/`) -> **Success**
  - Output: `app/build/app/outputs/flutter-apk/app-debug.apk`
- Flutter tests:
  - `flutter test` (from `app/`) -> **All tests passed** (`3 passed`)
- Firmware compile:
  - `arduino-cli compile --fqbn esp32:esp32:esp32 firmware/smart_medicine_reminder_v2` -> **Success**
  - Binary size: `1115783 bytes` (85% of `1310720`)
  - RAM use: `43988 bytes` (13% of `327680`)
  - Note: Arduino warning shown for `LiquidCrystal I2C` AVR architecture metadata; compile still successful for ESP32.

### Known Issues / Follow-up
- Run phone + device integration test:
  - set one-time schedule in app
  - confirm firmware stores `O@YYYY-MM-DD@HH:MM`
  - verify one-time schedule triggers once and does not repeat next day.
- Manual Bluetooth connect verification still needed on physical phone after the Connect screen gating fix.
- Validate that schedule sync works even when `TIME` intermittently fails.
