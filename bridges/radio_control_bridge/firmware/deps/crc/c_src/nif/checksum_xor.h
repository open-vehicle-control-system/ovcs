// -*- mode: c++; tab-width: 4; indent-tabs-mode: nil; st-rulers: [132] -*-
// vim: ts=4 sw=4 ft=c++ et

#ifndef CHECKSUM_XOR_H
#define CHECKSUM_XOR_H

#include <stdlib.h>
#include <stdint.h>

#include "crc_nif.h"

#ifdef __cplusplus
extern "C" {
#endif

extern uint8_t checksum_xor(uint8_t sum, const unsigned char *buf, size_t len);

/* NIF Functions */

extern ERL_NIF_TERM crc_nif_checksum_xor_1(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

#ifdef __cplusplus
}
#endif

#endif
