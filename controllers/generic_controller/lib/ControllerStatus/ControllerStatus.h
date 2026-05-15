#ifndef CONTROLLER_STATUS_H
#define CONTROLLER_STATUS_H

enum ControllerStatus {
    STARTING = 0,
    ADOPTION_REQUIRED = 1,
    READY = 2,
    VMS_MISSING_ERROR = 3,
    VMS_LATENCY_ERROR = 4,
    VMS_COUNTER_MISMATCH_ERROR = 5,
    VMS_FAILURE_ERROR = 6,
    EXPANSION_BOARDS_ERROR = 7
};

inline const char* controllerStatusName(ControllerStatus status) {
  switch (status) {
    case STARTING:                   return "STARTING";
    case ADOPTION_REQUIRED:          return "ADOPTION_REQUIRED";
    case READY:                      return "READY";
    case VMS_MISSING_ERROR:          return "VMS_MISSING_ERROR";
    case VMS_LATENCY_ERROR:          return "VMS_LATENCY_ERROR";
    case VMS_COUNTER_MISMATCH_ERROR: return "VMS_COUNTER_MISMATCH_ERROR";
    case VMS_FAILURE_ERROR:          return "VMS_FAILURE_ERROR";
    case EXPANSION_BOARDS_ERROR:     return "EXPANSION_BOARDS_ERROR";
    default:                         return "UNKNOWN";
  }
}

#endif