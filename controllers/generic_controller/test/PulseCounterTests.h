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

    void testChatterIsIgnored(){
        // A slow pass through the threshold: three edges within 1.5 ms
        // count as one revolution.
        PulseCounter counter;
        counter.recordEdge(1000000);
        counter.recordEdge(1000500);
        counter.recordEdge(1001500);
        TEST_ASSERT_EQUAL_UINT16(1, counter.count());
        counter.recordEdge(1020000);
        TEST_ASSERT_EQUAL_UINT16(2, counter.count());
        TEST_ASSERT_EQUAL_UINT16(500, counter.frequencyDeciHz(1020000));
    }

    void testCountWrapsAt16Bits(){
        PulseCounter counter;
        for (uint32_t i = 0; i < 65537; i++) {
            counter.recordEdge(i * 10000);
        }
        TEST_ASSERT_EQUAL_UINT16(1, counter.count());
    }

    void testFastestAcceptedPeriod(){
        // Exactly the minimum period is accepted and reads 500 Hz, well
        // inside 16 bits of deci-hertz.
        PulseCounter counter;
        counter.recordEdge(1000000);
        counter.recordEdge(1000000 + PULSE_MIN_PERIOD_US);
        TEST_ASSERT_EQUAL_UINT16(5000, counter.frequencyDeciHz(1000000 + PULSE_MIN_PERIOD_US));
    }

    void testMicrosWraparound(){
        // micros() wraps every ~71 minutes; unsigned subtraction keeps
        // the period right across it.
        PulseCounter counter;
        counter.recordEdge(0xFFFFFFF0);
        counter.recordEdge(0x00004E10);  // 20000 us later
        TEST_ASSERT_EQUAL_UINT16(500, counter.frequencyDeciHz(0x00004E10));
    }

    void testEdgeAfterTheClockSampleIsNotAWraparound(){
        // The clock was read one microsecond before the last edge landed.
        PulseCounter counter;
        counter.recordEdge(1000000);
        counter.recordEdge(1020000);
        TEST_ASSERT_EQUAL_UINT16(500, counter.frequencyDeciHz(1019999));
    }

    void testStaysStoppedAcrossAClockWraparound(){
        // Parked for 71.6 minutes: the stale pair must not re-enter the
        // timeout window when the clock comes back around.
        PulseCounter counter;
        counter.recordEdge(1000000);
        counter.recordEdge(1020000);
        TEST_ASSERT_EQUAL_UINT16(0, counter.frequencyDeciHz(1020000 + PULSE_TIMEOUT_US + 1));
        TEST_ASSERT_EQUAL_UINT16(0, counter.frequencyDeciHz(1030000));
        // The first edge after a stop measures the stop, not a period;
        // the second one starts a fresh measurement.
        counter.recordEdge(4000000);
        TEST_ASSERT_EQUAL_UINT16(0, counter.frequencyDeciHz(4000500));
        counter.recordEdge(4020000);
        TEST_ASSERT_EQUAL_UINT16(500, counter.frequencyDeciHz(4020000));
    }

    void run_tests(void){
        RUN_TEST(testEdgeAfterTheClockSampleIsNotAWraparound);
        RUN_TEST(testStaysStoppedAcrossAClockWraparound);
        RUN_TEST(testStoppedBeforeAnyEdge);
        RUN_TEST(testOneEdgeIsNotYetAFrequency);
        RUN_TEST(testFrequencyFromPeriod);
        RUN_TEST(testDecelerationReadsLowerBeforeTheTimeout);
        RUN_TEST(testStoppedAfterTheTimeout);
        RUN_TEST(testChatterIsIgnored);
        RUN_TEST(testCountWrapsAt16Bits);
        RUN_TEST(testFastestAcceptedPeriod);
        RUN_TEST(testMicrosWraparound);
    }
}
