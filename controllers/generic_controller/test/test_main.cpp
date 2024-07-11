#include <unity.h>
#include <fakeit.hpp>
#include <Arduino.h>

using namespace fakeit;

#include <PwmPinTest.h>
#include <DacPinTest.h>
#include <AnalogPinTest.h>
#include <AdoptionButtonTest.h>
#include <DigitalPinTest.h>


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
  RUN_TEST_GROUP(PwmPinTests);
  RUN_TEST_GROUP(DacPinTests);
  RUN_TEST_GROUP(AnalogPinTests);
  RUN_TEST_GROUP(AdoptionButtonTests);
  RUN_TEST_GROUP(DigitalPinTests);
  return UNITY_END();
}