#include <Arduino.h>
#include <GearSelector.h>

namespace GearSelectorTests{
    
    void test_initialize_sets_all_gear_selector_pins_as_input(){
        GearSelector selector = GearSelector();
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), digitalRead)).AlwaysReturn(1);
        selector.initialize();
        Verify(Method(ArduinoFake(), pinMode).Using(GEAR_DRIVE_PIN, INPUT));
        Verify(Method(ArduinoFake(), pinMode).Using(GEAR_NEUTRAL_PIN, INPUT));
        Verify(Method(ArduinoFake(), pinMode).Using(GEAR_REVERSE_PIN, INPUT));
        Verify(Method(ArduinoFake(), pinMode).Using(GEAR_NEUTRAL_PIN, INPUT));
    }

    void test_initialization_fails_if_drive_pin_is_defective(){
        GearSelector selector = GearSelector();
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), digitalRead)).AlwaysReturn(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_DRIVE_PIN)).Return(0);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_NEUTRAL_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_REVERSE_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_PARKING_PIN)).Return(1);
        boolean initialized = selector.initialize();
        TEST_ASSERT(!initialized);
    }

    void test_initialization_fails_if_neutral_pin_is_defective(){
        GearSelector selector = GearSelector();
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), digitalRead)).AlwaysReturn(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_DRIVE_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_NEUTRAL_PIN)).Return(0);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_REVERSE_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_PARKING_PIN)).Return(1);
        boolean initialized = selector.initialize();
        TEST_ASSERT(!initialized);
    }

    void test_initialization_fails_if_reverse_pin_is_defective(){
        GearSelector selector = GearSelector();
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), digitalRead)).AlwaysReturn(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_DRIVE_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_NEUTRAL_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_REVERSE_PIN)).Return(0);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_PARKING_PIN)).Return(1);
        boolean initialized = selector.initialize();
        TEST_ASSERT(!initialized);
    }

    void test_initialization_fails_if_parking_pin_is_defective(){
        GearSelector selector = GearSelector();
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_DRIVE_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_NEUTRAL_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_REVERSE_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_PARKING_PIN)).Return(0);
        boolean initialized = selector.initialize();
        TEST_ASSERT(!initialized);
    }

    void test_gear_selector_returns_drive_when_only_drive_is_selected(){
        GearSelector selector = GearSelector();
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_DRIVE_PIN)).Return(0);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_NEUTRAL_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_REVERSE_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_PARKING_PIN)).Return(1);
        TEST_ASSERT_EQUAL_INT(DRIVE, selector.getGearPosition());
    }
    
    void test_gear_selector_returns_drive_when_only_neutral_is_selected(){
        GearSelector selector = GearSelector();
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_DRIVE_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_NEUTRAL_PIN)).Return(0);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_REVERSE_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_PARKING_PIN)).Return(1);
        TEST_ASSERT_EQUAL_INT(NEUTRAL, selector.getGearPosition());
    }

    void test_gear_selector_returns_drive_when_only_reverse_is_selected(){
        GearSelector selector = GearSelector();
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_DRIVE_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_NEUTRAL_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_REVERSE_PIN)).Return(0);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_PARKING_PIN)).Return(1);
        TEST_ASSERT_EQUAL_INT(REVERSE, selector.getGearPosition());
    }

    void test_gear_selector_returns_drive_when_only_parking_is_selected(){
        GearSelector selector = GearSelector();
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_DRIVE_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_NEUTRAL_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_REVERSE_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_PARKING_PIN)).Return(0);
        TEST_ASSERT_EQUAL_INT(PARKING, selector.getGearPosition());
    }

    void test_gear_selector_returns_default_when_more_than_one_is_selected_at_startup(){
        GearSelector selector = GearSelector();
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_DRIVE_PIN)).Return(0);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_NEUTRAL_PIN)).Return(0);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_REVERSE_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_PARKING_PIN)).Return(1);
        TEST_ASSERT_EQUAL_INT(PARKING, selector.getGearPosition());
    }

    void test_gear_selector_returns_default_when_more_than_one_is_selected_after_gear_shifted(){
        GearSelector selector = GearSelector();
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_DRIVE_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_NEUTRAL_PIN)).Return(0);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_REVERSE_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_PARKING_PIN)).Return(1);
        TEST_ASSERT_EQUAL_INT(NEUTRAL, selector.getGearPosition());

        When(Method(ArduinoFake(), digitalRead).Using(GEAR_DRIVE_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_NEUTRAL_PIN)).Return(1);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_REVERSE_PIN)).Return(0);
        When(Method(ArduinoFake(), digitalRead).Using(GEAR_PARKING_PIN)).Return(0);
        TEST_ASSERT_EQUAL_INT(NEUTRAL, selector.getGearPosition());
    }

    void run_tests(void){
        RUN_TEST(test_initialize_sets_all_gear_selector_pins_as_input);
        RUN_TEST(test_initialization_fails_if_drive_pin_is_defective);
        RUN_TEST(test_initialization_fails_if_neutral_pin_is_defective);
        RUN_TEST(test_initialization_fails_if_reverse_pin_is_defective);
        RUN_TEST(test_initialization_fails_if_parking_pin_is_defective);
        RUN_TEST(test_gear_selector_returns_drive_when_only_drive_is_selected);
        RUN_TEST(test_gear_selector_returns_drive_when_only_neutral_is_selected);
        RUN_TEST(test_gear_selector_returns_drive_when_only_reverse_is_selected);
        RUN_TEST(test_gear_selector_returns_drive_when_only_parking_is_selected);
        RUN_TEST(test_gear_selector_returns_default_when_more_than_one_is_selected_at_startup);
        RUN_TEST(test_gear_selector_returns_default_when_more_than_one_is_selected_after_gear_shifted);
    }
    
}