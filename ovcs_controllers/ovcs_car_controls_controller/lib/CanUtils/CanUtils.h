#ifndef CanUtils_h
#define CanUtils_h

#include <SPI.h>
#include <mcp2515.h>

boolean initialize_can(MCP2515 canbus);
void send_throttle_message(MCP2515 canbus, int value);
can_frame read_can_message(MCP2515 canbus, int id);

#endif