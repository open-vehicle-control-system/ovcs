#include <unity.h>
#include <fakeit.hpp>
#include <Arduino.h>

using namespace fakeit;

#include <gear_selector_tests.h>
#include <throttle_pedal_tests.h>
#include <gear_indicator_tests.h>

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
  // clean stuff up here
}

int main()
{
  UNITY_BEGIN(); // IMPORTANT LINE!
  RUN_TEST_GROUP(GearSelectorTests);
  RUN_TEST_GROUP(ThrottlePedalTests);
  RUN_TEST_GROUP(GearIndicatorTests);
  return UNITY_END();
}