#ifdef UNIT_TEST

#include <ConvertionUtils.h>

namespace ConversionUtilsTest{
    void test_convert_throttle_to_max_range_no_throttle(){
        int value = 0;
        int calibration_low = 0;
        int calibration_high = 255;
        TEST_ASSERT_EQUAL_INT(0, convert_throttle_to_max_range(value, calibration_low, calibration_high));
    }

    void test_convert_throttle_to_max_range_max_throttle(){
        int value = 1023;
        int calibration_low = 0;
        int calibration_high = 255;
        TEST_ASSERT_EQUAL_INT(255, convert_throttle_to_max_range(value, calibration_low, calibration_high));
    }

    void test_convert_throttle_to_max_range_half_throttle(){
        int value = 511;
        int calibration_low = 0;
        int calibration_high = 255;
        TEST_ASSERT_EQUAL_INT(127, convert_throttle_to_max_range(value, calibration_low, calibration_high));
    }

    void test_convert_throttle_to_max_range_10_percent_throttle(){
        int value = 102;
        int calibration_low = 0;
        int calibration_high = 255;
        TEST_ASSERT_EQUAL_INT(25, convert_throttle_to_max_range(value, calibration_low, calibration_high));
    }

    void test_convert_throttle_to_max_range_no_throttle_low_different_than_0(){
        int value = 60;
        int calibration_low = 15;
        int calibration_high = 255;
        TEST_ASSERT_EQUAL_INT(0, convert_throttle_to_max_range(value, calibration_low, calibration_high));
    }

    void test_convert_throttle_to_max_range_max_throttle_high_different_than_255(){
        int value = 800;
        int calibration_low = 0;
        int calibration_high = 200;
        TEST_ASSERT_EQUAL_INT(255, convert_throttle_to_max_range(value, calibration_low, calibration_high));
    }

    void test_convert_throttle_to_max_range_max_throttle_half_low_not_0_and_high_bot_255(){
        int value = 600;
        int calibration_low = 100;
        int calibration_high = 200;
        TEST_ASSERT_EQUAL_INT(127, convert_throttle_to_max_range(value, calibration_low, calibration_high));
    }

    void run_tests(void){
        RUN_TEST(ConversionUtilsTest::test_convert_throttle_to_max_range_no_throttle);
        RUN_TEST(ConversionUtilsTest::test_convert_throttle_to_max_range_max_throttle);
        RUN_TEST(ConversionUtilsTest::test_convert_throttle_to_max_range_half_throttle);
        RUN_TEST(ConversionUtilsTest::test_convert_throttle_to_max_range_10_percent_throttle);
        RUN_TEST(ConversionUtilsTest::test_convert_throttle_to_max_range_no_throttle_low_different_than_0);
        RUN_TEST(ConversionUtilsTest::test_convert_throttle_to_max_range_max_throttle_high_different_than_255);
        RUN_TEST(ConversionUtilsTest::test_convert_throttle_to_max_range_max_throttle_half_low_not_0_and_high_bot_255);
    }
}
#endif