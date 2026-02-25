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
