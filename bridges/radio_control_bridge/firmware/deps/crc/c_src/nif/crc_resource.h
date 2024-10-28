// -*- mode: c++; tab-width: 4; indent-tabs-mode: nil; st-rulers: [132] -*-
// vim: ts=4 sw=4 ft=c++ et

#ifndef CRC_RESOURCE_H
#define CRC_RESOURCE_H

#include "crc_nif.h"
#include "crc_model.h"
#include "crc_algorithm.h"

typedef struct crc_resource_s crc_resource_t;

struct crc_resource_s {
    const crc_resource_t *parent;
    const crc_model_t *model;
    bool slow;
};

#define CRC_RESOURCE_DEF(type)                                                                                                     \
    typedef struct crc_resource_##type##_s crc_resource_##type##_t;                                                                \
    struct crc_resource_##type##_s {                                                                                               \
        const crc_resource_##type##_t *parent;                                                                                     \
        const crc_model_##type##_t *model;                                                                                         \
        bool slow;                                                                                                                 \
        crc_model_state_##type##_t state;                                                                                          \
    };                                                                                                                             \
    typedef struct crc_resource_embed_##type##_s crc_resource_embed_##type##_t;                                                    \
    struct crc_resource_embed_##type##_s {                                                                                         \
        crc_resource_##type##_t super;                                                                                             \
        crc_model_##type##_t model;                                                                                                \
    }

CRC_RESOURCE_DEF(uint8);
CRC_RESOURCE_DEF(uint16);
CRC_RESOURCE_DEF(uint32);
CRC_RESOURCE_DEF(uint64);

#undef CRC_RESOURCE_DEF

#ifdef __cplusplus
extern "C" {
#endif

extern int crc_resource_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info);
extern int crc_resource_upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data, ERL_NIF_TERM load_info);
extern void crc_resource_unload(ErlNifEnv *env, void **priv_data);
extern crc_resource_t *crc_resource_create(const crc_resource_t *parent, const crc_model_t *model, bool slow);
extern crc_resource_t *crc_resource_clone(const crc_resource_t *parent);
extern int crc_resource_get(ErlNifEnv *env, ERL_NIF_TERM resource_term, const crc_resource_t **resource);
extern int crc_resource_update(const crc_resource_t *old_resource, const uint8_t *buf, size_t len, crc_resource_t **new_resource);
extern int crc_resource_update_unsafe(crc_resource_t *resource, const uint8_t *buf, size_t len);
extern int crc_resource_final(const crc_resource_t *resource, void *value);

#ifdef __cplusplus
}
#endif

#endif
