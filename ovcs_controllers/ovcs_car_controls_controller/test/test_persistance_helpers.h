#ifdef UNIT_TEST

#include <PersistanceHelpers.h>

namespace PersistanceHelpersTest{
    void test_update_throttle_high_to_right_address(){
        When(OverloadedMethod(ArduinoFake(EEPROM), update, void(int, uint8_t))).AlwaysReturn();
        save_calibration_data("throttle_high", 255);
        Verify(Method(ArduinoFake(EEPROM), update).Using(1, 255)).Once();
    }

    void test_update_throttle_low_to_right_address(){
        When(OverloadedMethod(ArduinoFake(EEPROM), update, void(int, uint8_t))).AlwaysReturn();
        save_calibration_data("throttle_low", 0);
        Verify(Method(ArduinoFake(EEPROM), update).Using(0, 0)).Once();
    }

    void test_read_throttle_high_reads_to_proper_address(){
        When(OverloadedMethod(ArduinoFake(EEPROM), read, uint8_t(int))).AlwaysReturn();
        read_calibration_data("throttle_high");
        Verify(Method(ArduinoFake(EEPROM), read).Using(1)).Once();
    }

    void test_read_throttle_low_reads_to_proper_address(){
        When(OverloadedMethod(ArduinoFake(EEPROM), read, uint8_t(int))).AlwaysReturn();
        read_calibration_data("throttle_low");
        Verify(Method(ArduinoFake(EEPROM), read).Using(0)).Once();
    }

    void test_read_calibration_data_doesnt_alter_stored_data(){
        When(OverloadedMethod(ArduinoFake(EEPROM), read, uint8_t(int))).Return(255);
        TEST_ASSERT_EQUAL_INT(255, read_calibration_data("throttle_high"));
    }

    void run_tests(void){
        RUN_TEST(test_update_throttle_high_to_right_address);
        RUN_TEST(test_update_throttle_low_to_right_address);
        RUN_TEST(test_read_throttle_high_reads_to_proper_address);
        RUN_TEST(test_read_throttle_low_reads_to_proper_address);
        RUN_TEST(test_read_calibration_data_doesnt_alter_stored_data);
    }
}
#endif