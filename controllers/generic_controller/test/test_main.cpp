#include <unity.h>
#include <fakeit.hpp>
#include <Arduino.h>

using namespace fakeit;



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

  return UNITY_END();
}