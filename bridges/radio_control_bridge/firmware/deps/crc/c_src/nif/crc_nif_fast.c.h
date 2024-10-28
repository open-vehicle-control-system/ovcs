// -*- mode: c++; tab-width: 4; indent-tabs-mode: nil; st-rulers: [132] -*-
// vim: ts=4 sw=4 ft=c++ et

static ERL_NIF_TERM crc_nif_crc_fast_2(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
static ERL_NIF_TERM crc_nif_crc_fast_update_2(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
static ERL_NIF_TERM crc_nif_crc_fast_final_1(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

/* crc_nif:crc_fast/2 */

static int crc_nif_crc_fast_2_work(ErlNifEnv *env, xnif_slice_t *slice, int *phasep, size_t *offsetp, size_t reductions);
static ERL_NIF_TERM crc_nif_crc_fast_2_done(ErlNifEnv *env, xnif_slice_t *slice);

static xnif_slice_func_t crc_nif_crc_fast_2_func = {
    crc_nif_crc_fast_2_work, crc_nif_crc_fast_2_done, NULL, NULL,
};

static ERL_NIF_TERM
crc_nif_crc_fast_2(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    crc_resource_t *resource = NULL;
    ErlNifBinary input;
    ERL_NIF_TERM out_term;

    if (argc != 2 || !enif_inspect_iolist_as_binary(env, argv[1], &input) ||
        !crc_init(env, 1, argv, false, (const crc_resource_t **)&resource)) {
        return enif_make_badarg(env);
    }

    if (input.size <= XNIF_SLICE_MAX_PER_SLICE) {
        if (!crc_resource_update_unsafe(resource, (const uint8_t *)input.data, (size_t)input.size)) {
            (void)enif_release_resource((void *)resource);
            return enif_make_badarg(env);
        }
        ErlNifUInt64 value = 0;
        if (!crc_resource_final(resource, (void *)&value)) {
            (void)enif_release_resource((void *)resource);
            return enif_make_badarg(env);
        }
        out_term = enif_make_uint64(env, value);
        (void)enif_release_resource((void *)resource);
        return out_term;
    }

    xnif_slice_t *slice = xnif_slice_create("crc_fast", &crc_nif_crc_fast_2_func, 0, input.size);
    if (slice == NULL) {
        return enif_make_badarg(env);
    }
    ERL_NIF_TERM newargv[2];
    newargv[0] = enif_make_resource(env, (void *)resource);
    newargv[1] = argv[1];
    (void)enif_release_resource((void *)resource);

    return xnif_slice_schedule(env, slice, 2, newargv);
}

static int
crc_nif_crc_fast_2_work(ErlNifEnv *env, xnif_slice_t *slice, int *phasep, size_t *offsetp, size_t reductions)
{
    size_t offset = *offsetp;
    crc_resource_t *resource = NULL;
    ErlNifBinary input;
    if (slice->argc != 2 || !crc_resource_get(env, slice->argv[0], (const crc_resource_t **)&resource) ||
        !enif_inspect_iolist_as_binary(env, slice->argv[1], &input)) {
        return -1;
    }
    if (!crc_resource_update_unsafe(resource, (const uint8_t *)input.data + offset, reductions)) {
        return -1;
    }
    *offsetp = offset + reductions;
    return 0;
}

static ERL_NIF_TERM
crc_nif_crc_fast_2_done(ErlNifEnv *env, xnif_slice_t *slice)
{
    const crc_resource_t *resource = NULL;
    ERL_NIF_TERM out_term;
    ErlNifUInt64 value = 0;
    if (slice->argc != 2 || !crc_resource_get(env, slice->argv[0], &resource) || !crc_resource_final(resource, (void *)&value)) {
        return enif_make_badarg(env);
    }
    out_term = enif_make_uint64(env, value);
    return out_term;
}

/* crc_nif:crc_fast_update/2 */

static int crc_nif_crc_fast_update_2_work(ErlNifEnv *env, xnif_slice_t *slice, int *phasep, size_t *offsetp, size_t reductions);
static ERL_NIF_TERM crc_nif_crc_fast_update_2_done(ErlNifEnv *env, xnif_slice_t *slice);

static xnif_slice_func_t crc_nif_crc_fast_update_2_func = {
    crc_nif_crc_fast_update_2_work, crc_nif_crc_fast_update_2_done, NULL, NULL,
};

static ERL_NIF_TERM
crc_nif_crc_fast_update_2(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    const crc_resource_t *old_resource = NULL;
    ErlNifBinary input;

    if (argc != 2 || !crc_resource_get(env, argv[0], &old_resource) || old_resource->slow ||
        !enif_inspect_iolist_as_binary(env, argv[1], &input)) {
        return enif_make_badarg(env);
    }

    if (input.size == 0) {
        return argv[0];
    }

    crc_resource_t *new_resource = NULL;
    ERL_NIF_TERM out_term;

    if (input.size <= XNIF_SLICE_MAX_PER_SLICE) {
        if (!crc_resource_update(old_resource, (const uint8_t *)input.data, (size_t)input.size, &new_resource)) {
            return enif_make_badarg(env);
        }
        out_term = enif_make_resource(env, (void *)new_resource);
        (void)enif_release_resource((void *)new_resource);
        return out_term;
    }

    new_resource = crc_resource_clone(old_resource);
    if (new_resource == NULL) {
        return enif_make_badarg(env);
    }
    xnif_slice_t *slice = xnif_slice_create("crc_fast_update", &crc_nif_crc_fast_update_2_func, 0, input.size);
    if (slice == NULL) {
        (void)enif_release_resource((void *)new_resource);
        return enif_make_badarg(env);
    }
    ERL_NIF_TERM newargv[2];
    newargv[0] = enif_make_resource(env, (void *)new_resource);
    newargv[1] = argv[1];
    (void)enif_release_resource((void *)new_resource);

    return xnif_slice_schedule(env, slice, 2, newargv);
}

static int
crc_nif_crc_fast_update_2_work(ErlNifEnv *env, xnif_slice_t *slice, int *phasep, size_t *offsetp, size_t reductions)
{
    size_t offset = *offsetp;
    crc_resource_t *resource = NULL;
    ErlNifBinary input;
    if (slice->argc != 2 || !crc_resource_get(env, slice->argv[0], (const crc_resource_t **)&resource) ||
        !enif_inspect_iolist_as_binary(env, slice->argv[1], &input)) {
        return -1;
    }
    if (!crc_resource_update_unsafe(resource, (const uint8_t *)input.data + offset, reductions)) {
        return -1;
    }
    *offsetp = offset + reductions;
    return 0;
}

static ERL_NIF_TERM
crc_nif_crc_fast_update_2_done(ErlNifEnv *env, xnif_slice_t *slice)
{
    return slice->argv[0];
}

/* crc_nif:crc_fast_final/1 */

static ERL_NIF_TERM
crc_nif_crc_fast_final_1(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    const crc_resource_t *resource = NULL;
    ERL_NIF_TERM out_term;

    if (argc != 1 || !crc_resource_get(env, argv[0], &resource) || resource->slow) {
        return enif_make_badarg(env);
    }

    ErlNifUInt64 value = 0;

    if (!crc_resource_final(resource, (void *)&value)) {
        return enif_make_badarg(env);
    }

    out_term = enif_make_uint64(env, value);

    return out_term;
}
