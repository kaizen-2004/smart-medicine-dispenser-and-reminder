# Smart Medicine Reminder

Offline-first smart medicine reminder using:
- Android Flutter app (phone-side local notifications)
- ESP32 + Bluetooth Classic SPP (sync/config only)
- DS3231 RTC + NVS persistence (autonomous pillbox operation)

## Repository Layout

```text
app/        Flutter Android app
firmware/   ESP32 Arduino sketch
docs/       Project documentation and test log
tools/      Optional utilities and notes
```

## What Works in This Scaffold

- Schedule UI with 3 medicine rows (`SET`, label, `HH:MM`)
- Current time display updating every second
- Connect Device screen with scan + connect flow
- SPP protocol commands from app (`TIME`, `SYNC`) with response handling
- Daily local notifications for medicine 1/2/3
- Local persistence of schedule + last sync timestamp
- ESP32 firmware protocol parser:
  - `GET`
  - `SYNC,HH:MM,HH:MM,HH:MM`
  - `SET,slot,HH:MM`
  - `TIME,YYYY-MM-DD,HH:MM:SS`
  - `TEST,slot`
- ESP32 autonomous scheduler with daily trigger lockout
- ESP32 schedule persistence in NVS

## Android App Setup

Prerequisites:
- Flutter SDK installed and on `PATH`
- Android SDK + a physical Android device

Commands:

```bash
cd app
[ -f android/gradlew ] || flutter create --platforms android .
cp android/local.properties.example android/local.properties
# edit android/local.properties with your local Android/Flutter SDK paths
flutter pub get
flutter run -d <android-device-id>
```

Notes:
- App is Android-only by design.
- If Bluetooth pairing is unreliable in-app, pair first via Android Bluetooth settings.
- On Android 13+, grant notification permission.
- For best reminder precision, allow exact alarms in app settings.

## Android Release Build (AAB/APK)

1. Set your app version in `app/pubspec.yaml` (for example: `1.0.0+1`).
2. Create an upload keystore (run once):

```bash
cd app/android
keytool -genkey -v \
  -keystore ../upload-keystore.jks \
  -alias upload \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000
```

3. Create signing properties:

```bash
cd app/android
cp key.properties.example key.properties
```

4. Edit `app/android/key.properties`:
   - `storePassword`: keystore password
   - `keyPassword`: key password
   - `keyAlias`: alias used in keytool command (default `upload`)
   - `storeFile`: path to keystore (default `../upload-keystore.jks`)

5. Build release artifacts:

```bash
cd app
flutter clean
flutter pub get
flutter build appbundle --release
flutter build apk --release
```

6. Output files:
   - AAB: `app/build/app/outputs/bundle/release/app-release.aab`
   - APK: `app/build/app/outputs/flutter-apk/app-release.apk`

Note:
- If `app/android/key.properties` is missing, Gradle falls back to debug signing for release builds. This is only for local testing, not Play Store upload.

## ESP32 Firmware Setup

Sketch:
- `firmware/smart_medicine_reminder.ino`

Arduino dependencies:
- ESP32 Arduino core
- `RTClib`
- `ESP32Servo`

Steps:
1. Open the sketch in Arduino IDE.
2. Select an ESP32 board (e.g., `ESP32 Dev Module`).
3. Wire RTC + servos as below.
4. Upload firmware.
5. Open serial monitor at `115200` baud for debug logs.

## Suggested Wiring

- DS3231:
  - `VCC -> 3V3` (or module-supported `5V`, depending on board/module)
  - `GND -> GND`
  - `SDA -> GPIO21`
  - `SCL -> GPIO22`
- Servo signals:
  - Compartment 1 -> `GPIO25`
  - Compartment 2 -> `GPIO26`
  - Compartment 3 -> `GPIO27`

## Power Notes (Important)

- Use a dedicated 5V rail for servos (recommended 5V 2A minimum, 3A preferred).
- ESP32 should be powered separately from USB/regulated source.
- Share common ground between ESP32 and servo power supply.
- Add bulk capacitance near servo rail to avoid brownouts during movement.

## Bluetooth SPP Protocol

App to device:
- `GET\n`
- `SYNC,HH:MM,HH:MM,HH:MM\n`
- `SET,1,HH:MM\n` / `SET,2,HH:MM\n` / `SET,3,HH:MM\n`
- `TIME,YYYY-MM-DD,HH:MM:SS\n`
- `TEST,1\n` / `TEST,2\n` / `TEST,3\n`

Device to app:
- `OK\n`
- `SCHED,1,HH:MM,2,HH:MM,3,HH:MM\n`
- `ERR,BAD_FORMAT\n`
- `ERR,RTC_NOT_SET\n`

## Troubleshooting

- Device not visible in scan list:
  - Confirm board is powered and Bluetooth name is `Smart-Medicine-Reminder`.
  - Pair once from Android settings, then retry in-app.
- Notifications not appearing:
  - Check app notification permission.
  - Disable battery optimization for this app if your phone is aggressive.
- Reboots when servos move:
  - This is usually power rail sag. Use separate servo PSU and common GND.
- Wrong trigger timing:
  - Send `TIME,...` from app during each sync to keep RTC aligned.

## Current Validation Status

- Android release build validated on `2026-02-22`:
  - `flutter build appbundle --release` succeeded
  - `flutter build apk --release` succeeded
- Firmware flashing/runtime hardware tests are still required on a physical ESP32 + DS3231 + servo setup.
