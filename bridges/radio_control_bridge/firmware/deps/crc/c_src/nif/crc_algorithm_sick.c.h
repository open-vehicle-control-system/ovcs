// -*- mode: c++; tab-width: 4; indent-tabs-mode: nil; st-rulers: [132] -*-
// vim: ts=4 sw=4 ft=c++ et

/* crc_algorithm_init_sick/2 */

static int crc_algorithm_uint8_init_sick(const crc_model_uint8_t *model, uint8_t *value, uint8_t *extra);
static int crc_algorithm_uint16_init_sick(const crc_model_uint16_t *model, uint16_t *value, uint16_t *extra);
static int crc_algorithm_uint32_init_sick(const crc_model_uint32_t *model, uint32_t *value, uint32_t *extra);
static int crc_algorithm_uint64_init_sick(const crc_model_uint64_t *model, uint64_t *value, uint64_t *extra);

#define CRC_ALGORITHM_INIT_SICK_DEF(type)                                                                                          \
    inline int crc_algorithm_##type##_init_sick(const crc_model_##type##_t *model, type##_t *value, type##_t *extra)               \
    {                                                                                                                              \
        type##_t crc;                                                                                                              \
        crc = model->init;                                                                                                         \
        *value = crc;                                                                                                              \
        *extra = 0;                                                                                                                \
        return 1;                                                                                                                  \
    }

CRC_ALGORITHM_INIT_SICK_DEF(uint8)
CRC_ALGORITHM_INIT_SICK_DEF(uint16)
CRC_ALGORITHM_INIT_SICK_DEF(uint32)
CRC_ALGORITHM_INIT_SICK_DEF(uint64)

#undef CRC_ALGORITHM_INIT_SICK_DEF

/* crc_algorithm_update_sick/4 */

static int crc_algorithm_uint8_update_sick(const crc_model_uint8_t *model, const uint8_t *buf, size_t len, uint8_t *value,
                                           uint8_t *extra);
static int crc_algorithm_uint16_update_sick(const crc_model_uint16_t *model, const uint8_t *buf, size_t len, uint16_t *value,
                                            uint16_t *extra);
static int crc_algorithm_uint32_update_sick(const crc_model_uint32_t *model, const uint8_t *buf, size_t len, uint32_t *value,
                                            uint32_t *extra);
static int crc_algorithm_uint64_update_sick(const crc_model_uint64_t *model, const uint8_t *buf, size_t len, uint64_t *value,
                                            uint64_t *extra);

inline int
crc_algorithm_uint8_update_sick(const crc_model_uint8_t *model, const uint8_t *buf, size_t len, uint8_t *value, uint8_t *extra)
{
    return 0;
}

inline int
crc_algorithm_uint16_update_sick(const crc_model_uint16_t *model, const uint8_t *buf, size_t len, uint16_t *value, uint16_t *extra)
{
    uint16_t next_byte;
    uint16_t prev_byte = *extra;
    uint16_t reg = *value;
    while (len--) {
        next_byte = 0x00ff & (uint16_t)*buf++;
        if ((reg & (model->msb_mask << model->crc_shift)) != 0) {
            reg <<= 1;
            reg ^= (uint16_t)(model->poly << model->crc_shift);
        } else {
            reg <<= 1;
        }
        reg ^= (next_byte | prev_byte);
        prev_byte = next_byte << 8;
    }
    *value = reg & model->crc_mask;
    *extra = prev_byte;
    return 1;
}

inline int
crc_algorithm_uint32_update_sick(const crc_model_uint32_t *model, const uint8_t *buf, size_t len, uint32_t *value, uint32_t *extra)
{
    return 0;
}

inline int
crc_algorithm_uint64_update_sick(const crc_model_uint64_t *model, const uint8_t *buf, size_t len, uint64_t *value, uint64_t *extra)
{
    return 0;
}

/* crc_algorithm_final_sick/2 */

static int crc_algorithm_uint8_final_sick(const crc_model_uint8_t *model, uint8_t *value, uint8_t *extra);
static int crc_algorithm_uint16_final_sick(const crc_model_uint16_t *model, uint16_t *value, uint16_t *extra);
static int crc_algorithm_uint32_final_sick(const crc_model_uint32_t *model, uint32_t *value, uint32_t *extra);
static int crc_algorithm_uint64_final_sick(const crc_model_uint64_t *model, uint64_t *value, uint64_t *extra);

inline int
crc_algorithm_uint8_final_sick(const crc_model_uint8_t *model, uint8_t *value, uint8_t *extra)
{
    return 0;
}

inline int
crc_algorithm_uint16_final_sick(const crc_model_uint16_t *model, uint16_t *value, uint16_t *extra)
{
    uint16_t old_value = *value;
    uint16_t new_value;
    uint16_t low_byte;
    uint16_t high_byte;
    low_byte = (old_value & 0xff00) >> 8;
    high_byte = (old_value & 0x00ff) << 8;
    new_value = low_byte | high_byte;
    *value = new_value;
    return 1;
}

inline int
crc_algorithm_uint32_final_sick(const crc_model_uint32_t *model, uint32_t *value, uint32_t *extra)
{
    return 0;
}

inline int
crc_algorithm_uint64_final_sick(const crc_model_uint64_t *model, uint64_t *value, uint64_t *extra)
{
    return 0;
}
