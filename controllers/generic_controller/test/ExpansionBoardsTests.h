#include <Arduino.h>
#include <ExpansionBoards.h>
#include <MockBoard.h>

namespace ExpansionBoardsTests{
    void testBeginsTheBoardsInUse() {
        MockBoard board1 = MockBoard();
        MockBoard board2 = MockBoard();
        Mock<MockBoard> spy1(board1);
        Mock<MockBoard> spy2(board2);
        When(Method(spy1, begin)).AlwaysReturn(true);
        When(Method(spy2, begin)).AlwaysReturn(true);
        bool result = beginExpansionBoards(&board1, true, &board2, true);
        Verify(Method(spy1, begin)).Exactly(1);
        Verify(Method(spy2, begin)).Exactly(1);
        TEST_ASSERT_TRUE(result);
    }

    void testFailsWhenABoardInUseFailsToBegin() {
        MockBoard board1 = MockBoard();
        MockBoard board2 = MockBoard();
        Mock<MockBoard> spy1(board1);
        Mock<MockBoard> spy2(board2);
        When(Method(spy1, begin)).AlwaysReturn(true);
        When(Method(spy2, begin)).AlwaysReturn(false);
        bool result = beginExpansionBoards(&board1, true, &board2, true);
        TEST_ASSERT_FALSE(result);
    }

    void testBeginsTheSecondBoardWhenTheFirstFails() {
        MockBoard board1 = MockBoard();
        MockBoard board2 = MockBoard();
        Mock<MockBoard> spy1(board1);
        Mock<MockBoard> spy2(board2);
        When(Method(spy1, begin)).AlwaysReturn(false);
        When(Method(spy2, begin)).AlwaysReturn(true);
        bool result = beginExpansionBoards(&board1, true, &board2, true);
        Verify(Method(spy2, begin)).Exactly(1);
        TEST_ASSERT_FALSE(result);
    }

    void testIgnoresTheFirstBoardWhenNotInUse() {
        MockBoard board1 = MockBoard();
        MockBoard board2 = MockBoard();
        Mock<MockBoard> spy1(board1);
        Mock<MockBoard> spy2(board2);
        When(Method(spy1, begin)).AlwaysReturn(false);
        When(Method(spy2, begin)).AlwaysReturn(true);
        bool result = beginExpansionBoards(&board1, false, &board2, true);
        Verify(Method(spy1, begin)).Exactly(0);
        Verify(Method(spy2, begin)).Exactly(1);
        TEST_ASSERT_TRUE(result);
    }

    void testIgnoresTheSecondBoardWhenNotInUse() {
        MockBoard board1 = MockBoard();
        MockBoard board2 = MockBoard();
        Mock<MockBoard> spy1(board1);
        Mock<MockBoard> spy2(board2);
        When(Method(spy1, begin)).AlwaysReturn(true);
        When(Method(spy2, begin)).AlwaysReturn(false);
        bool result = beginExpansionBoards(&board1, true, &board2, false);
        Verify(Method(spy1, begin)).Exactly(1);
        Verify(Method(spy2, begin)).Exactly(0);
        TEST_ASSERT_TRUE(result);
    }

    void run_tests(void){
        RUN_TEST(testBeginsTheBoardsInUse);
        RUN_TEST(testFailsWhenABoardInUseFailsToBegin);
        RUN_TEST(testBeginsTheSecondBoardWhenTheFirstFails);
        RUN_TEST(testIgnoresTheFirstBoardWhenNotInUse);
        RUN_TEST(testIgnoresTheSecondBoardWhenNotInUse);
    }
}
