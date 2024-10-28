// -*- mode: c++; tab-width: 4; indent-tabs-mode: nil; st-rulers: [132] -*-
// vim: ts=4 sw=4 ft=c++ et

#include "crc_model.h"

#ifndef kcalloc
#define kcalloc(N, Z) memset(enif_alloc((N) * (Z)), 0, (N) * (Z))
#endif
#ifndef kmalloc
#define kmalloc(Z) enif_alloc(Z)
#endif
#ifndef krealloc
#define krealloc(P, Z) enif_realloc(P, Z)
#endif
#ifndef kfree
#define kfree(P) enif_free(P)
#endif

#include "khash.h"

#if ULONG_MAX == ULLONG_MAX
KHASH_MAP_INIT_INT64(crc_stubs, const crc_model_stub_t *)
KHASH_MAP_INIT_INT64(crc_models, const crc_model_t *)
#else
KHASH_MAP_INIT_INT(crc_stubs, const crc_model_stub_t *)
KHASH_MAP_INIT_INT(crc_models, const crc_model_t *)
#endif

static khash_t(crc_stubs) *crc_model_lut = NULL;
static khash_t(crc_models) *crc_model_map = NULL;

#include "crc_model_uint8.c.h"
#include "crc_model_uint16.c.h"
#include "crc_model_uint32.c.h"
#include "crc_model_uint64.c.h"

int
crc_model_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    khash_t(crc_models) *ms = NULL;
    ms = kh_init(crc_models);
    if (ms == NULL) {
        return ENOMEM;
    }
    khash_t(crc_stubs) *ss = NULL;
    ss = kh_init(crc_stubs);
    if (ss == NULL) {
        kh_destroy(crc_models, ms);
        return ENOMEM;
    }

    khiter_t im;
    khiter_t is;
    int r;
    size_t i;
    size_t j;

#define REGISTER_MODELS(type)                                                                                                      \
    do {                                                                                                                           \
        crc_model_stub_t *s = NULL;                                                                                                \
        i = 0;                                                                                                                     \
        while (crc_model_##type##_stubs[i].is_root == false) {                                                                     \
            s = &crc_model_##type##_stubs[i++];                                                                                    \
            s->_link.next = s->_link.prev = NULL;                                                                                  \
            s->root_key = enif_make_atom(env, s->root_keystring);                                                                  \
            s->key = enif_make_atom(env, s->keystring);                                                                            \
            is = kh_put(crc_stubs, ss, s->key, &r);                                                                                \
            switch (r) {                                                                                                           \
            case 1: /* the bucket is empty (never used) */                                                                         \
            case 2: /* the element in the bucket has been deleted */                                                               \
                kh_val(ss, is) = (const crc_model_stub_t *)s;                                                                      \
                break;                                                                                                             \
            default:                                                                                                               \
                kh_destroy(crc_stubs, ss);                                                                                         \
                kh_destroy(crc_models, ms);                                                                                        \
                return r;                                                                                                          \
            }                                                                                                                      \
        }                                                                                                                          \
        crc_model_##type##_t *m = NULL;                                                                                            \
        i = 0;                                                                                                                     \
        while (crc_model_##type##_list[i].super.is_root == true) {                                                                 \
            m = &crc_model_##type##_list[i++];                                                                                     \
            (void)crc_linklist_init_anchor(&m->super._link);                                                                       \
            m->super.root_key = enif_make_atom(env, m->super.root_keystring);                                                      \
            (void)crc_model_init(&m->super);                                                                                       \
            im = kh_put(crc_models, ms, m->super.root_key, &r);                                                                    \
            switch (r) {                                                                                                           \
            case 1: /* the bucket is empty (never used) */                                                                         \
            case 2: /* the element in the bucket has been deleted */                                                               \
                kh_val(ms, im) = (const crc_model_t *)m;                                                                           \
                break;                                                                                                             \
            default:                                                                                                               \
                kh_destroy(crc_stubs, ss);                                                                                         \
                kh_destroy(crc_models, ms);                                                                                        \
                return r;                                                                                                          \
            }                                                                                                                      \
            j = 0;                                                                                                                 \
            while (crc_model_##type##_stubs[j].is_root == false) {                                                                 \
                s = &crc_model_##type##_stubs[j++];                                                                                \
                if (s->root_key != m->super.root_key) {                                                                            \
                    continue;                                                                                                      \
                }                                                                                                                  \
                (void)crc_linklist_insert(&m->super._link, &s->_link);                                                             \
            }                                                                                                                      \
        }                                                                                                                          \
    } while (0)

    REGISTER_MODELS(uint8);
    REGISTER_MODELS(uint16);
    REGISTER_MODELS(uint32);
    REGISTER_MODELS(uint64);

#undef REGISTER_MODELS

    if (crc_model_lut != NULL) {
        kh_destroy(crc_stubs, crc_model_lut);
        crc_model_lut = NULL;
    }

    crc_model_lut = ss;

    if (crc_model_map != NULL) {
        kh_destroy(crc_models, crc_model_map);
        crc_model_map = NULL;
    }

    crc_model_map = ms;

    return 0;
}

int
crc_model_upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data, ERL_NIF_TERM load_info)
{
    return crc_model_load(env, priv_data, load_info);
}

void
crc_model_unload(ErlNifEnv *env, void **priv_data)
{
    if (crc_model_lut != NULL) {
        kh_destroy(crc_stubs, crc_model_lut);
        crc_model_lut = NULL;
    }
    if (crc_model_map != NULL) {
        kh_destroy(crc_models, crc_model_map);
        crc_model_map = NULL;
    }
}

int
crc_model_get(ERL_NIF_TERM key, const crc_model_t **model)
{
    const crc_model_stub_t *stub = NULL;
    khiter_t iter;
    if (model != NULL) {
        *model = NULL;
    }
    iter = kh_get(crc_stubs, crc_model_lut, key);
    if (iter == kh_end(crc_model_lut)) {
        return 0;
    }
    stub = (void *)kh_val(crc_model_lut, iter);
    if (stub == NULL) {
        return 0;
    }
    iter = kh_get(crc_models, crc_model_map, stub->root_key);
    if (iter == kh_end(crc_model_map)) {
        return 0;
    }
    if (model != NULL) {
        *model = (void *)kh_val(crc_model_map, iter);
    }
    return 1;
}

#define CRC_MODEL_IS_MATCH_DEF(type)                                                                                               \
    static inline bool crc_model_##type##_is_match(const crc_model_##type##_t *a, const crc_model_##type##_t *b)                   \
    {                                                                                                                              \
        return (a->sick == b->sick && a->width == b->width && a->poly == b->poly && a->init == b->init && a->refin == b->refin &&  \
                a->refout == b->refout && a->xorout == b->xorout);                                                                 \
    }

CRC_MODEL_IS_MATCH_DEF(uint8)
CRC_MODEL_IS_MATCH_DEF(uint16)
CRC_MODEL_IS_MATCH_DEF(uint32)
CRC_MODEL_IS_MATCH_DEF(uint64)

#undef CRC_MODEL_IS_MATCH_DEF

int
crc_model_match(const crc_model_t *needle, const crc_model_t **model)
{
    khint_t i;
    const crc_model_t *m = NULL;
    if (model != NULL) {
        *model = NULL;
    }
    for (i = kh_begin(crc_model_map); i != kh_end(crc_model_map); ++i) {
        if (!kh_exist(crc_model_map, i)) {
            continue;
        }
        m = (void *)kh_val(crc_model_map, i);
        if (m->bits == needle->bits) {
            bool is_match = false;
            switch (m->bits) {
            case 8:
                is_match = crc_model_uint8_is_match((void *)needle, (void *)m);
                break;
            case 16:
                is_match = crc_model_uint16_is_match((void *)needle, (void *)m);
                break;
            case 32:
                is_match = crc_model_uint32_is_match((void *)needle, (void *)m);
                break;
            case 64:
                is_match = crc_model_uint64_is_match((void *)needle, (void *)m);
                break;
            default:
                is_match = false;
                break;
            }
            if (is_match == true) {
                if (model != NULL) {
                    *model = m;
                }
                return 1;
            }
        }
    }
    return 0;
}

ERL_NIF_TERM
crc_model_list(ErlNifEnv *env)
{
    ERL_NIF_TERM out;
    ERL_NIF_TERM key;
    ERL_NIF_TERM val;
    ERL_NIF_TERM skey;
    ERL_NIF_TERM sval;
    ERL_NIF_TERM new_map = enif_make_new_map(env);

    const crc_model_t *model = NULL;
    const crc_linklist_t *anchor = NULL;
    const crc_linklist_t *node = NULL;
    const crc_model_stub_t *stub = NULL;
    unsigned char *sval_buf = NULL;
    size_t sval_len = 0;
    khint_t i;

    out = new_map;

    for (i = kh_begin(crc_model_map); i != kh_end(crc_model_map); ++i) {
        if (!kh_exist(crc_model_map, i)) {
            continue;
        }
        key = (ERL_NIF_TERM)kh_key(crc_model_map, i);
        val = new_map;
        model = (void *)kh_val(crc_model_map, i);
        anchor = &model->_link;
        node = anchor->next;
        while (node != anchor) {
            stub = (void *)node;
            node = node->next;
            skey = stub->key;
            sval_len = strnlen(stub->name, sizeof(stub->name));
            if (sval_len == 0) {
                sval = enif_make_atom(env, "nil");
            } else {
                sval_buf = enif_make_new_binary(env, sval_len, &sval);
                (void)memcpy(sval_buf, stub->name, sval_len);
            }
            (void)enif_make_map_put(env, val, skey, sval, &val);
        }
        (void)enif_make_map_put(env, out, key, val, &out);
    }

    return out;
}

/* crc_model_init/1 */

static int crc_model_uint8_init(crc_model_uint8_t *model);
static int crc_model_uint16_init(crc_model_uint16_t *model);
static int crc_model_uint32_init(crc_model_uint32_t *model);
static int crc_model_uint64_init(crc_model_uint64_t *model);

int
crc_model_init(crc_model_t *model)
{
#define CRC_MODEL_INIT_CALL(type) return crc_model_##type##_init((void *)model)

    switch (model->bits) {
    case 8:
        CRC_MODEL_INIT_CALL(uint8);
        break;
    case 16:
        CRC_MODEL_INIT_CALL(uint16);
        break;
    case 32:
        CRC_MODEL_INIT_CALL(uint32);
        break;
    case 64:
        CRC_MODEL_INIT_CALL(uint64);
        break;
    default:
        break;
    }

#undef CRC_MODEL_INIT_CALL

    return 0;
}

#define CRC_MODEL_INIT_DEF(type)                                                                                                   \
    inline int crc_model_##type##_init(crc_model_##type##_t *model)                                                                \
    {                                                                                                                              \
        model->msb_mask = 1;                                                                                                       \
        model->msb_mask <<= (model->width - 1);                                                                                    \
        model->crc_mask = 1;                                                                                                       \
        model->crc_mask |= ((model->msb_mask - 1) << 1);                                                                           \
        model->crc_shift = (model->width < 8) ? 8 - model->width : 0;                                                              \
        return 1;                                                                                                                  \
    }

CRC_MODEL_INIT_DEF(uint8)
CRC_MODEL_INIT_DEF(uint16)
CRC_MODEL_INIT_DEF(uint32)
CRC_MODEL_INIT_DEF(uint64)

#undef CRC_MODEL_INIT_DEF
