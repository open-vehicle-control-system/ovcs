#include <Arduino.h>
#include <AdoptionButton.h>

namespace AdoptionButtonTests{
    void testWaitingForAdoptionWhenButtonPressed(){
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), digitalRead)).AlwaysReturn(1);
        AdoptionButton button = AdoptionButton();
        bool result = button.isWaitingAdoption();
        Verify(Method(ArduinoFake(), pinMode).Using(2, INPUT)).Exactly(1);
        Verify(Method(ArduinoFake(), digitalRead).Using(2)).Exactly(1);
        TEST_ASSERT_TRUE(result);
    }

    void testNotWaitingAdoptionWhenButtonNotPressed(){
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), digitalRead)).AlwaysReturn(0);
        AdoptionButton button = AdoptionButton();
        bool result = button.isWaitingAdoption();
        Verify(Method(ArduinoFake(), pinMode).Using(2, INPUT)).Exactly(1);
        Verify(Method(ArduinoFake(), digitalRead).Using(2)).Exactly(1);
        TEST_ASSERT_FALSE(result);
    }

    void testNotWaitingAdoptionAfterAdoptionValidated(){
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), digitalRead)).Return(1);

        AdoptionButton button = AdoptionButton();
        bool result = button.isWaitingAdoption();
        TEST_ASSERT_TRUE(result);
        button.validateAdoption();
        When(Method(ArduinoFake(), digitalRead)).Return(0);
        result = button.isWaitingAdoption();
        TEST_ASSERT_FALSE(result);
    }

    void testDontReadoptWhenButtonIsLongPressed(){
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), digitalRead)).AlwaysReturn(1);

        AdoptionButton button = AdoptionButton();
        bool result = button.isWaitingAdoption();
        TEST_ASSERT_TRUE(result);
        button.validateAdoption();
        result = button.isWaitingAdoption();
        TEST_ASSERT_FALSE(result);
    }

    void testAllowReadoptionAfterButtonReleasedAndPressed(){
        When(Method(ArduinoFake(), pinMode)).AlwaysReturn();
        When(Method(ArduinoFake(), digitalRead)).Return(1);

        AdoptionButton button = AdoptionButton();
        bool result = button.isWaitingAdoption();
        TEST_ASSERT_TRUE(result);

        button.validateAdoption();

        When(Method(ArduinoFake(), digitalRead)).Return(0);
        result = button.isWaitingAdoption();
        TEST_ASSERT_FALSE(result);

        When(Method(ArduinoFake(), digitalRead)).Return(1);
        result = button.isWaitingAdoption();
        TEST_ASSERT_TRUE(result);
    }

    void run_tests(void){
        RUN_TEST(testWaitingForAdoptionWhenButtonPressed);
        RUN_TEST(testNotWaitingAdoptionWhenButtonNotPressed);
        RUN_TEST(testNotWaitingAdoptionAfterAdoptionValidated);
        RUN_TEST(testDontReadoptWhenButtonIsLongPressed);
        RUN_TEST(testAllowReadoptionAfterButtonReleasedAndPressed);
    }
}