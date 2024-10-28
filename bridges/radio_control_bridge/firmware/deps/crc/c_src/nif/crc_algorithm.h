// -*- mode: c++; tab-width: 4; indent-tabs-mode: nil; st-rulers: [132] -*-
// vim: ts=4 sw=4 ft=c++ et

#ifndef CRC_ALGORITHM_H
#define CRC_ALGORITHM_H

#include "crc_nif.h"
#include "crc_model.h"

#ifdef __cplusplus
extern "C" {
#endif

extern int crc_algorithm_reflect(const crc_model_t *model, void *value, uint8_t width);
extern int crc_algorithm_compile(crc_model_t *model);
extern int crc_algorithm_init(const crc_model_t *model, bool slow, void *state);
extern int crc_algorithm_update(const crc_model_t *model, bool slow, const uint8_t *buf, size_t len, void *state);
extern int crc_algorithm_final(const crc_model_t *model, bool slow, void *state);
extern int crc_algorithm_residue(const crc_model_t *model, void *state);

#ifdef __cplusplus
}
#endif

#endif
