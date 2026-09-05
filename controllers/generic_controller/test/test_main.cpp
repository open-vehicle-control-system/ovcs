#include <unity.h>
#include <fakeit.hpp>
#include <Arduino.h>
using namespace fakeit;

#include <PwmPinTests.h>
#include <DacPinTests.h>
#include <AnalogPinTests.h>
#include <AdoptionButtonTests.h>
#include <DigitalPinTests.h>
#include <PulseCounterTests.h>


#define RUN_TEST_GROUP(TEST) \
    if (!std::getenv("TEST_GROUP") || (strcmp(#TEST, std::getenv("TEST_GROUP")) == 0)) { \
        TEST::run_tests(); \
    }

void setUp(void)
{
  ArduinoFakeReset();
}

void tearDown(void)
{
}

int main()
{
  UNITY_BEGIN();
  RUN_TEST_GROUP(PwmPinTests);
  RUN_TEST_GROUP(DacPinTests);
  RUN_TEST_GROUP(AnalogPinTests);
  RUN_TEST_GROUP(AdoptionButtonTests);
  RUN_TEST_GROUP(DigitalPinTests);
  RUN_TEST_GROUP(PulseCounterTests);
  return UNITY_END();
}