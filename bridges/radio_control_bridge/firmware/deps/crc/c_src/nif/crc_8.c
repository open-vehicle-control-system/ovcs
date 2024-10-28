// -*- mode: c++; tab-width: 4; indent-tabs-mode: nil; st-rulers: [132] -*-
// vim: ts=4 sw=4 ft=c++ et

#include "crc_8.h"
#include "xnif_slice.h"

/*
code derived from:
http://stackoverflow.com/questions/15169387/definitive-crc-for-c
*/

static uint8_t crc_8_table[] = {
    0x00, 0x3e, 0x7c, 0x42, 0xf8, 0xc6, 0x84, 0xba, 0x95, 0xab, 0xe9, 0xd7, 0x6d, 0x53, 0x11, 0x2f, 0x4f, 0x71, 0x33, 0x0d,
    0xb7, 0x89, 0xcb, 0xf5, 0xda, 0xe4, 0xa6, 0x98, 0x22, 0x1c, 0x5e, 0x60, 0x9e, 0xa0, 0xe2, 0xdc, 0x66, 0x58, 0x1a, 0x24,
    0x0b, 0x35, 0x77, 0x49, 0xf3, 0xcd, 0x8f, 0xb1, 0xd1, 0xef, 0xad, 0x93, 0x29, 0x17, 0x55, 0x6b, 0x44, 0x7a, 0x38, 0x06,
    0xbc, 0x82, 0xc0, 0xfe, 0x59, 0x67, 0x25, 0x1b, 0xa1, 0x9f, 0xdd, 0xe3, 0xcc, 0xf2, 0xb0, 0x8e, 0x34, 0x0a, 0x48, 0x76,
    0x16, 0x28, 0x6a, 0x54, 0xee, 0xd0, 0x92, 0xac, 0x83, 0xbd, 0xff, 0xc1, 0x7b, 0x45, 0x07, 0x39, 0xc7, 0xf9, 0xbb, 0x85,
    0x3f, 0x01, 0x43, 0x7d, 0x52, 0x6c, 0x2e, 0x10, 0xaa, 0x94, 0xd6, 0xe8, 0x88, 0xb6, 0xf4, 0xca, 0x70, 0x4e, 0x0c, 0x32,
    0x1d, 0x23, 0x61, 0x5f, 0xe5, 0xdb, 0x99, 0xa7, 0xb2, 0x8c, 0xce, 0xf0, 0x4a, 0x74, 0x36, 0x08, 0x27, 0x19, 0x5b, 0x65,
    0xdf, 0xe1, 0xa3, 0x9d, 0xfd, 0xc3, 0x81, 0xbf, 0x05, 0x3b, 0x79, 0x47, 0x68, 0x56, 0x14, 0x2a, 0x90, 0xae, 0xec, 0xd2,
    0x2c, 0x12, 0x50, 0x6e, 0xd4, 0xea, 0xa8, 0x96, 0xb9, 0x87, 0xc5, 0xfb, 0x41, 0x7f, 0x3d, 0x03, 0x63, 0x5d, 0x1f, 0x21,
    0x9b, 0xa5, 0xe7, 0xd9, 0xf6, 0xc8, 0x8a, 0xb4, 0x0e, 0x30, 0x72, 0x4c, 0xeb, 0xd5, 0x97, 0xa9, 0x13, 0x2d, 0x6f, 0x51,
    0x7e, 0x40, 0x02, 0x3c, 0x86, 0xb8, 0xfa, 0xc4, 0xa4, 0x9a, 0xd8, 0xe6, 0x5c, 0x62, 0x20, 0x1e, 0x31, 0x0f, 0x4d, 0x73,
    0xc9, 0xf7, 0xb5, 0x8b, 0x75, 0x4b, 0x09, 0x37, 0x8d, 0xb3, 0xf1, 0xcf, 0xe0, 0xde, 0x9c, 0xa2, 0x18, 0x26, 0x64, 0x5a,
    0x3a, 0x04, 0x46, 0x78, 0xc2, 0xfc, 0xbe, 0x80, 0xaf, 0x91, 0xd3, 0xed, 0x57, 0x69, 0x2b, 0x15};

uint8_t
crc_8_init(uint8_t seed)
{
    return (uint8_t)(seed ^ 0xff);
}

uint8_t
crc_8_update(uint8_t ctx, const unsigned char *buf, size_t len)
{
    while (len--) {
        ctx = (crc_8_table[ctx ^ *buf] ^ (ctx >> 8)) & 0xff;
        buf++;
    }
    return ctx & 0xff;
}

uint8_t
crc_8_final(uint8_t ctx)
{
    return (uint8_t)(ctx ^ 0xff);
}

/* NIF Functions */

static int crc_nif_crc_8_2_work(ErlNifEnv *env, xnif_slice_t *slice, int *phasep, size_t *offsetp, size_t reductions);
static ERL_NIF_TERM crc_nif_crc_8_2_done(ErlNifEnv *env, xnif_slice_t *slice);

static xnif_slice_func_t crc_nif_crc_8_2_func = {
    crc_nif_crc_8_2_work, crc_nif_crc_8_2_done, NULL, NULL,
};

ERL_NIF_TERM
crc_nif_crc_8_2(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    unsigned int seed;
    ErlNifBinary input;

    if (argc != 2 || !enif_get_uint(env, argv[0], &seed) || seed > 0xff || !enif_inspect_binary(env, argv[1], &input)) {
        return enif_make_badarg(env);
    }

    if (input.size <= XNIF_SLICE_MAX_PER_SLICE) {
        uint8_t crc;
        crc = crc_8(seed, input.data, input.size);
        return enif_make_uint(env, crc);
    }

    xnif_slice_t *slice = xnif_slice_create("crc_8", &crc_nif_crc_8_2_func, 0, input.size);
    if (slice == NULL) {
        return enif_make_badarg(env);
    }
    uint8_t ctx = crc_8_init(seed);
    ERL_NIF_TERM newargv[2];
    newargv[0] = enif_make_uint(env, ctx);
    newargv[1] = argv[1];
    return xnif_slice_schedule(env, slice, 2, newargv);
}

static int
crc_nif_crc_8_2_work(ErlNifEnv *env, xnif_slice_t *slice, int *phasep, size_t *offsetp, size_t reductions)
{
    size_t offset = *offsetp;
    uint8_t ctx;
    ErlNifBinary input;
    if (slice->argc != 2 || !enif_get_uint(env, slice->argv[0], (unsigned int *)&ctx) ||
        !enif_inspect_binary(env, slice->argv[1], &input)) {
        return -1;
    }
    ctx = crc_8_update(ctx, input.data + offset, reductions);
    slice->argv[0] = enif_make_uint(env, ctx);
    *offsetp = offset + reductions;
    return 0;
}

static ERL_NIF_TERM
crc_nif_crc_8_2_done(ErlNifEnv *env, xnif_slice_t *slice)
{
    uint8_t ctx;
    if (slice->argc != 2 || !enif_get_uint(env, slice->argv[0], (unsigned int *)&ctx)) {
        return enif_make_badarg(env);
    }
    return enif_make_uint(env, crc_8_final(ctx));
}

ERL_NIF_TERM
crc_nif_crc_8_init_1(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    unsigned int seed;

    if (argc != 1 || !enif_get_uint(env, argv[0], &seed) || seed > 0xff) {
        return enif_make_badarg(env);
    }

    uint8_t ctx = crc_8_init((uint8_t)seed);
    return enif_make_uint(env, ctx);
}

static int crc_nif_crc_8_update_2_work(ErlNifEnv *env, xnif_slice_t *slice, int *phasep, size_t *offsetp, size_t reductions);
static ERL_NIF_TERM crc_nif_crc_8_update_2_done(ErlNifEnv *env, xnif_slice_t *slice);

static xnif_slice_func_t crc_nif_crc_8_update_2_func = {
    crc_nif_crc_8_update_2_work, crc_nif_crc_8_update_2_done, NULL, NULL,
};

ERL_NIF_TERM
crc_nif_crc_8_update_2(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    unsigned int ctx;
    ErlNifBinary input;

    if (argc != 2 || !enif_get_uint(env, argv[0], &ctx) || ctx > 0xff || !enif_inspect_binary(env, argv[1], &input)) {
        return enif_make_badarg(env);
    }

    if (input.size <= XNIF_SLICE_MAX_PER_SLICE) {
        ctx = crc_8_update((uint8_t)ctx, input.data, input.size);
        return enif_make_uint(env, ctx);
    }

    xnif_slice_t *slice = xnif_slice_create("crc_8_update", &crc_nif_crc_8_update_2_func, 0, input.size);
    if (slice == NULL) {
        return enif_make_badarg(env);
    }
    ERL_NIF_TERM newargv[2];
    newargv[0] = argv[0];
    newargv[1] = argv[1];
    return xnif_slice_schedule(env, slice, 2, newargv);
}

static int
crc_nif_crc_8_update_2_work(ErlNifEnv *env, xnif_slice_t *slice, int *phasep, size_t *offsetp, size_t reductions)
{
    size_t offset = *offsetp;
    uint8_t ctx;
    ErlNifBinary input;
    if (slice->argc != 2 || !enif_get_uint(env, slice->argv[0], (unsigned int *)&ctx) ||
        !enif_inspect_binary(env, slice->argv[1], &input)) {
        return -1;
    }
    ctx = crc_8_update(ctx, input.data + offset, reductions);
    slice->argv[0] = enif_make_uint(env, ctx);
    *offsetp = offset + reductions;
    return 0;
}

static ERL_NIF_TERM
crc_nif_crc_8_update_2_done(ErlNifEnv *env, xnif_slice_t *slice)
{
    uint8_t ctx;
    if (slice->argc != 2 || !enif_get_uint(env, slice->argv[0], (unsigned int *)&ctx)) {
        return enif_make_badarg(env);
    }
    return enif_make_uint(env, ctx);
}

ERL_NIF_TERM
crc_nif_crc_8_final_1(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    unsigned int ctx;

    if (argc != 1 || !enif_get_uint(env, argv[0], &ctx) || ctx > 0xff) {
        return enif_make_badarg(env);
    }

    uint8_t crc = crc_8_final((uint8_t)ctx);
    return enif_make_uint(env, crc);
}
