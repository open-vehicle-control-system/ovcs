// -*- mode: c++; tab-width: 4; indent-tabs-mode: nil; st-rulers: [132] -*-
// vim: ts=4 sw=4 ft=c++ et

#ifndef CRC_MODEL_H
#define CRC_MODEL_H

#include "crc_nif.h"

#define CRC_MODEL_STRING_MAX 32

typedef struct crc_model_stub_s {
    crc_linklist_t _link;
    bool is_root;
    ERL_NIF_TERM root_key;
    char root_keystring[CRC_MODEL_STRING_MAX];
    ERL_NIF_TERM key;
    char keystring[CRC_MODEL_STRING_MAX];
    char name[CRC_MODEL_STRING_MAX];
} crc_model_stub_t;

typedef struct crc_model_s {
    crc_linklist_t _link;
    bool is_root;
    ERL_NIF_TERM root_key;
    char root_keystring[CRC_MODEL_STRING_MAX];
    uint8_t bits;
} crc_model_t;

#define CRC_MODEL_DEF(type)                                                                                                        \
    typedef struct crc_model_state_##type##_s {                                                                                    \
        type##_t value;                                                                                                            \
        type##_t extra;                                                                                                            \
    } crc_model_state_##type##_t;                                                                                                  \
    typedef struct crc_model_##type##_s {                                                                                          \
        crc_model_t super;                                                                                                         \
        bool sick;                                                                                                                 \
        uint8_t width;                                                                                                             \
        type##_t poly;                                                                                                             \
        type##_t init;                                                                                                             \
        bool refin;                                                                                                                \
        bool refout;                                                                                                               \
        type##_t xorout;                                                                                                           \
        type##_t check;                                                                                                            \
        type##_t residue;                                                                                                          \
        type##_t table[256];                                                                                                       \
        type##_t msb_mask;                                                                                                         \
        type##_t crc_mask;                                                                                                         \
        unsigned int crc_shift;                                                                                                    \
    } crc_model_##type##_t

CRC_MODEL_DEF(uint8);
CRC_MODEL_DEF(uint16);
CRC_MODEL_DEF(uint32);
CRC_MODEL_DEF(uint64);

#undef CRC_MODEL_DEF

#ifdef __cplusplus
extern "C" {
#endif

extern int crc_model_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info);
extern int crc_model_upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data, ERL_NIF_TERM load_info);
extern void crc_model_unload(ErlNifEnv *env, void **priv_data);
extern int crc_model_get(ERL_NIF_TERM key, const crc_model_t **model);
extern int crc_model_match(const crc_model_t *needle, const crc_model_t **model);
extern ERL_NIF_TERM crc_model_list(ErlNifEnv *env);
extern int crc_model_init(crc_model_t *model);

#ifdef __cplusplus
}
#endif

#endif
