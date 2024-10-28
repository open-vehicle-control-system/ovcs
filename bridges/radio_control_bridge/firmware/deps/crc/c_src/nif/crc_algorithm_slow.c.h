// -*- mode: c++; tab-width: 4; indent-tabs-mode: nil; st-rulers: [132] -*-
// vim: ts=4 sw=4 ft=c++ et

/* crc_algorithm_init_slow/2 */

static int crc_algorithm_uint8_init_slow(const crc_model_uint8_t *model, uint8_t *value);
static int crc_algorithm_uint16_init_slow(const crc_model_uint16_t *model, uint16_t *value);
static int crc_algorithm_uint32_init_slow(const crc_model_uint32_t *model, uint32_t *value);
static int crc_algorithm_uint64_init_slow(const crc_model_uint64_t *model, uint64_t *value);

#define CRC_ALGORITHM_INIT_SLOW_DEF(type)                                                                                          \
    inline int crc_algorithm_##type##_init_slow(const crc_model_##type##_t *model, type##_t *value)                                \
    {                                                                                                                              \
        type##_t crc;                                                                                                              \
        unsigned int bit;                                                                                                          \
        size_t i;                                                                                                                  \
        crc = model->init;                                                                                                         \
        for (i = 0; i < model->width; i++) {                                                                                       \
            bit = crc & 0x01;                                                                                                      \
            if (bit) {                                                                                                             \
                crc ^= model->poly;                                                                                                \
            }                                                                                                                      \
            crc >>= 1;                                                                                                             \
            if (bit) {                                                                                                             \
                crc |= model->msb_mask;                                                                                            \
            }                                                                                                                      \
        }                                                                                                                          \
        crc = crc & model->crc_mask;                                                                                               \
        *value = crc;                                                                                                              \
        return 1;                                                                                                                  \
    }

CRC_ALGORITHM_INIT_SLOW_DEF(uint8)
CRC_ALGORITHM_INIT_SLOW_DEF(uint16)
CRC_ALGORITHM_INIT_SLOW_DEF(uint32)
CRC_ALGORITHM_INIT_SLOW_DEF(uint64)

#undef CRC_ALGORITHM_INIT_SLOW_DEF

/* crc_algorithm_update_slow/4 */

static int crc_algorithm_uint8_update_slow(const crc_model_uint8_t *model, const uint8_t *buf, size_t len, uint8_t *value);
static int crc_algorithm_uint16_update_slow(const crc_model_uint16_t *model, const uint8_t *buf, size_t len, uint16_t *value);
static int crc_algorithm_uint32_update_slow(const crc_model_uint32_t *model, const uint8_t *buf, size_t len, uint32_t *value);
static int crc_algorithm_uint64_update_slow(const crc_model_uint64_t *model, const uint8_t *buf, size_t len, uint64_t *value);

#define CRC_ALGORITHM_UPDATE_SLOW_DEF(type)                                                                                        \
    inline int crc_algorithm_##type##_update_slow(const crc_model_##type##_t *model, const uint8_t *buf, size_t len,               \
                                                  type##_t *value)                                                                 \
    {                                                                                                                              \
        type##_t reg = *value;                                                                                                     \
        bool bit;                                                                                                                  \
        uint8_t octet;                                                                                                             \
        size_t i;                                                                                                                  \
        while (len--) {                                                                                                            \
            octet = *buf++;                                                                                                        \
            if (model->refin) {                                                                                                    \
                octet = crc_algorithm_uint8_reflect(octet, 8);                                                                     \
            }                                                                                                                      \
            for (i = 0; i < 8; i++) {                                                                                              \
                bit = (reg & model->msb_mask);                                                                                     \
                reg = ((reg << 1) & model->crc_mask) | ((octet >> (7 - i)) & 0x01);                                                \
                if (bit) {                                                                                                         \
                    reg ^= model->poly;                                                                                            \
                }                                                                                                                  \
            }                                                                                                                      \
        }                                                                                                                          \
        *value = reg;                                                                                                              \
        return 1;                                                                                                                  \
    }

CRC_ALGORITHM_UPDATE_SLOW_DEF(uint8)
CRC_ALGORITHM_UPDATE_SLOW_DEF(uint16)
CRC_ALGORITHM_UPDATE_SLOW_DEF(uint32)
CRC_ALGORITHM_UPDATE_SLOW_DEF(uint64)

#undef CRC_ALGORITHM_UPDATE_SLOW_DEF

/* crc_algorithm_final_slow/2 */

static int crc_algorithm_uint8_final_slow(const crc_model_uint8_t *model, uint8_t *value);
static int crc_algorithm_uint16_final_slow(const crc_model_uint16_t *model, uint16_t *value);
static int crc_algorithm_uint32_final_slow(const crc_model_uint32_t *model, uint32_t *value);
static int crc_algorithm_uint64_final_slow(const crc_model_uint64_t *model, uint64_t *value);

#define CRC_ALGORITHM_FINAL_SLOW_DEF(type)                                                                                         \
    inline int crc_algorithm_##type##_final_slow(const crc_model_##type##_t *model, type##_t *value)                               \
    {                                                                                                                              \
        type##_t reg = *value;                                                                                                     \
        bool bit;                                                                                                                  \
        size_t i;                                                                                                                  \
        for (i = 0; i < model->width; i++) {                                                                                       \
            bit = (reg & model->msb_mask);                                                                                         \
            reg = ((reg << 1) & model->crc_mask);                                                                                  \
            if (bit) {                                                                                                             \
                reg ^= model->poly;                                                                                                \
            }                                                                                                                      \
        }                                                                                                                          \
        if (model->refout) {                                                                                                       \
            reg = crc_algorithm_##type##_reflect(reg, model->width);                                                               \
        }                                                                                                                          \
        reg = (reg ^ model->xorout) & model->crc_mask;                                                                             \
        *value = reg;                                                                                                              \
        return 1;                                                                                                                  \
    }

CRC_ALGORITHM_FINAL_SLOW_DEF(uint8)
CRC_ALGORITHM_FINAL_SLOW_DEF(uint16)
CRC_ALGORITHM_FINAL_SLOW_DEF(uint32)
CRC_ALGORITHM_FINAL_SLOW_DEF(uint64)

#undef CRC_ALGORITHM_FINAL_SLOW_DEF
