#include <Arduino.h>
#include <ContactorsMcp2515.h>

#define MAIN_NEGATIVE_CONTACTOR_RELAY_PIN 4
#define MAIN_POSITIVE_CONTACTOR_RELAY_PIN 8
#define PRECHARGE_CONTACTOR_RELAY_PIN 7

int mainNegativeContactorRequestedState = 0;
int mainPositiveRequestedContactor = 0;
int prechargeContactorRequestedState = 0;

ContactorsMcp2515 transport = ContactorsMcp2515();

void receive_frame() {
  ContactorsRequestedStatuses requestedStatuses;
  requestedStatuses = transport.pullContactorsStatuses();
  mainNegativeContactorRequestedState = requestedStatuses.mainNegativeContactorRequestedState;
  mainPositiveRequestedContactor = requestedStatuses.mainPositiveRequestedContactor;
  prechargeContactorRequestedState = requestedStatuses.prechargeContactorRequestedState;
}

void actuate_relays() {
  digitalWrite(MAIN_NEGATIVE_CONTACTOR_RELAY_PIN, mainNegativeContactorRequestedState == 1 ? HIGH : LOW);
  digitalWrite(MAIN_POSITIVE_CONTACTOR_RELAY_PIN, mainPositiveRequestedContactor == 1 ? HIGH : LOW);
  digitalWrite(PRECHARGE_CONTACTOR_RELAY_PIN, prechargeContactorRequestedState == 1 ? HIGH : LOW);
}

void send_status() {
  int mainNegativeRelayPin = digitalRead(MAIN_NEGATIVE_CONTACTOR_RELAY_PIN);
  int mainPositiveRelayPin = digitalRead(MAIN_POSITIVE_CONTACTOR_RELAY_PIN);
  int prechargeRelayPin = digitalRead(PRECHARGE_CONTACTOR_RELAY_PIN);
  transport.sendFrame(mainNegativeRelayPin, mainPositiveRelayPin, prechargeRelayPin);
}

void setup() {
  Serial.begin(9600);
  transport.initialize();
  pinMode(MAIN_NEGATIVE_CONTACTOR_RELAY_PIN, OUTPUT);
  pinMode(MAIN_POSITIVE_CONTACTOR_RELAY_PIN, OUTPUT);
  pinMode(PRECHARGE_CONTACTOR_RELAY_PIN, OUTPUT);
  actuate_relays();
}

void loop() {
  receive_frame();
  actuate_relays();
  send_status();
}

