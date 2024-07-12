#include <Arduino.h>
#include <DigitalPin.h>
#include <MockBoard.h>

namespace DigitalPinTests{
    void tesDigitalWriteIfAllowedWhenDisabled(){
         MockBoard mockBoard = MockBoard();
         DigitalPin digitalPin = DigitalPin(0, &mockBoard, 0);
        Mock<MockBoard> spy(mockBoard);
        When(Method(spy, digitalWrite)).Return();
        digitalPin.writeIfAllowed(1);
        Verify(Method(spy, digitalWrite).Using(0, 1)).Exactly(0);
    }

    void testDigitalWriteIfAllowedWhenWriteOnly(){
        MockBoard mockBoard = MockBoard();
        DigitalPin digitalPin = DigitalPin(2, &mockBoard, 2);
        Mock<MockBoard> spy(mockBoard);
        When(Method(spy, digitalWrite)).Return();
        digitalPin.writeIfAllowed(1);
        Verify(Method(spy, digitalWrite).Using(2, 1)).Exactly(1);
    }

    void testDigitalWriteIfAllowedWhenReadWrite(){
        MockBoard mockBoard = MockBoard();
        DigitalPin digitalPin = DigitalPin(3, &mockBoard, 3);
        Mock<MockBoard> spy(mockBoard);
        When(Method(spy, digitalWrite)).Return();
        digitalPin.writeIfAllowed(0);
        Verify(Method(spy, digitalWrite).Using(3, 0)).Exactly(1);
    }

    void testDigitalWriteIfAllowedWhenReadOnly(){;
        MockBoard mockBoard = MockBoard();
        DigitalPin digitalPin = DigitalPin(3, &mockBoard, 4);
        Mock<MockBoard> spy(mockBoard);
        When(Method(spy, digitalWrite)).Return();
        digitalPin.writeIfAllowed(1);
        Verify(Method(spy, digitalWrite).Using(4, 0)).Exactly(0);
    }


    void run_tests(void){
        RUN_TEST(tesDigitalWriteIfAllowedWhenDisabled);
        RUN_TEST(testDigitalWriteIfAllowedWhenWriteOnly);
        RUN_TEST(testDigitalWriteIfAllowedWhenReadWrite);
        RUN_TEST(testDigitalWriteIfAllowedWhenReadOnly);
    }
}