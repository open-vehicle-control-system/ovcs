// -*- mode: c++; tab-width: 4; indent-tabs-mode: nil; st-rulers: [132] -*-
// vim: ts=4 sw=4 ft=c++ et

#include "crc_algorithm.h"

/* crc_algorithm_reflect/3 */

static uint8_t crc_algorithm_uint8_reflect(uint8_t reg, uint8_t width);
static uint16_t crc_algorithm_uint16_reflect(uint16_t reg, uint8_t width);
static uint32_t crc_algorithm_uint32_reflect(uint32_t reg, uint8_t width);
static uint64_t crc_algorithm_uint64_reflect(uint64_t reg, uint8_t width);

int
crc_algorithm_reflect(const crc_model_t *model, void *value, uint8_t width)
{
#define CRC_ALGORITHM_REFLECT_CALL(type)                                                                                           \
    do {                                                                                                                           \
        type##_t *p = (type##_t *)value;                                                                                           \
        type##_t old_value = *p;                                                                                                   \
        type##_t new_value = crc_algorithm_##type##_reflect(old_value, width);                                                     \
        *p = new_value;                                                                                                            \
    } while (0)

    switch (model->bits) {
    case 8:
        CRC_ALGORITHM_REFLECT_CALL(uint8);
        break;
    case 16:
        CRC_ALGORITHM_REFLECT_CALL(uint16);
        break;
    case 32:
        CRC_ALGORITHM_REFLECT_CALL(uint32);
        break;
    case 64:
        CRC_ALGORITHM_REFLECT_CALL(uint64);
        break;
    default:
        return 0;
    }

#undef CRC_ALGORITHM_REFLECT_CALL

    return 1;
}

#define CRC_ALGORITHM_REFLECT_DEF(type)                                                                                            \
    inline type##_t crc_algorithm_##type##_reflect(type##_t reg, uint8_t width)                                                    \
    {                                                                                                                              \
        size_t i;                                                                                                                  \
        type##_t res;                                                                                                              \
        res = reg & 0x01;                                                                                                          \
        for (i = 0; i < (width - 1); i++) {                                                                                        \
            reg >>= 1;                                                                                                             \
            res <<= 1;                                                                                                             \
            res |= (reg & 0x01);                                                                                                   \
        }                                                                                                                          \
        return res;                                                                                                                \
    }

CRC_ALGORITHM_REFLECT_DEF(uint8)
CRC_ALGORITHM_REFLECT_DEF(uint16)
CRC_ALGORITHM_REFLECT_DEF(uint32)
CRC_ALGORITHM_REFLECT_DEF(uint64)

#undef CRC_ALGORITHM_REFLECT_DEF

/* crc_algorithm_compile/1 */

static int crc_algorithm_uint8_compile(crc_model_uint8_t *model);
static int crc_algorithm_uint16_compile(crc_model_uint16_t *model);
static int crc_algorithm_uint32_compile(crc_model_uint32_t *model);
static int crc_algorithm_uint64_compile(crc_model_uint64_t *model);

int
crc_algorithm_compile(crc_model_t *model)
{
    switch (model->bits) {
    case 8:
        return crc_algorithm_uint8_compile((void *)model);
    case 16:
        return crc_algorithm_uint16_compile((void *)model);
    case 32:
        return crc_algorithm_uint32_compile((void *)model);
    case 64:
        return crc_algorithm_uint64_compile((void *)model);
    default:
        return 0;
    }
}

#define CRC_ALGORITHM_COMPILE_DEF(type)                                                                                            \
    inline int crc_algorithm_##type##_compile(crc_model_##type##_t *model)                                                         \
    {                                                                                                                              \
        if (model->sick) {                                                                                                         \
            return 0;                                                                                                              \
        }                                                                                                                          \
        uint8_t tbl_idx_width = 8;                                                                                                 \
        size_t table_length = 1 << tbl_idx_width;                                                                                  \
        (void)memset(model->table, 0, table_length * sizeof(type##_t));                                                            \
        size_t i;                                                                                                                  \
        size_t j;                                                                                                                  \
        type##_t reg;                                                                                                              \
        for (i = 0; i < table_length; i++) {                                                                                       \
            reg = i;                                                                                                               \
            if (model->refin) {                                                                                                    \
                reg = crc_algorithm_##type##_reflect(reg, tbl_idx_width);                                                          \
            }                                                                                                                      \
            reg <<= (model->width - tbl_idx_width + model->crc_shift);                                                             \
            for (j = 0; j < tbl_idx_width; j++) {                                                                                  \
                if ((reg & (model->msb_mask << model->crc_shift)) != 0) {                                                          \
                    reg <<= 1;                                                                                                     \
                    reg ^= (type##_t)(model->poly << model->crc_shift);                                                            \
                } else {                                                                                                           \
                    reg <<= 1;                                                                                                     \
                }                                                                                                                  \
            }                                                                                                                      \
            if (model->refin) {                                                                                                    \
                reg = crc_algorithm_##type##_reflect((type##_t)(reg >> model->crc_shift), model->width);                           \
                reg <<= model->crc_shift;                                                                                          \
            }                                                                                                                      \
            model->table[i] = (type##_t)(reg >> model->crc_shift) & model->crc_mask;                                               \
        }                                                                                                                          \
        return 1;                                                                                                                  \
    }

CRC_ALGORITHM_COMPILE_DEF(uint8)
CRC_ALGORITHM_COMPILE_DEF(uint16)
CRC_ALGORITHM_COMPILE_DEF(uint32)
CRC_ALGORITHM_COMPILE_DEF(uint64)

#undef CRC_ALGORITHM_COMPILE_DEF

/* algorithm implementations */

#include "crc_algorithm_fast.c.h"
#include "crc_algorithm_slow.c.h"
#include "crc_algorithm_sick.c.h"

/* crc_algorithm_init/2 */

static int crc_algorithm_uint8_init(const crc_model_uint8_t *model, bool slow, crc_model_state_uint8_t *state);
static int crc_algorithm_uint16_init(const crc_model_uint16_t *model, bool slow, crc_model_state_uint16_t *state);
static int crc_algorithm_uint32_init(const crc_model_uint32_t *model, bool slow, crc_model_state_uint32_t *state);
static int crc_algorithm_uint64_init(const crc_model_uint64_t *model, bool slow, crc_model_state_uint64_t *state);

int
crc_algorithm_init(const crc_model_t *model, bool slow, void *state)
{
#define CRC_ALGORITHM_INIT_CALL(type) return crc_algorithm_##type##_init((void *)model, slow, (void *)state)

    switch (model->bits) {
    case 8:
        CRC_ALGORITHM_INIT_CALL(uint8);
        break;
    case 16:
        CRC_ALGORITHM_INIT_CALL(uint16);
        break;
    case 32:
        CRC_ALGORITHM_INIT_CALL(uint32);
        break;
    case 64:
        CRC_ALGORITHM_INIT_CALL(uint64);
        break;
    default:
        break;
    }

#undef CRC_ALGORITHM_INIT_CALL

    return 0;
}

#define CRC_ALGORITHM_INIT_DEF(type)                                                                                               \
    inline int crc_algorithm_##type##_init(const crc_model_##type##_t *model, bool slow, crc_model_state_##type##_t *state)        \
    {                                                                                                                              \
        if (model->sick) {                                                                                                         \
            return crc_algorithm_##type##_init_sick(model, &state->value, &state->extra);                                          \
        } else if (slow) {                                                                                                         \
            return crc_algorithm_##type##_init_slow(model, &state->value);                                                         \
        } else {                                                                                                                   \
            return crc_algorithm_##type##_init_fast(model, &state->value);                                                         \
        }                                                                                                                          \
    }

CRC_ALGORITHM_INIT_DEF(uint8)
CRC_ALGORITHM_INIT_DEF(uint16)
CRC_ALGORITHM_INIT_DEF(uint32)
CRC_ALGORITHM_INIT_DEF(uint64)

#undef CRC_ALGORITHM_INIT_DEF

/* crc_algorithm_update/4 */

static int crc_algorithm_uint8_update(const crc_model_uint8_t *model, bool slow, const uint8_t *buf, size_t len,
                                      crc_model_state_uint8_t *state);
static int crc_algorithm_uint16_update(const crc_model_uint16_t *model, bool slow, const uint8_t *buf, size_t len,
                                       crc_model_state_uint16_t *state);
static int crc_algorithm_uint32_update(const crc_model_uint32_t *model, bool slow, const uint8_t *buf, size_t len,
                                       crc_model_state_uint32_t *state);
static int crc_algorithm_uint64_update(const crc_model_uint64_t *model, bool slow, const uint8_t *buf, size_t len,
                                       crc_model_state_uint64_t *state);

int
crc_algorithm_update(const crc_model_t *model, bool slow, const uint8_t *buf, size_t len, void *state)
{
    if (len == 0) {
        return 1;
    }
    switch (model->bits) {
    case 8:
        return crc_algorithm_uint8_update((void *)model, slow, buf, len, (void *)state);
    case 16:
        return crc_algorithm_uint16_update((void *)model, slow, buf, len, (void *)state);
    case 32:
        return crc_algorithm_uint32_update((void *)model, slow, buf, len, (void *)state);
    case 64:
        return crc_algorithm_uint64_update((void *)model, slow, buf, len, (void *)state);
    default:
        return 0;
    }
}

#define CRC_ALGORITHM_UPDATE_DEF(type)                                                                                             \
    inline int crc_algorithm_##type##_update(const crc_model_##type##_t *model, bool slow, const uint8_t *buf, size_t len,         \
                                             crc_model_state_##type##_t *state)                                                    \
    {                                                                                                                              \
        if (model->sick) {                                                                                                         \
            return crc_algorithm_##type##_update_sick(model, buf, len, &state->value, &state->extra);                              \
        } else if (slow) {                                                                                                         \
            return crc_algorithm_##type##_update_slow(model, buf, len, &state->value);                                             \
        } else {                                                                                                                   \
            return crc_algorithm_##type##_update_fast(model, buf, len, &state->value);                                             \
        }                                                                                                                          \
    }

CRC_ALGORITHM_UPDATE_DEF(uint8)
CRC_ALGORITHM_UPDATE_DEF(uint16)
CRC_ALGORITHM_UPDATE_DEF(uint32)
CRC_ALGORITHM_UPDATE_DEF(uint64)

#undef CRC_ALGORITHM_UPDATE_DEF

/* crc_algorithm_final/2 */

static int crc_algorithm_uint8_final(const crc_model_uint8_t *model, bool slow, crc_model_state_uint8_t *state);
static int crc_algorithm_uint16_final(const crc_model_uint16_t *model, bool slow, crc_model_state_uint16_t *state);
static int crc_algorithm_uint32_final(const crc_model_uint32_t *model, bool slow, crc_model_state_uint32_t *state);
static int crc_algorithm_uint64_final(const crc_model_uint64_t *model, bool slow, crc_model_state_uint64_t *state);

int
crc_algorithm_final(const crc_model_t *model, bool slow, void *value)
{
    switch (model->bits) {
    case 8:
        return crc_algorithm_uint8_final((void *)model, slow, (void *)value);
    case 16:
        return crc_algorithm_uint16_final((void *)model, slow, (void *)value);
    case 32:
        return crc_algorithm_uint32_final((void *)model, slow, (void *)value);
    case 64:
        return crc_algorithm_uint64_final((void *)model, slow, (void *)value);
    default:
        return 0;
    }
}

#define CRC_ALGORITHM_FINAL_DEF(type)                                                                                              \
    inline int crc_algorithm_##type##_final(const crc_model_##type##_t *model, bool slow, crc_model_state_##type##_t *state)       \
    {                                                                                                                              \
        if (model->sick) {                                                                                                         \
            return crc_algorithm_##type##_final_sick(model, &state->value, &state->extra);                                         \
        } else if (slow) {                                                                                                         \
            return crc_algorithm_##type##_final_slow(model, &state->value);                                                        \
        } else {                                                                                                                   \
            return crc_algorithm_##type##_final_fast(model, &state->value);                                                        \
        }                                                                                                                          \
    }

CRC_ALGORITHM_FINAL_DEF(uint8)
CRC_ALGORITHM_FINAL_DEF(uint16)
CRC_ALGORITHM_FINAL_DEF(uint32)
CRC_ALGORITHM_FINAL_DEF(uint64)

#undef CRC_ALGORITHM_FINAL_DEF

/* crc_algorithm_residue/2 */

static int crc_algorithm_uint8_residue(const crc_model_uint8_t *model, uint8_t *value);
static int crc_algorithm_uint16_residue(const crc_model_uint16_t *model, uint16_t *value);
static int crc_algorithm_uint32_residue(const crc_model_uint32_t *model, uint32_t *value);
static int crc_algorithm_uint64_residue(const crc_model_uint64_t *model, uint64_t *value);

int
crc_algorithm_residue(const crc_model_t *model, void *value)
{
    switch (model->bits) {
    case 8:
        return crc_algorithm_uint8_residue((void *)model, (uint8_t *)value);
    case 16:
        return crc_algorithm_uint16_residue((void *)model, (uint16_t *)value);
    case 32:
        return crc_algorithm_uint32_residue((void *)model, (uint32_t *)value);
    case 64:
        return crc_algorithm_uint64_residue((void *)model, (uint64_t *)value);
    default:
        return 0;
    }
}

#define CRC_ALGORITHM_RESIDUE_DEF(type)                                                                                            \
    static inline type##_t crc_algorithm_##type##_residue_calc(const crc_model_##type##_t *model, type##_t message)                \
    {                                                                                                                              \
        unsigned long max;                                                                                                         \
        unsigned long iter;                                                                                                        \
        unsigned long ofs;                                                                                                         \
        type##_t probe;                                                                                                            \
        type##_t rem;                                                                                                              \
        type##_t result;                                                                                                           \
        max = model->width;                                                                                                        \
        probe = model->msb_mask;                                                                                                   \
        rem = model->init;                                                                                                         \
        for (iter = 0, ofs = 0; iter < max; ++iter, --ofs) {                                                                       \
            if (!ofs) {                                                                                                            \
                ofs = model->width;                                                                                                \
                rem ^= message;                                                                                                    \
            }                                                                                                                      \
            if (rem & probe) {                                                                                                     \
                rem = (rem << 1) ^ model->poly;                                                                                    \
            } else {                                                                                                               \
                rem <<= 1;                                                                                                         \
            }                                                                                                                      \
        }                                                                                                                          \
        result = (rem ^ model->xorout) & model->crc_mask;                                                                          \
        return result;                                                                                                             \
    }                                                                                                                              \
                                                                                                                                   \
    inline int crc_algorithm_##type##_residue(const crc_model_##type##_t *model, type##_t *value)                                  \
    {                                                                                                                              \
        int retval;                                                                                                                \
        type##_t xorout = model->xorout;                                                                                           \
        type##_t residue = 0;                                                                                                      \
        type##_t extra = 0;                                                                                                        \
        crc_model_##type##_t mcopy_buff;                                                                                           \
        crc_model_##type##_t *mcopy = &mcopy_buff;                                                                                 \
        (void)memcpy(mcopy, model, sizeof(crc_model_##type##_t));                                                                  \
        mcopy->init = residue;                                                                                                     \
        mcopy->xorout = 0;                                                                                                         \
        if (model->refout) {                                                                                                       \
            xorout = crc_algorithm_##type##_reflect(xorout, mcopy->width);                                                         \
        }                                                                                                                          \
        size_t len = (mcopy->super.bits / 8);                                                                                      \
        uint8_t *buf = (void *)&xorout;                                                                                            \
        if (mcopy->sick) {                                                                                                         \
            retval = crc_algorithm_##type##_update_sick(mcopy, buf, len, &residue, &extra);                                        \
        } else {                                                                                                                   \
            retval = 1;                                                                                                            \
            residue = crc_algorithm_##type##_residue_calc(mcopy, xorout);                                                          \
        }                                                                                                                          \
        if (!retval) {                                                                                                             \
            return retval;                                                                                                         \
        }                                                                                                                          \
        if (mcopy->sick) {                                                                                                         \
            retval = crc_algorithm_##type##_final_sick(mcopy, &residue, &extra);                                                   \
        } else if (mcopy->refin) {                                                                                                 \
            retval = 1;                                                                                                            \
            residue = crc_algorithm_##type##_reflect(residue, mcopy->width);                                                       \
        }                                                                                                                          \
        if (!retval) {                                                                                                             \
            return retval;                                                                                                         \
        }                                                                                                                          \
        *value = residue;                                                                                                          \
        return 1;                                                                                                                  \
    }

CRC_ALGORITHM_RESIDUE_DEF(uint8)
CRC_ALGORITHM_RESIDUE_DEF(uint16)
CRC_ALGORITHM_RESIDUE_DEF(uint32)
CRC_ALGORITHM_RESIDUE_DEF(uint64)

#undef CRC_ALGORITHM_RESIDUE_DEF
