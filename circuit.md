# Circuit / Hardware Connections

This matches the current firmware in `firmware/smart_medicine_reminder/smart_medicine_reminder.ino`.

You can connect **DS3231 RTC + 16x2 I2C LCD** on the same I2C bus.

## 1) ESP32 <-> Servos

- Servo 1 signal -> ESP32 GPIO `25`
- Servo 2 signal -> ESP32 GPIO `26`
- Servo 3 signal -> ESP32 GPIO `27`

Power:

- All servo VCC -> External `+5V` servo PSU
- All servo GND -> External PSU GND
- ESP32 GND -> External PSU GND (common ground required)

Important:

- Do **not** power all servos from ESP32 5V pin.
- Add `470uF to 1000uF` capacitor across servo `+5V` and `GND`.

## 2) ESP32 <-> DS3231 RTC (I2C)

- DS3231 VCC -> ESP32 `3V3` (or board-safe supply)
- DS3231 GND -> ESP32 `GND`
- DS3231 SDA -> ESP32 GPIO `21`
- DS3231 SCL -> ESP32 GPIO `22`

Notes:

- Install CR2032 cell for RTC backup.
- DS3231 and LCD share SDA/SCL in parallel.

## 3) ESP32 <-> 16x2 LCD with I2C Backpack

- LCD SDA -> ESP32 GPIO `21`
- LCD SCL -> ESP32 GPIO `22`
- LCD GND -> ESP32 `GND`
- LCD VCC -> `5V` (module dependent)

Address:

- Common address is `0x27` (current firmware).
- If blank, scan for `0x3F` and update firmware constant.

## 4) ESP32 <-> Buttons (new)

Button wiring uses internal pull-ups (`INPUT_PULLUP`), so each button is:
- One leg to GPIO pin
- Other leg to `GND`

Pins:

- Button A (Patient Acknowledge) -> GPIO `32`
- Button B (Refill Mode Toggle, long press 2s) -> GPIO `33`

Behavior:

- Button A press:
  - Close all compartments
  - Silence buzzer
  - Mark only currently due medicines (firmware event to app)
- Button B long press 2s:
  - Toggle refill mode ON/OFF
  - ON: open all compartments and keep open
  - OFF: close all compartments

## 5) ESP32 <-> Buzzer (new)

Pin:

- Buzzer control -> ESP32 GPIO `14`

Recommended wiring:

- Use an **active buzzer module** with transistor driver if current is high.
- For direct small active buzzer modules:
  - SIG -> GPIO `14`
  - VCC -> `3V3` or `5V` (module rating)
  - GND -> common GND

The buzzer is used for due alerts and is silenced by Button A.

## 6) ESP32 Power

Option A:

- ESP32 via USB, servos via separate 5V PSU.

Option B:

- Single regulated 5V PSU to ESP32 VIN + servo rail.

Always keep common GND between ESP32, servo PSU, RTC, LCD, buttons, buzzer.

## 7) Bluetooth

- No external BT module needed.
- ESP32 Bluetooth Classic SPP is used.
- Device name: `Smart-Medicine-Reminder`.
- Current behavior: always discoverable while powered.

## 8) Quick Checklist

1. Common GND between all modules and supplies.
2. Servos on GPIO 25/26/27 with external 5V rail.
3. RTC + LCD both on SDA 21 / SCL 22.
4. Button A on GPIO 32 to GND.
5. Button B on GPIO 33 to GND.
6. Buzzer on GPIO 14.
7. RTC backup battery installed.
