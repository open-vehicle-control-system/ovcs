#include <Arduino.h>
#include <AnalogPin.h>

namespace AnalogPinTests{
    void testAnalogReadIfAllowedWhenNotEnabled(){
        When(Method(ArduinoFake(), analogRead)).AlwaysReturn(42);
        AnalogPin analogPin = AnalogPin(false, 0);
        int result = analogPin.readIfAllowed();
        Verify(Method(ArduinoFake(), analogRead).Using(0)).Exactly(0);
        TEST_ASSERT_EQUAL_INT(0, result);
    }

    void testAnalogReadIfAllowedWhenEnabled(){
        When(Method(ArduinoFake(), analogRead)).AlwaysReturn(42);
        AnalogPin analogPin = AnalogPin(true, 2);
        int result = analogPin.readIfAllowed();
        Verify(Method(ArduinoFake(), analogRead).Using(2)).Exactly(1);
        TEST_ASSERT_EQUAL_INT(42, result);
    }

    void run_tests(void){
        RUN_TEST(testAnalogReadIfAllowedWhenNotEnabled);
        RUN_TEST(testAnalogReadIfAllowedWhenEnabled);
    }
}