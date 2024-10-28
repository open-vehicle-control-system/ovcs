// -*- mode: c++; tab-width: 4; indent-tabs-mode: nil; st-rulers: [132] -*-
// vim: ts=4 sw=4 ft=c++ et

#include "checksum_xor.h"
#include "xnif_slice.h"

uint8_t
checksum_xor(uint8_t sum, const unsigned char *buf, size_t len)
{
    size_t i;
    for (i = 0; i < len; i++) {
        sum ^= buf[i];
    }
    return sum;
}

/* NIF Functions */

static int crc_nif_checksum_xor_1_work(ErlNifEnv *env, xnif_slice_t *slice, int *phasep, size_t *offsetp, size_t reductions);
static ERL_NIF_TERM crc_nif_checksum_xor_1_done(ErlNifEnv *env, xnif_slice_t *slice);

static xnif_slice_func_t crc_nif_checksum_xor_1_func = {
    crc_nif_checksum_xor_1_work, crc_nif_checksum_xor_1_done, NULL, NULL,
};

ERL_NIF_TERM
crc_nif_checksum_xor_1(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary input;

    if (argc != 1 || !enif_inspect_binary(env, argv[0], &input)) {
        return enif_make_badarg(env);
    }

    if (input.size <= XNIF_SLICE_MAX_PER_SLICE) {
        uint8_t sum;
        sum = checksum_xor(0, input.data, input.size);
        return enif_make_uint(env, sum);
    }

    xnif_slice_t *slice = xnif_slice_create("checksum_xor", &crc_nif_checksum_xor_1_func, 0, input.size);
    if (slice == NULL) {
        return enif_make_badarg(env);
    }
    ERL_NIF_TERM newargv[2];
    newargv[0] = enif_make_uint(env, 0);
    newargv[1] = argv[0];
    return xnif_slice_schedule(env, slice, 2, newargv);
}

static int
crc_nif_checksum_xor_1_work(ErlNifEnv *env, xnif_slice_t *slice, int *phasep, size_t *offsetp, size_t reductions)
{
    size_t offset = *offsetp;
    uint8_t sum;
    ErlNifBinary input;
    if (slice->argc != 2 || !enif_get_uint(env, slice->argv[0], (unsigned int *)&sum) ||
        !enif_inspect_binary(env, slice->argv[1], &input)) {
        return -1;
    }
    sum = checksum_xor(sum, input.data + offset, reductions);
    slice->argv[0] = enif_make_uint(env, sum);
    *offsetp = offset + reductions;
    return 0;
}

static ERL_NIF_TERM
crc_nif_checksum_xor_1_done(ErlNifEnv *env, xnif_slice_t *slice)
{
    uint16_t sum;
    if (slice->argc != 2 || !enif_get_uint(env, slice->argv[0], (unsigned int *)&sum)) {
        return enif_make_badarg(env);
    }
    return enif_make_uint(env, sum);
}
