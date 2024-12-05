#ifndef VMS_COMMAND_H
#define VMS_COMMAND_H

#include <Arduino.h>

enum Command {
    NONE = 0x00,
    RESET_GENERIC_CONTROLLERS = 0x01
};

struct VmsCommand {
    Command command = NONE;
};

#endif
