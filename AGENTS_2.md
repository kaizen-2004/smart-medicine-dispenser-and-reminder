# AGENTS.md — Add OTA Updates to Existing ESP32 DevKit Firmware (Arduino IDE)
_Last updated: 2026-02-28_

## Decision Summary (Best Default)
**Use ESP32 Wi‑Fi SoftAP + Web OTA** for firmware updates, while keeping **Bluetooth Classic (SPP)** for your Android app’s normal connection (control/telemetry).

**Why**
- **More reliable** than sending large firmware binaries over Bluetooth SPP.
- **Safer** with an OTA partition scheme: update writes to the **inactive OTA slot** and switches only after success.
- **Simpler** on Android: upload via **browser** (or optional HTTP upload in-app).
- **Works offline**: no internet required (phone connects directly to ESP32 AP).

---

## What the agent must do
You (the AI agent) are assisting a project that already has:
- An ESP32 DevKit running an Arduino sketch
- An Android app connected via Bluetooth Classic (SPP)

Your job is to **add OTA capability** without breaking the existing Bluetooth app workflow.

### Required outcomes
1. ESP32 can enter “Update Mode” on demand (preferably triggered by a BT command).
2. In Update Mode, ESP32 starts a Wi‑Fi SoftAP and hosts an OTA upload page:
   - URL: `http://192.168.4.1/update`
3. User uploads the firmware `.bin` from Android (browser).
4. ESP32 reboots into the new firmware and BT app still works.

---

## Safety Requirements (Non‑negotiable)
1. **Partition Scheme MUST include OTA**
   - Arduino IDE → Tools → Partition Scheme → choose an option containing **OTA**.
2. OTA page should **not** be always available.
   - Only enable Wi‑Fi SoftAP + `/update` in Update Mode.
3. Maintain stable power during update (USB power recommended).
4. Do not change flash/PSRAM/partition settings between builds unless intentional.

---

## Arduino IDE Build + Firmware Export Steps
1. Select correct board + settings (same as your current working firmware):
   - Tools → Board: ESP32 Dev Module / DevKit variant
   - Tools → Flash Size: match device (often 4MB)
   - Tools → Partition Scheme: **must include OTA**
2. Generate the update file:
   - Sketch → **Export Compiled Binary**
3. Copy the resulting `.bin` to the Android phone (Drive / USB / etc.).

---

## Android Update Steps (User Procedure)
1. In the Android app (BT Classic), tap: **Firmware Update**
2. App sends: `ENTER_UPDATE_MODE`
3. ESP32 replies with AP info (example):
   - `AP_READY SSID=ESP32-OTA PASS=12345678 IP=192.168.4.1 URL=http://192.168.4.1/update`
4. User connects phone Wi‑Fi to `ESP32-OTA` (password `12345678`)
   - If Android warns “No internet”, choose **Stay connected / Use anyway**
5. Open browser:
   - `http://192.168.4.1/update`
6. Select the firmware `.bin`, upload, wait for completion
7. ESP32 reboots; app reconnects over Bluetooth

---

## ESP32 Implementation Guide (Integrate into Existing Sketch)

### A) Libraries to include
```cpp
#include <WiFi.h>
#include <WebServer.h>
#include <HTTPUpdateServer.h>
#include <BluetoothSerial.h>
```

### B) Global objects + flags
```cpp
BluetoothSerial SerialBT;

static bool updateMode = false;
static bool otaServerStarted = false;

WebServer server(80);
HTTPUpdateServer httpUpdater;
```

### C) Start Update Mode (SoftAP + Web OTA)
Use a function like this. Call it when you receive `ENTER_UPDATE_MODE`.

```cpp
void startUpdateMode() {
  if (updateMode) return;
  updateMode = true;

  const char* ap_ssid = "ESP32-OTA";
  const char* ap_pass = "12345678"; // >= 8 chars

  WiFi.mode(WIFI_AP);
  bool ok = WiFi.softAP(ap_ssid, ap_pass);
  IPAddress ip = WiFi.softAPIP();

  // Start OTA web server only once
  if (!otaServerStarted) {
    // Optional basic auth (recommended):
    // httpUpdater.setup(&server, "/update", "admin", "strongpassword");
    httpUpdater.setup(&server); // exposes /update

    server.on("/", []() {
      server.send(200, "text/plain",
        "ESP32 OTA Ready. Go to /update to upload firmware.\n");
    });

    server.begin();
    otaServerStarted = true;
  }

  // Tell the app what to do
  if (ok) {
    SerialBT.printf(
      "AP_READY SSID=%s PASS=%s IP=%s URL=http://%s/update\n",
      ap_ssid, ap_pass, ip.toString().c_str(), ip.toString().c_str()
    );
  } else {
    SerialBT.println("AP_FAIL");
  }
}
```

### D) Optional: Exit Update Mode (turn AP off)
```cpp
void stopUpdateMode() {
  if (!updateMode) return;
  updateMode = false;

  // Stop SoftAP
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_OFF);

  SerialBT.println("UPDATE_MODE_OFF");
}
```

### E) Bluetooth command parsing (minimal)
Integrate into your existing BT receive logic.

```cpp
void handleBluetoothCommands() {
  static String line;
  while (SerialBT.available()) {
    char c = (char)SerialBT.read();
    if (c == '\n') {
      line.trim();

      if (line == "ENTER_UPDATE_MODE") {
        startUpdateMode();
      } else if (line == "EXIT_UPDATE_MODE") {
        stopUpdateMode();
      } else {
        // Existing commands go here
      }

      line = "";
    } else {
      line += c;
    }
  }
}
```

### F) Main loop integration (critical)
When OTA server is enabled, you **must** call `server.handleClient()` frequently.

```cpp
void loop() {
  handleBluetoothCommands();

  if (otaServerStarted) {
    server.handleClient();
  }

  // Your existing logic here (sensors, UI, etc.)
}
```

---

## Security Recommendations (Pick at least one)
1. **Enable OTA basic auth**
   - `httpUpdater.setup(&server, "/update", "admin", "strongpassword");`
2. **Enable Update Mode only after BT confirmation**
   - e.g., require a one-time PIN: `ENTER_UPDATE_MODE 123456`
3. **Auto-timeout Update Mode**
   - After N minutes, call `stopUpdateMode()`.

---

## Troubleshooting Checklist
- `/update` page won’t open:
  - Phone must be connected to ESP32 AP (not mobile data/Wi‑Fi router)
  - Use `http://192.168.4.1/update`
- Upload fails immediately:
  - Partition Scheme likely **does not include OTA**
- ESP32 reboots but won’t run:
  - Board/flash settings changed between builds; rebuild using same settings
- Android disconnects from AP (“no internet”):
  - Choose “Stay connected / Use anyway”
- OTA works but BT app can’t reconnect:
  - Ensure BT device name/pairing behavior unchanged in new firmware

---

## Alternative Path (BT‑Only Firmware Update) — Not the default
BT-only OTA is possible but requires a robust file transfer protocol (chunking, retry/resume, integrity checks).
Choose this only if Wi‑Fi cannot be used.

Minimum spec for BT-only OTA (if ever implemented):
- Command: `OTA <size>\n` → ESP replies `OK\n`
- Stream raw bytes in fixed chunks (e.g., 1024 bytes)
- Verify integrity (CRC/SHA)
- Write using `Update.begin(size)`, `Update.write()`, `Update.end(true)`
- Reboot on success
