#include <ExternalPwm.h>

namespace ExternalPwmTests{
    // A request identical to the current state must not be relayed: the
    // VMS retransmits unchanged frames every 10 ms.
    void testIdenticalRequestDoesNotDiffer(){
        ExternalPwm current(0, true, 32767, 50);
        ExternalPwm request(0, true, 32767, 50);
        TEST_ASSERT_FALSE(current.differsFrom(request));
    }

    void testDutyCycleChangeDiffers(){
        ExternalPwm current(0, true, 32767, 50);
        ExternalPwm request(0, true, 40000, 50);
        TEST_ASSERT_TRUE(current.differsFrom(request));
    }

    void testEnabledChangeDiffers(){
        ExternalPwm current(0, true, 32767, 50);
        ExternalPwm request(0, false, 32767, 50);
        TEST_ASSERT_TRUE(current.differsFrom(request));
    }

    void testFrequencyChangeDiffers(){
        ExternalPwm current(0, true, 32767, 50);
        ExternalPwm request(0, true, 32767, 60);
        TEST_ASSERT_TRUE(current.differsFrom(request));
    }

    // Applying a request makes the next identical one a no-op.
    void testUpdateAbsorbsTheDifference(){
        ExternalPwm current(0, false, 0, 0);
        ExternalPwm request(0, true, 32767, 50);
        TEST_ASSERT_TRUE(current.differsFrom(request));
        current.update(request, 1000);
        TEST_ASSERT_FALSE(current.differsFrom(request));
    }

    void testChangedRequestIsRelayedImmediately(){
        ExternalPwm current(0, true, 32767, 50);
        current.update(current, 1000);
        ExternalPwm request(0, true, 40000, 50);
        TEST_ASSERT_TRUE(current.needsRelay(request, 1001));
    }

    // An identical request is held back until the refresh interval has
    // elapsed since the last packet, then resent once.
    void testIdenticalRequestIsRefreshedAtTheSlowRate(){
        ExternalPwm current(0, true, 32767, 50);
        current.update(current, 1000);
        ExternalPwm request(0, true, 32767, 50);
        TEST_ASSERT_FALSE(current.needsRelay(request, 1010));
        TEST_ASSERT_FALSE(current.needsRelay(request, 1000 + EXTERNAL_PWM_REFRESH_INTERVAL_MS - 1));
        TEST_ASSERT_TRUE(current.needsRelay(request, 1000 + EXTERNAL_PWM_REFRESH_INTERVAL_MS));
        current.update(request, 1000 + EXTERNAL_PWM_REFRESH_INTERVAL_MS);
        TEST_ASSERT_FALSE(current.needsRelay(request, 1000 + EXTERNAL_PWM_REFRESH_INTERVAL_MS + 10));
    }

    // millis() wraps after ~49 days; the refresh must still fire.
    void testRefreshSurvivesMillisWrapAround(){
        ExternalPwm current(0, true, 32767, 50);
        unsigned long beforeWrap = (unsigned long) -50;
        current.update(current, beforeWrap);
        ExternalPwm request(0, true, 32767, 50);
        TEST_ASSERT_FALSE(current.needsRelay(request, 10));
        TEST_ASSERT_TRUE(current.needsRelay(request, 60));
    }

    void run_tests(){
        RUN_TEST(testIdenticalRequestDoesNotDiffer);
        RUN_TEST(testDutyCycleChangeDiffers);
        RUN_TEST(testEnabledChangeDiffers);
        RUN_TEST(testFrequencyChangeDiffers);
        RUN_TEST(testUpdateAbsorbsTheDifference);
        RUN_TEST(testChangedRequestIsRelayedImmediately);
        RUN_TEST(testIdenticalRequestIsRefreshedAtTheSlowRate);
        RUN_TEST(testRefreshSurvivesMillisWrapAround);
    }
}
