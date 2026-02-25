# Firmware Test Sketches (Bluetooth)

These are standalone ESP32 test sketches for testing one subsystem at a time.
Upload only one test sketch at a time.

## Folder layout

- RTC + Bluetooth: `firmware/tests/rtc_ds3231_bluetooth_test/rtc_ds3231_bluetooth_test.ino`
- Servo directions + Bluetooth: `firmware/tests/servo_direction_bluetooth_test/servo_direction_bluetooth_test.ino`
- Servo angle calibration + Bluetooth: `firmware/tests/servo_angle_calibration_bluetooth_test/servo_angle_calibration_bluetooth_test.ino`
- Diagnostics (power/boot/BT only):
  - `firmware/tests/diagnostics/serial_only_power_test/serial_only_power_test.ino`
  - `firmware/tests/diagnostics/bluetooth_only_stability_test/bluetooth_only_stability_test.ino`
  - `firmware/tests/diagnostics/servo_sweep_0_180_test/servo_sweep_0_180_test.ino`

## Common setup

- Board: ESP32 (same board/profile used by your main firmware).
- Libraries:
  - `BluetoothSerial` (built into ESP32 Arduino core)
  - `RTClib` (RTC test)
  - `ESP32Servo` (servo test)
- Android app for manual testing: any Bluetooth Classic terminal app.
- In terminal settings, enable newline append (`\n`) when sending commands.

## 0) Diagnostics first (recommended)

Run these before connecting RTC/LCD/servos if you suspect random resets.

### A) Serial-only power test

- Sketch: `firmware/tests/diagnostics/serial_only_power_test/serial_only_power_test.ino`
- Purpose: confirm the ESP32 can stay up without peripherals and without Bluetooth.
- Expected output (Serial monitor `115200`):
  - `READY,SERIAL_ONLY_POWER_TEST`
  - `RESET_REASON,...`
  - `HEARTBEAT,uptime_ms=...,free_heap=...` every second
- If you still see reboot lines (`rst:0x...`) here, the issue is board power/USB cable/board settings.

### B) Bluetooth-only stability test

- Sketch: `firmware/tests/diagnostics/bluetooth_only_stability_test/bluetooth_only_stability_test.ino`
- Bluetooth name: `SMR-BT-DIAG`
- Purpose: verify Bluetooth stack is stable before adding RTC/LCD/servo load.
- Commands over Bluetooth terminal:
  - `PING` -> `PONG`
  - `INFO` -> memory + uptime line
  - `RESET` -> software restart
- If resets appear only in this stage, check board settings (especially PSRAM option) and power quality.

### C) General servo sweep test (0 to 180)

- Sketch: `firmware/tests/diagnostics/servo_sweep_0_180_test/servo_sweep_0_180_test.ino`
- Purpose: direct hardware test of servo movement without Bluetooth, RTC, or LCD logic.
- Serial monitor: `115200`.
- Commands:
  - `S` -> sweep all servos (0 -> 180 -> 0)
  - `1` / `2` / `3` -> sweep one servo only
  - `H` -> print help
- Tip: disconnect servo horns/load during this test to avoid mechanical stalls while sweeping extremes.

## 1) DS3231 RTC Bluetooth test

- Bluetooth name: `SMR-RTC-Test`
- Wiring:
  - DS3231 `VCC` -> ESP32 `3V3`
  - DS3231 `GND` -> ESP32 `GND`
  - DS3231 `SDA` -> ESP32 `GPIO 21`
  - DS3231 `SCL` -> ESP32 `GPIO 22`

Commands:

- `HELP`
- `PING`
- `NOW`
- `LOST`
- `SET,YYYY-MM-DD,HH:MM:SS`
- `STREAM,ON`
- `STREAM,OFF`

Quick test sequence:

1. Send `PING` -> expect `OK`.
2. Send `SET,2026-02-22,10:30:00` -> expect `OK` and `NOW,...`.
3. Send `NOW` -> verify RTC keeps ticking.
4. Send `STREAM,ON` -> receive time updates every second.

## 2) Servo direction Bluetooth test

- Bluetooth name: `SMR-Servo-Test`
- Servo pins (same as project firmware):
  - Servo 1 -> `GPIO 25`
  - Servo 2 -> `GPIO 26`
  - Servo 3 -> `GPIO 27`
- Default angles:
  - Lock: `45`
  - Unlock: `160`

Commands:

- `HELP`
- `PING`
- `STATUS`
- `LOCK,1` / `LOCK,2` / `LOCK,3`
- `UNLOCK,1` / `UNLOCK,2` / `UNLOCK,3`
- `MOVE,slot,angle`
- `SETLOCK,slot,angle`
- `SETUNLOCK,slot,angle`
- `TEST,slot`
- `SWEEP,slot,from,to,step,delay_ms`

Quick test sequence:

1. Send `STATUS` to see current lock/unlock values.
2. Send `UNLOCK,1` then `LOCK,1` to check physical direction.
3. If direction is wrong, swap calibration:
   - Example: `SETLOCK,1,95` and `SETUNLOCK,1,10`
4. Send `TEST,1` to verify open-close behavior with delay.

## 3) Servo angle calibration Bluetooth test (recommended for lock/unlock tuning)

- Sketch: `firmware/tests/servo_angle_calibration_bluetooth_test/servo_angle_calibration_bluetooth_test.ino`
- Bluetooth name: `SMR-Servo-Calib`
- Purpose: interactively find lock/unlock angles and print copy-ready constants for the main firmware.

Commands:

- `HELP`
- `PING`
- `STATUS`
- `SLOT,1` / `SLOT,2` / `SLOT,3` (select active slot)
- `ANGLE,deg` (move selected slot directly)
- `NUDGE,delta` (example: `NUDGE,-2`, `NUDGE,+5`)
- `MOVE,slot,deg`
- `LOCK` / `UNLOCK` (selected slot)
- `LOCK,slot` / `UNLOCK,slot`
- `SAVELOCK` / `SAVEUNLOCK` (save selected slot from current angle)
- `SAVELOCK,slot` / `SAVEUNLOCK,slot`
- `TEST` (selected slot open->close)
- `TEST,slot`
- `TEST,slot,delayMs`
- `PRINTCFG` (prints lock/unlock values + copy-ready constants)
- `RESETCFG` (restore defaults and save)

Quick calibration flow:

1. Send `SLOT,1`.
2. Use `ANGLE,<deg>` and `NUDGE,<delta>` until position is the exact closed angle.
3. Send `SAVELOCK`.
4. Move to exact open angle and send `SAVEUNLOCK`.
5. Send `TEST,1,1200` to verify.
6. Repeat for slots 2 and 3.
7. Send `PRINTCFG` and copy the constants into your main firmware.

## Power and safety notes

- Do not power servos directly from ESP32 `3V3`.
- Use a dedicated 5V rail for servos.
- Keep servo power ground connected to ESP32 ground (common GND).
