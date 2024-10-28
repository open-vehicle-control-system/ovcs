// -*- mode: c++; tab-width: 4; indent-tabs-mode: nil; st-rulers: [132] -*-
// vim: ts=4 sw=4 ft=c++ et

#ifndef CRC_8_H
#define CRC_8_H

#include <stdlib.h>
#include <stdint.h>

#include "crc_nif.h"

#ifdef __cplusplus
extern "C" {
#endif

extern uint8_t crc_8_init(uint8_t seed);
extern uint8_t crc_8_update(uint8_t ctx, const unsigned char *buf, size_t len);
extern uint8_t crc_8_final(uint8_t ctx);
static uint8_t crc_8(uint8_t seed, const unsigned char *buf, size_t len);

inline uint8_t
crc_8(uint8_t seed, const unsigned char *buf, size_t len)
{
    uint8_t ctx;
    ctx = crc_8_init(seed);
    ctx = crc_8_update(ctx, buf, len);
    return crc_8_final(ctx);
}

/* NIF Functions */

extern ERL_NIF_TERM crc_nif_crc_8_2(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM crc_nif_crc_8_init_1(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM crc_nif_crc_8_update_2(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM crc_nif_crc_8_final_1(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

#ifdef __cplusplus
}
#endif

#endif
