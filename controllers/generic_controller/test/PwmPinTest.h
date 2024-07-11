#include <Arduino.h>
#include <PwmPin.h>

namespace PwmPinTests{
    void testWriteIfAllowedWhenNotEnabled(){
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), analogWrite)).AlwaysReturn();
        PwmPin pwmPin = PwmPin(false, 0);
        pwmPin.writeIfAllowed(10);
        Verify(Method(ArduinoFake(), pinMode).Using(0, OUTPUT)).Exactly(1);
        Verify(Method(ArduinoFake(), analogWrite).Using(0, 10)).Exactly(0);
    }

    void testWriteIfAllowedWhenEnabled(){
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), analogWrite)).AlwaysReturn();
        PwmPin pwmPin = PwmPin(true, 2);
        pwmPin.writeIfAllowed(10);
        Verify(Method(ArduinoFake(), pinMode).Using(2, OUTPUT)).Exactly(1);
        Verify(Method(ArduinoFake(), analogWrite).Using(2, 10)).Exactly(1);
    }

    void run_tests(void){
        RUN_TEST(testWriteIfAllowedWhenNotEnabled);
        RUN_TEST(testWriteIfAllowedWhenEnabled);
    }
}