#include <ExpansionBoards.h>

bool beginExpansionBoards(AbstractBoard* board1, bool board1InUse, AbstractBoard* board2, bool board2InUse) {
  bool board1Began = !board1InUse || board1->begin();
  bool board2Began = !board2InUse || board2->begin();
  return board1Began && board2Began;
};
