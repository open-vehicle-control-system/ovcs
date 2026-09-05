#include <PulseCounter.h>

namespace PulseCounterTests{
    void testStoppedBeforeAnyEdge(){
        PulseCounter counter;
        TEST_ASSERT_EQUAL_UINT16(0, counter.count());
        TEST_ASSERT_EQUAL_UINT16(0, counter.frequencyDeciHz(5000000));
    }

    void testOneEdgeIsNotYetAFrequency(){
        PulseCounter counter;
        counter.recordEdge(1000000);
        TEST_ASSERT_EQUAL_UINT16(1, counter.count());
        TEST_ASSERT_EQUAL_UINT16(0, counter.frequencyDeciHz(1000500));
    }

    void testFrequencyFromPeriod(){
        // 20 ms between edges: 50 Hz, reported as 500 deci-hertz.
        PulseCounter counter;
        counter.recordEdge(1000000);
        counter.recordEdge(1020000);
        TEST_ASSERT_EQUAL_UINT16(2, counter.count());
        TEST_ASSERT_EQUAL_UINT16(500, counter.frequencyDeciHz(1025000));
    }

    void testDecelerationReadsLowerBeforeTheTimeout(){
        // Last period 20 ms, but 100 ms have passed since the last edge:
        // the wheel cannot be turning faster than 10 Hz.
        PulseCounter counter;
        counter.recordEdge(1000000);
        counter.recordEdge(1020000);
        TEST_ASSERT_EQUAL_UINT16(100, counter.frequencyDeciHz(1120000));
    }

    void testStoppedAfterTheTimeout(){
        PulseCounter counter;
        counter.recordEdge(1000000);
        counter.recordEdge(1020000);
        TEST_ASSERT_EQUAL_UINT16(0, counter.frequencyDeciHz(1020000 + PULSE_TIMEOUT_US + 1));
    }

    void testBounceIsIgnored(){
        PulseCounter counter;
        counter.recordEdge(1000000);
        counter.recordEdge(1000010);
        TEST_ASSERT_EQUAL_UINT16(1, counter.count());
        counter.recordEdge(1020000);
        TEST_ASSERT_EQUAL_UINT16(500, counter.frequencyDeciHz(1020000));
    }

    void testCountWrapsAt16Bits(){
        PulseCounter counter;
        for (uint32_t i = 0; i < 65537; i++) {
            counter.recordEdge(i * 1000);
        }
        TEST_ASSERT_EQUAL_UINT16(1, counter.count());
    }

    void testFrequencySaturates(){
        // 150 us period is 6666.6 Hz, above what 16 bits of deci-hertz hold.
        PulseCounter counter;
        counter.recordEdge(1000000);
        counter.recordEdge(1000150);
        TEST_ASSERT_EQUAL_UINT16(65535, counter.frequencyDeciHz(1000150));
    }

    void testMicrosWraparound(){
        // micros() wraps every ~71 minutes; unsigned subtraction keeps
        // the period right across it.
        PulseCounter counter;
        counter.recordEdge(0xFFFFFFF0);
        counter.recordEdge(0x00004E10);  // 20000 us later
        TEST_ASSERT_EQUAL_UINT16(500, counter.frequencyDeciHz(0x00004E10));
    }

    void run_tests(void){
        RUN_TEST(testStoppedBeforeAnyEdge);
        RUN_TEST(testOneEdgeIsNotYetAFrequency);
        RUN_TEST(testFrequencyFromPeriod);
        RUN_TEST(testDecelerationReadsLowerBeforeTheTimeout);
        RUN_TEST(testStoppedAfterTheTimeout);
        RUN_TEST(testBounceIsIgnored);
        RUN_TEST(testCountWrapsAt16Bits);
        RUN_TEST(testFrequencySaturates);
        RUN_TEST(testMicrosWraparound);
    }
}
