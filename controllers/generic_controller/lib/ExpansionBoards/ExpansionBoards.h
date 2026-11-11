#ifndef EXPANSION_BOARDS_H
#define EXPANSION_BOARDS_H

#include <AbstractBoard.h>

// Begins each board in use; false if any of them failed to begin.
bool beginExpansionBoards(AbstractBoard* board1, bool board1InUse, AbstractBoard* board2, bool board2InUse);

#endif
