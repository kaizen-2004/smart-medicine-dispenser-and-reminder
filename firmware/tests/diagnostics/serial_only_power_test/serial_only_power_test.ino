#include <Arduino.h>
#include <esp_system.h>

namespace {
constexpr uint32_t kHeartbeatIntervalMs = 1000;
uint32_t lastHeartbeatMs = 0;
} // namespace

const char *resetReasonToString(esp_reset_reason_t reason) {
  switch (reason) {
    case ESP_RST_UNKNOWN:
      return "UNKNOWN";
    case ESP_RST_POWERON:
      return "POWERON";
    case ESP_RST_EXT:
      return "EXTERNAL_PIN";
    case ESP_RST_SW:
      return "SOFTWARE";
    case ESP_RST_PANIC:
      return "PANIC";
    case ESP_RST_INT_WDT:
      return "INT_WDT";
    case ESP_RST_TASK_WDT:
      return "TASK_WDT";
    case ESP_RST_WDT:
      return "OTHER_WDT";
    case ESP_RST_DEEPSLEEP:
      return "DEEPSLEEP";
    case ESP_RST_BROWNOUT:
      return "BROWNOUT";
    case ESP_RST_SDIO:
      return "SDIO";
    default:
      return "UNMAPPED";
  }
}

void printBanner() {
  Serial.println();
  Serial.println("READY,SERIAL_ONLY_POWER_TEST");
  Serial.printf(
      "RESET_REASON,%s (%d)\n",
      resetReasonToString(esp_reset_reason()),
      static_cast<int>(esp_reset_reason()));
}

void setup() {
  Serial.begin(115200);
  delay(300);
  printBanner();
}

void loop() {
  const uint32_t nowMs = millis();
  if ((nowMs - lastHeartbeatMs) >= kHeartbeatIntervalMs) {
    lastHeartbeatMs = nowMs;
    Serial.printf(
        "HEARTBEAT,uptime_ms=%lu,free_heap=%u\n",
        static_cast<unsigned long>(nowMs),
        static_cast<unsigned int>(ESP.getFreeHeap()));
  }
}
