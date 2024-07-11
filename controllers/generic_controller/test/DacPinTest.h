#include <Arduino.h>
#include <DacPin.h>

namespace DacPinTests{
    void testDacWriteIfAllowedWhenNotEnabled(){
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), analogWrite)).AlwaysReturn();
        DacPin dacPin = DacPin(false, 0);
        dacPin.writeIfAllowed(10);
        Verify(Method(ArduinoFake(), pinMode).Using(0, OUTPUT)).Exactly(1);
        Verify(Method(ArduinoFake(), analogWrite).Using(0, 10)).Exactly(0);
    }

    void testDacWriteIfAllowedWhenEnabled(){
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), analogWrite)).AlwaysReturn();
        DacPin dacPin = DacPin(true, 2);
        dacPin.writeIfAllowed(10);
        Verify(Method(ArduinoFake(), pinMode).Using(2, OUTPUT)).Exactly(1);
        Verify(Method(ArduinoFake(), analogWrite).Using(2, 10)).Exactly(1);
    }

    void run_tests(void){
        RUN_TEST(testDacWriteIfAllowedWhenNotEnabled);
        RUN_TEST(testDacWriteIfAllowedWhenEnabled);
    }
}