#include <Arduino.h>
#include <DigitalPin.h>
#include <MockBoard.h>

namespace DigitalPinTests{
    void tesDigitalInitializationWhenDisabled() {
        MockBoard mockBoard = MockBoard();
        Mock<MockBoard> spy(mockBoard);
        When(Method(spy, pinMode)).Return();
        DigitalPin digitalPin = DigitalPin(0, &mockBoard, 0);
        Verify(Method(spy, pinMode).Using(0, OUTPUT)).Exactly(0);
    }

    void tesDigitalInitializationWhenReadOnly() {
        MockBoard mockBoard = MockBoard();
        Mock<MockBoard> spy(mockBoard);
        When(Method(spy, pinMode)).Return();
        DigitalPin digitalPin = DigitalPin(1, &mockBoard, 0);
        Verify(Method(spy, pinMode).Using(0, INPUT)).Exactly(1);
    }

    void tesDigitalInitializationWhenWriteOnly() {
        MockBoard mockBoard = MockBoard();
        Mock<MockBoard> spy(mockBoard);
        When(Method(spy, pinMode)).Return();
        When(Method(spy, digitalWrite)).Return();
        DigitalPin digitalPin = DigitalPin(2, &mockBoard, 0);
        Verify(Method(spy, pinMode).Using(0, OUTPUT)).Exactly(1);
        Verify(Method(spy, digitalWrite).Using(0, 0)).Exactly(1);
    }

    void tesDigitalInitializationWhenReadWrite() {
        MockBoard mockBoard = MockBoard();
        Mock<MockBoard> spy(mockBoard);
        When(Method(spy, pinMode)).Return();
        When(Method(spy, digitalWrite)).Return();
        DigitalPin digitalPin = DigitalPin(3, &mockBoard, 0);
        Verify(Method(spy, pinMode).Using(0, OUTPUT)).Exactly(1);
        Verify(Method(spy, digitalWrite).Using(0, 0)).Exactly(1);
    }

    void tesDigitalWriteIfAllowedWhenDisabled() {
        MockBoard mockBoard = MockBoard();
        DigitalPin digitalPin = DigitalPin(0, &mockBoard, 0);
        Mock<MockBoard> spy(mockBoard);
        When(Method(spy, digitalWrite)).Return();
        digitalPin.writeIfAllowed(1);
        Verify(Method(spy, digitalWrite).Using(0, 1)).Exactly(0);
    }

    void testDigitalWriteIfAllowedWhenReadOnly() {;
        MockBoard mockBoard = MockBoard();
        DigitalPin digitalPin = DigitalPin(1, &mockBoard, 4);
        Mock<MockBoard> spy(mockBoard);
        When(Method(spy, digitalWrite)).Return();
        digitalPin.writeIfAllowed(1);
        Verify(Method(spy, digitalWrite).Using(4, 1)).Exactly(0);
    }

    void testDigitalWriteIfAllowedWhenWriteOnly() {
        MockBoard mockBoard = MockBoard();
        DigitalPin digitalPin = DigitalPin(2, &mockBoard, 2);
        Mock<MockBoard> spy(mockBoard);
        When(Method(spy, digitalWrite)).Return();
        digitalPin.writeIfAllowed(1);
        Verify(Method(spy, digitalWrite).Using(2, 1)).Exactly(1);
    }

    void testDigitalWriteIfAllowedWhenReadWrite() {
        MockBoard mockBoard = MockBoard();
        DigitalPin digitalPin = DigitalPin(3, &mockBoard, 3);
        Mock<MockBoard> spy(mockBoard);
        When(Method(spy, digitalWrite)).Return();
        digitalPin.writeIfAllowed(0);
        Verify(Method(spy, digitalWrite).Using(3, 0)).Exactly(1);
    }

    void tesDigitalReadIfAllowedWhenDisabled() {
        MockBoard mockBoard = MockBoard();
        DigitalPin digitalPin = DigitalPin(0, &mockBoard, 0);
        Mock<MockBoard> spy(mockBoard);
        When(Method(spy, digitalRead)).Return(1);
        uint8_t result = digitalPin.readIfAllowed();
        Verify(Method(spy, digitalRead)).Exactly(0);
        TEST_ASSERT_EQUAL_INT8 (0, result);
    }

    void testDigitalReadIfAllowedWhenReadOnly() {
        MockBoard mockBoard = MockBoard();
        DigitalPin digitalPin = DigitalPin(1, &mockBoard, 0);
        Mock<MockBoard> spy(mockBoard);
        When(Method(spy, digitalRead)).Return(1);
        uint8_t result = digitalPin.readIfAllowed();
        Verify(Method(spy, digitalRead)).Exactly(1);
        TEST_ASSERT_EQUAL_INT8 (1, result);
    }

    void testDigitalReadIfAllowedWhenWriteOnly() {
        MockBoard mockBoard = MockBoard();
        DigitalPin digitalPin = DigitalPin(2, &mockBoard, 0);
        Mock<MockBoard> spy(mockBoard);
        When(Method(spy, digitalRead)).Return(1);
        uint8_t result = digitalPin.readIfAllowed();
        Verify(Method(spy, digitalRead)).Exactly(0);
        TEST_ASSERT_EQUAL_INT8 (0, result);
    }

     void testDigitalReadIfAllowedWhenReadWrite() {
        MockBoard mockBoard = MockBoard();
        DigitalPin digitalPin = DigitalPin(3, &mockBoard, 0);
        Mock<MockBoard> spy(mockBoard);
        When(Method(spy, digitalRead)).Return(1);
        uint8_t result = digitalPin.readIfAllowed();
        Verify(Method(spy, digitalRead)).Exactly(1);
        TEST_ASSERT_EQUAL_INT8 (1, result);
    }

    void test0ValueDigitalReadIfAllowedWhenReadWrite() {
        MockBoard mockBoard = MockBoard();
        DigitalPin digitalPin = DigitalPin(3, &mockBoard, 0);
        Mock<MockBoard> spy(mockBoard);
        When(Method(spy, digitalRead)).Return(0);
        uint8_t result = digitalPin.readIfAllowed();
        Verify(Method(spy, digitalRead)).Exactly(1);
        TEST_ASSERT_EQUAL_INT8 (0, result);
    }

    void run_tests(void){
        RUN_TEST(tesDigitalInitializationWhenDisabled);
        RUN_TEST(tesDigitalInitializationWhenWriteOnly);
        RUN_TEST(tesDigitalInitializationWhenReadOnly);
        RUN_TEST(tesDigitalInitializationWhenReadWrite);

        RUN_TEST(tesDigitalWriteIfAllowedWhenDisabled);
        RUN_TEST(testDigitalWriteIfAllowedWhenReadOnly);
        RUN_TEST(testDigitalWriteIfAllowedWhenWriteOnly);
        RUN_TEST(testDigitalWriteIfAllowedWhenReadWrite);

        RUN_TEST(tesDigitalReadIfAllowedWhenDisabled);
        RUN_TEST(testDigitalReadIfAllowedWhenReadOnly);
        RUN_TEST(testDigitalReadIfAllowedWhenWriteOnly);
        RUN_TEST(testDigitalReadIfAllowedWhenReadWrite);
        RUN_TEST(test0ValueDigitalReadIfAllowedWhenReadWrite);
    }
}