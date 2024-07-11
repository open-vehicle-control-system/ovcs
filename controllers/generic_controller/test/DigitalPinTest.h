#include <Arduino.h>
#include <DigitalPin.h>

namespace DigitalPinTests{
    void testMainboardDigitalWriteIfAllowedWhenDisabled(){
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), digitalWrite)).AlwaysReturn();
        DigitalPin analogPin = DigitalPin(0, 0, 0);
        analogPin.writeIfAllowed(1);
        Verify(Method(ArduinoFake(), pinMode).Using(0, OUTPUT)).Exactly(0);
        Verify(Method(ArduinoFake(), digitalWrite).Using(0, 1)).Exactly(0);
    }

    void testMainboardDigitalWriteIfAllowedWhenWriteOnly(){
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), digitalWrite)).AlwaysReturn();
        DigitalPin analogPin = DigitalPin(2, 0, 0);
        analogPin.writeIfAllowed(1);
        Verify(Method(ArduinoFake(), pinMode).Using(0, OUTPUT)).Exactly(1);
        Verify(Method(ArduinoFake(), digitalWrite).Using(0, 1)).Exactly(1);
    }

    void testMainboardDigitalWriteIfAllowedWhenReadWrite(){
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), digitalWrite)).AlwaysReturn();
        DigitalPin analogPin = DigitalPin(3, 0, 0);
        analogPin.writeIfAllowed(1);
        Verify(Method(ArduinoFake(), pinMode).Using(0, OUTPUT)).Exactly(1);
        Verify(Method(ArduinoFake(), digitalWrite).Using(0, 1)).Exactly(1);
    }

    void testMainboardDigitalWriteIfAllowedWhenReadOnly(){
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), digitalWrite)).AlwaysReturn();
        DigitalPin analogPin = DigitalPin(1, 0, 0);
        analogPin.writeIfAllowed(1);
        Verify(Method(ArduinoFake(), pinMode).Using(0, INPUT)).Exactly(1);
        Verify(Method(ArduinoFake(), digitalWrite).Using(0, 1)).Exactly(0);
    }

    void testMosfetDigitalWriteIfAllowedWhenDisabled(){
        When(Method(MOSFETBoard1, pinMode1)).AlwaysReturn();
        When(Method(MOSFETBoard1, write1)).AlwaysReturn();
        DigitalPin analogPin = DigitalPin(0, 1, 0);
        analogPin.writeIfAllowed(1);
        Verify(Method(MOSFETBoard1, pinMode1).Using(0, OUTPUT)).Exactly(0);
        Verify(Method(MOSFETBoard1, write1).Using(0, 1)).Exactly(0);
    }

    void run_tests(void){
        RUN_TEST(testMainboardDigitalWriteIfAllowedWhenDisabled);
        RUN_TEST(testMainboardDigitalWriteIfAllowedWhenWriteOnly);
        RUN_TEST(testMainboardDigitalWriteIfAllowedWhenReadWrite);
        RUN_TEST(testMainboardDigitalWriteIfAllowedWhenReadOnly);
        RUN_TEST(testMosfetDigitalWriteIfAllowedWhenDisabled);
    }
}