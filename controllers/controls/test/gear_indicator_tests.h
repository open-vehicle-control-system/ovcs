#include <Arduino.h>
#include <TransportMock.h>
#include <GearIndicator.h>

namespace GearIndicatorTests{

    void test_initialize_sets_pinmode_to_relevant_pins(){
        TransportMock mock = TransportMock();
        GearIndicator indicator = GearIndicator(&mock);
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), digitalWrite)).AlwaysReturn();
        indicator.initialize();
        Verify(Method(ArduinoFake(), pinMode).Using(DRIVE_INDICATOR_PIN, OUTPUT));
        Verify(Method(ArduinoFake(), pinMode).Using(NEUTRAL_INDICATOR_PIN, OUTPUT));
        Verify(Method(ArduinoFake(), pinMode).Using(REVERSE_INDICATOR_PIN, OUTPUT));
        Verify(Method(ArduinoFake(), pinMode).Using(PARKING_INDICATOR_PIN, OUTPUT));
    }

    void run_tests(void){
        RUN_TEST(test_initialize_sets_pinmode_to_relevant_pins);
    }
}