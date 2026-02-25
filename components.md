# Components for Smart Medicine Reminder (Hardware)

## Required (for full offline/autonomous behavior)

| Qty | Component | Suggested spec / notes |
|---|---|---|
| 1 | ESP32 dev board | ESP32 DevKit V1 (WROOM-32). Uses built-in Bluetooth Classic (no external BT module needed). |
| 1 | DS3231 RTC module | I2C real-time clock with backup coin cell (CR2032). |
| 1 | 16x2 LCD with I2C backpack (PCF8574) | Required for on-device display. Typical I2C address is `0x27` or `0x3F`. |
| 3 | Servo motors | SG90/MG90S (or similar) for 3 compartments. |
| 2 | Tactile push buttons | One for patient acknowledge (Button A), one for refill mode toggle (Button B). |
| 1 | Active buzzer module | Local audible reminder; silenced by Button A acknowledge. |
| 1 | External 5V servo power supply | At least 3A recommended for 3 servos (higher if servos are stronger/larger). |
| 1 | 5V power for ESP32 | USB cable + phone charger/power bank, or regulated 5V rail to VIN. |
| 1 | Common ground wiring | Ground of ESP32 and servo PSU must be tied together. |
| 1 | Electrolytic capacitor | 470uF to 1000uF, >= 10V, placed near servo power rail. |
| 1 set | Jumper wires | Male-female / male-male as needed. |
| 1 | Breadboard or perfboard | For prototype wiring. |

## Optional (recommended)

| Qty | Component | Purpose |
|---|---|---|
| 1 | On/off switch | Main power control. |
| 1 | Fuse (or resettable polyfuse) | Basic overcurrent protection on servo rail. |
| 1 | Level shifter / transistor stage | Only if using unusual servos or long/noisy signal lines. |
| 1 | I2C scanner sketch (software tool) | Useful to confirm LCD backpack address (`0x27` vs `0x3F`). |
| 1 | NPN transistor + base resistor (1k to 2.2k) | Recommended buzzer driver if your buzzer draws more current than a GPIO should source. |
| 1 | Enclosure + mounts | Mechanical stability and safety. |

## Not needed

- External Bluetooth module (HC-05/HC-06) is **not required** because ESP32 already provides Bluetooth Classic via `BluetoothSerial`.
- Separate LCD contrast potentiometer is usually **not needed** because most I2C backpacks already include one onboard.

## Firmware-matched assumptions

Based on your current firmware (`firmware/smart_medicine_reminder/smart_medicine_reminder.ino`):

- Servo pins: GPIO `25`, `26`, `27`
- RTC: DS3231 via I2C (default ESP32 I2C pins)
- Bluetooth device name: `Smart-Medicine-Reminder`
- LCD via I2C backpack (`LiquidCrystal_I2C`)
  - LCD address constant: `0x27` (change to `0x3F` if your module uses that)
- Button A pin: GPIO `32` (acknowledge/close/silence)
- Button B pin: GPIO `33` (long-press refill toggle)
- Buzzer pin: GPIO `14`
