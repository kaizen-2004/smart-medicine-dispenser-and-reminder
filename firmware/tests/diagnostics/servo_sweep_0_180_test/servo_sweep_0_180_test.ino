#include <Arduino.h>
#include <ESP32Servo.h>

namespace {
constexpr uint8_t kServoPins[3] = {25, 26, 27};
constexpr int kStartAngle = 90;
constexpr int kMinAngle = 0;
constexpr int kMaxAngle = 180;
constexpr int kStep = 2;
constexpr uint32_t kStepDelayMs = 20;
constexpr uint32_t kBetweenServoDelayMs = 400;
} // namespace

Servo servos[3];

void printHelp() {
  Serial.println("READY,SERVO_SWEEP_0_180_TEST");
  Serial.println("CMDS,S,1,2,3,H");
  Serial.println("S: sweep all servos 0->180->0");
  Serial.println("1/2/3: sweep only that servo");
  Serial.println("H: show this help");
}

void moveServo(int slotIndex, int angle) {
  servos[slotIndex].write(angle);
  delay(kStepDelayMs);
}

void sweepSlot(int slotIndex) {
  Serial.printf("SWEEP_START,SLOT,%d\n", slotIndex + 1);

  for (int angle = kMinAngle; angle <= kMaxAngle; angle += kStep) {
    moveServo(slotIndex, angle);
  }
  for (int angle = kMaxAngle; angle >= kMinAngle; angle -= kStep) {
    moveServo(slotIndex, angle);
  }

  servos[slotIndex].write(kStartAngle);
  Serial.printf("SWEEP_DONE,SLOT,%d\n", slotIndex + 1);
}

void sweepAll() {
  for (int i = 0; i < 3; i++) {
    sweepSlot(i);
    delay(kBetweenServoDelayMs);
  }
  Serial.println("SWEEP_ALL_DONE");
}

void handleSerialInput() {
  while (Serial.available()) {
    const char command = static_cast<char>(Serial.read());
    if (command == '\r' || command == '\n' || command == ' ') {
      continue;
    }

    switch (command) {
      case 'S':
      case 's':
        sweepAll();
        break;
      case '1':
        sweepSlot(0);
        break;
      case '2':
        sweepSlot(1);
        break;
      case '3':
        sweepSlot(2);
        break;
      case 'H':
      case 'h':
        printHelp();
        break;
      default:
        Serial.printf("ERR,UNKNOWN_CMD,%c\n", command);
        break;
    }
  }
}

void setup() {
  Serial.begin(115200);
  delay(300);

  for (int i = 0; i < 3; i++) {
    servos[i].setPeriodHertz(50);
    servos[i].attach(kServoPins[i], 500, 2400);
    servos[i].write(kStartAngle);
  }

  printHelp();
}

void loop() { handleSerialInput(); }
