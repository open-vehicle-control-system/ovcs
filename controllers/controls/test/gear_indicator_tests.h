#include <Arduino.h>
#include <TransportMock.h>
#include <GearIndicator.h>

namespace GearIndicatorTests{

    void test_initialize_sets_pinmode_to_relevant_pins(){
        TransportMock mock = TransportMock();
        Mock<TransportMock> TransportMock(mock);
        GearIndicator indicator = GearIndicator(&mock);
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), digitalWrite)).AlwaysReturn();
        indicator.initialize();
        Verify(Method(ArduinoFake(), pinMode).Using(DRIVE_INDICATOR_PIN, OUTPUT));
        Verify(Method(ArduinoFake(), pinMode).Using(NEUTRAL_INDICATOR_PIN, OUTPUT));
        Verify(Method(ArduinoFake(), pinMode).Using(REVERSE_INDICATOR_PIN, OUTPUT));
        Verify(Method(ArduinoFake(), pinMode).Using(PARKING_INDICATOR_PIN, OUTPUT));
    }

    void test_get_validated_gear_position_works_with_drive(){
        TransportMock mock = TransportMock();
        GearIndicator indicator = GearIndicator(&mock);
        Mock<TransportMock> spy(mock);
        When(Method(spy, pullValidatedGear)).Return(DRIVE);
        TEST_ASSERT_EQUAL_INT(DRIVE, indicator.getValidatedGearPosition());
    }


    void test_get_validated_gear_position_works_with_neutral(){
        TransportMock mock = TransportMock();
        GearIndicator indicator = GearIndicator(&mock);
        Mock<TransportMock> spy(mock);
        When(Method(spy, pullValidatedGear)).Return(NEUTRAL);
        TEST_ASSERT_EQUAL_INT(NEUTRAL, indicator.getValidatedGearPosition());
    }

    void test_get_validated_gear_position_works_with_reverse(){
        TransportMock mock = TransportMock();
        GearIndicator indicator = GearIndicator(&mock);
        Mock<TransportMock> spy(mock);
        When(Method(spy, pullValidatedGear)).Return(REVERSE);
        TEST_ASSERT_EQUAL_INT(REVERSE, indicator.getValidatedGearPosition());
    }

    void test_get_validated_gear_position_works_with_parking(){
        TransportMock mock = TransportMock();
        GearIndicator indicator = GearIndicator(&mock);
        Mock<TransportMock> spy(mock);
        When(Method(spy, pullValidatedGear)).Return(PARKING);
        TEST_ASSERT_EQUAL_INT(PARKING, indicator.getValidatedGearPosition());
    }

    void test_indicate_gear_position_write_on_drive_pin_when_drive_validated(){
        TransportMock mock = TransportMock();
        GearIndicator indicator = GearIndicator(&mock);
        Mock<TransportMock> spy(mock);
        When(Method(ArduinoFake(), digitalWrite)).AlwaysReturn();
        indicator.indicateGearPosition(DRIVE);
        Verify(Method(ArduinoFake(), digitalWrite).Using(DRIVE_INDICATOR_PIN, LOW)).Exactly(1); //reset
        Verify(Method(ArduinoFake(), digitalWrite).Using(DRIVE_INDICATOR_PIN, HIGH)).Exactly(1);
    }

    void test_indicate_gear_position_write_on_neutral_pin_when_neutral_validated(){
        TransportMock mock = TransportMock();
        GearIndicator indicator = GearIndicator(&mock);
        Mock<TransportMock> spy(mock);
        When(Method(ArduinoFake(), digitalWrite)).AlwaysReturn();
        indicator.indicateGearPosition(NEUTRAL);
        Verify(Method(ArduinoFake(), digitalWrite).Using(NEUTRAL_INDICATOR_PIN, LOW)).Exactly(1); //reset
        Verify(Method(ArduinoFake(), digitalWrite).Using(NEUTRAL_INDICATOR_PIN, HIGH)).Exactly(1);
    }

    void test_indicate_gear_position_write_on_reverse_pin_when_reverse_validated(){
        TransportMock mock = TransportMock();
        GearIndicator indicator = GearIndicator(&mock);
        Mock<TransportMock> spy(mock);
        When(Method(ArduinoFake(), digitalWrite)).AlwaysReturn();
        indicator.indicateGearPosition(REVERSE);
        Verify(Method(ArduinoFake(), digitalWrite).Using(REVERSE_INDICATOR_PIN, LOW)).Exactly(1); //reset
        Verify(Method(ArduinoFake(), digitalWrite).Using(REVERSE_INDICATOR_PIN, HIGH)).Exactly(1);
    }

    void test_indicate_gear_position_write_on_parking_pin_when_parking_validated(){
        TransportMock mock = TransportMock();
        GearIndicator indicator = GearIndicator(&mock);
        Mock<TransportMock> spy(mock);
        When(Method(ArduinoFake(), digitalWrite)).AlwaysReturn();
        indicator.indicateGearPosition(PARKING);
        Verify(Method(ArduinoFake(), digitalWrite).Using(PARKING_INDICATOR_PIN, LOW)).Exactly(1); //reset
        Verify(Method(ArduinoFake(), digitalWrite).Using(PARKING_INDICATOR_PIN, HIGH)).Exactly(1);
    }

    void run_tests(void){
        RUN_TEST(test_initialize_sets_pinmode_to_relevant_pins);
        RUN_TEST(test_get_validated_gear_position_works_with_drive);
        RUN_TEST(test_get_validated_gear_position_works_with_neutral);
        RUN_TEST(test_get_validated_gear_position_works_with_reverse);
        RUN_TEST(test_get_validated_gear_position_works_with_parking);
        RUN_TEST(test_indicate_gear_position_write_on_drive_pin_when_drive_validated);
        RUN_TEST(test_indicate_gear_position_write_on_neutral_pin_when_neutral_validated);
        RUN_TEST(test_indicate_gear_position_write_on_reverse_pin_when_reverse_validated);
        RUN_TEST(test_indicate_gear_position_write_on_parking_pin_when_parking_validated);

    }
}