#include <Arduino.h>
#include <ThrottlePedal.h>

namespace ThrottlePedalTests{
    void test_initialize_sets_analog_pins_as_input(){
        ThrottlePedal pedal = ThrottlePedal();
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        pedal.initialize();
        Verify(Method(ArduinoFake(), pinMode).Using(THROTTLE_PEDAL_PIN_1, INPUT)).Once();
        Verify(Method(ArduinoFake(), pinMode).Using(THROTTLE_PEDAL_PIN_2, INPUT)).Once();
    }

    void test_readValues_sets_resolution_to_what_VMSU_expects(){
        ThrottlePedal pedal = ThrottlePedal();
        When(Method(ArduinoFake(), analogRead)).AlwaysReturn(42);
        When(Method(ArduinoFake(), analogReadResolution)).Return();
        int expectedResolutionByVMSinBits = 14;
        pedal.readValues();
        Verify(Method(ArduinoFake(), analogReadResolution).Using(expectedResolutionByVMSinBits)).Once();
    }

    void test_readValues_returns_the_analogRead_values_without_modification(){
        ThrottlePedal pedal = ThrottlePedal();
        When(Method(ArduinoFake(), analogRead)).AlwaysReturn(42);
        When(Method(ArduinoFake(), analogReadResolution)).Return();
        AnalogValues values = pedal.readValues();
        TEST_ASSERT_EQUAL_INT(42, values.pin_1);
        TEST_ASSERT_EQUAL_INT(42, values.pin_2);
    }

    void run_tests(void){
        RUN_TEST(test_initialize_sets_analog_pins_as_input);
        RUN_TEST(test_readValues_sets_resolution_to_what_VMSU_expects);
        RUN_TEST(test_readValues_returns_the_analogRead_values_without_modification);
    }
}