// -*- mode: c++; tab-width: 4; indent-tabs-mode: nil; st-rulers: [132] -*-
// vim: ts=4 sw=4 ft=c++ et

/* crc_algorithm_init_fast/2 */

static int crc_algorithm_uint8_init_fast(const crc_model_uint8_t *model, uint8_t *value);
static int crc_algorithm_uint16_init_fast(const crc_model_uint16_t *model, uint16_t *value);
static int crc_algorithm_uint32_init_fast(const crc_model_uint32_t *model, uint32_t *value);
static int crc_algorithm_uint64_init_fast(const crc_model_uint64_t *model, uint64_t *value);

#define CRC_ALGORITHM_INIT_FAST_DEF(type)                                                                                          \
    inline int crc_algorithm_##type##_init_fast(const crc_model_##type##_t *model, type##_t *value)                                \
    {                                                                                                                              \
        type##_t crc;                                                                                                              \
        crc = model->init;                                                                                                         \
        *value = crc;                                                                                                              \
        return 1;                                                                                                                  \
    }

CRC_ALGORITHM_INIT_FAST_DEF(uint8)
CRC_ALGORITHM_INIT_FAST_DEF(uint16)
CRC_ALGORITHM_INIT_FAST_DEF(uint32)
CRC_ALGORITHM_INIT_FAST_DEF(uint64)

#undef CRC_ALGORITHM_INIT_FAST_DEF

/* crc_algorithm_update_fast/4 */

static int crc_algorithm_uint8_update_fast(const crc_model_uint8_t *model, const uint8_t *buf, size_t len, uint8_t *value);
static int crc_algorithm_uint16_update_fast(const crc_model_uint16_t *model, const uint8_t *buf, size_t len, uint16_t *value);
static int crc_algorithm_uint32_update_fast(const crc_model_uint32_t *model, const uint8_t *buf, size_t len, uint32_t *value);
static int crc_algorithm_uint64_update_fast(const crc_model_uint64_t *model, const uint8_t *buf, size_t len, uint64_t *value);

#define CRC_ALGORITHM_UPDATE_FAST_DEF(type)                                                                                        \
    inline int crc_algorithm_##type##_update_fast(const crc_model_##type##_t *model, const uint8_t *buf, size_t len,               \
                                                  type##_t *value)                                                                 \
    {                                                                                                                              \
        type##_t crc = *value;                                                                                                     \
        unsigned int tbl_index;                                                                                                    \
        if (model->refin) {                                                                                                        \
            crc = crc_algorithm_##type##_reflect(crc, model->width);                                                               \
            while (len--) {                                                                                                        \
                tbl_index = (crc ^ *buf++) & 0xff;                                                                                 \
                crc = ((crc >> 8) ^ model->table[tbl_index]) & model->crc_mask;                                                    \
            }                                                                                                                      \
            crc = crc_algorithm_##type##_reflect(crc, model->width) & model->crc_mask;                                             \
        } else {                                                                                                                   \
            crc = crc << model->crc_shift;                                                                                         \
            while (len--) {                                                                                                        \
                tbl_index = ((crc >> (model->width - 8 + model->crc_shift)) ^ *buf++) & 0xff;                                      \
                crc = ((crc << (8 - model->crc_shift)) ^ (model->table[tbl_index] << model->crc_shift)) &                          \
                      (model->crc_mask << model->crc_shift);                                                                       \
            }                                                                                                                      \
            crc = crc >> model->crc_shift;                                                                                         \
        }                                                                                                                          \
        *value = crc;                                                                                                              \
        return 1;                                                                                                                  \
    }

CRC_ALGORITHM_UPDATE_FAST_DEF(uint8)
CRC_ALGORITHM_UPDATE_FAST_DEF(uint16)
CRC_ALGORITHM_UPDATE_FAST_DEF(uint32)
CRC_ALGORITHM_UPDATE_FAST_DEF(uint64)

#undef CRC_ALGORITHM_UPDATE_FAST_DEF

/* crc_algorithm_final_fast/2 */

static int crc_algorithm_uint8_final_fast(const crc_model_uint8_t *model, uint8_t *value);
static int crc_algorithm_uint16_final_fast(const crc_model_uint16_t *model, uint16_t *value);
static int crc_algorithm_uint32_final_fast(const crc_model_uint32_t *model, uint32_t *value);
static int crc_algorithm_uint64_final_fast(const crc_model_uint64_t *model, uint64_t *value);

#define CRC_ALGORITHM_FINAL_FAST_DEF(type)                                                                                         \
    inline int crc_algorithm_##type##_final_fast(const crc_model_##type##_t *model, type##_t *value)                               \
    {                                                                                                                              \
        type##_t crc = *value;                                                                                                     \
        if (model->refout) {                                                                                                       \
            crc = crc_algorithm_##type##_reflect(crc, model->width);                                                               \
        }                                                                                                                          \
        *value = crc ^ model->xorout;                                                                                              \
        return 1;                                                                                                                  \
    }

CRC_ALGORITHM_FINAL_FAST_DEF(uint8)
CRC_ALGORITHM_FINAL_FAST_DEF(uint16)
CRC_ALGORITHM_FINAL_FAST_DEF(uint32)
CRC_ALGORITHM_FINAL_FAST_DEF(uint64)

#undef CRC_ALGORITHM_FINAL_FAST_DEF
