// -*- mode: c++; tab-width: 4; indent-tabs-mode: nil; st-rulers: [132] -*-
// vim: ts=4 sw=4 ft=c++ et

static int crc_init(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[], bool slow, const crc_resource_t **resp);
static int crc_init_atom(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[], bool slow, const crc_resource_t **resp);
static int crc_init_map(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[], bool slow, const crc_resource_t **resp);
static int crc_init_map_extend(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[], bool slow, const crc_resource_t **resp);
static int crc_init_ref(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[], bool slow, const crc_resource_t **resp);
static int crc_init_tuple(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[], bool slow, const crc_resource_t **resp);

/* crc_nif:crc_fast_init/1 */

static ERL_NIF_TERM
crc_nif_crc_fast_init_1(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    const crc_resource_t *resource = NULL;
    ERL_NIF_TERM out_term;

    if (argc != 1 || !crc_init(env, argc, argv, false, &resource)) {
        return enif_make_badarg(env);
    }

    out_term = enif_make_resource(env, (void *)resource);
    (void)enif_release_resource((void *)resource);

    return out_term;
}

/* crc_nif:crc_slow_init/1 */

static ERL_NIF_TERM
crc_nif_crc_slow_init_1(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    const crc_resource_t *resource = NULL;
    ERL_NIF_TERM out_term;

    if (argc != 1 || !crc_init(env, argc, argv, true, &resource)) {
        return enif_make_badarg(env);
    }

    out_term = enif_make_resource(env, (void *)resource);
    (void)enif_release_resource((void *)resource);

    return out_term;
}

/* Internal Functions */

static int
crc_init(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[], bool slow, const crc_resource_t **resp)
{
    if (enif_is_atom(env, argv[0])) {
        return crc_init_atom(env, argc, argv, slow, resp);
    } else if (enif_is_map(env, argv[0])) {
        return crc_init_map(env, argc, argv, slow, resp);
    } else if (enif_is_tuple(env, argv[0])) {
        return crc_init_tuple(env, argc, argv, slow, resp);
    } else if (enif_is_ref(env, argv[0])) {
        return crc_init_ref(env, argc, argv, slow, resp);
    } else {
        return 0;
    }
}

static int
crc_init_atom(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[], bool slow, const crc_resource_t **resp)
{
    const crc_model_t *model = NULL;

    if (argc != 1 || !crc_model_get(argv[0], &model)) {
        return 0;
    }

    crc_resource_t *resource = crc_resource_create(NULL, model, slow);
    if (resource == NULL) {
        return 0;
    }
    *resp = resource;

    return 1;
}

static int
crc_init_map(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[], bool slow, const crc_resource_t **resp)
{
    size_t arity;

    if (argc != 1 || !enif_get_map_size(env, argv[0], &arity) || arity < 1) {
        return 0;
    }

    /* Maybe extend pre-defined model */

    ERL_NIF_TERM extend;

    if (enif_get_map_value(env, argv[0], ATOM_extend, &extend)) {
        ERL_NIF_TERM extargv[2];
        extargv[0] = extend;
        extargv[1] = argv[0];
        return crc_init_map_extend(env, 2, extargv, slow, resp);
    }

    /* Required Parameters */

    ERL_NIF_TERM width;
    ERL_NIF_TERM poly;
    ERL_NIF_TERM init;
    ERL_NIF_TERM refin;
    ERL_NIF_TERM refout;
    ERL_NIF_TERM xorout;

    if (!enif_get_map_value(env, argv[0], ATOM_width, &width) || !enif_get_map_value(env, argv[0], ATOM_poly, &poly) ||
        !enif_get_map_value(env, argv[0], ATOM_init, &init) || !enif_get_map_value(env, argv[0], ATOM_refin, &refin) ||
        !enif_get_map_value(env, argv[0], ATOM_refout, &refout) || !enif_get_map_value(env, argv[0], ATOM_xorout, &xorout)) {
        return 0;
    }

    /* Optional Parameters */

    ERL_NIF_TERM check;
    ERL_NIF_TERM residue;
    ERL_NIF_TERM sick;

    if (!enif_get_map_value(env, argv[0], ATOM_check, &check)) {
        check = ATOM_nil;
    }

    if (!enif_get_map_value(env, argv[0], ATOM_residue, &residue)) {
        residue = ATOM_nil;
    }

    if (!enif_get_map_value(env, argv[0], ATOM_sick, &sick)) {
        sick = ATOM_nil;
    }

    ERL_NIF_TERM newargv[1];
    newargv[0] = enif_make_tuple9(env, width, poly, init, refin, refout, xorout, check, residue, sick);
    return crc_init_tuple(env, 1, newargv, slow, resp);
}

static int
crc_init_map_extend(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[], bool slow, const crc_resource_t **resp)
{
    const crc_resource_t *old_resource = NULL;
    size_t arity;

    if (argc != 2 || !crc_init(env, 1, argv, slow, &old_resource)) {
        return 0;
    }
    if (!enif_get_map_size(env, argv[1], &arity) || arity < 1) {
        (void)enif_release_resource((void *)old_resource);
        return 0;
    }

    /* All keys are optional when extending */

    ERL_NIF_TERM width;
    ERL_NIF_TERM poly;
    ERL_NIF_TERM init;
    ERL_NIF_TERM refin;
    ERL_NIF_TERM refout;
    ERL_NIF_TERM xorout;
    ERL_NIF_TERM check;
    ERL_NIF_TERM residue;
    ERL_NIF_TERM sick;

#define CRC_INIT_MAP_EXTEND_CALL(type)                                                                                             \
    do {                                                                                                                           \
        const crc_resource_##type##_t *r = (void *)old_resource;                                                                   \
        if (!enif_get_map_value(env, argv[1], ATOM_width, &width)) {                                                               \
            width = enif_make_uint(env, (unsigned int)r->model->width);                                                            \
        }                                                                                                                          \
        if (!enif_get_map_value(env, argv[1], ATOM_poly, &poly)) {                                                                 \
            poly = (r->model->width > 32) ? enif_make_uint64(env, (ErlNifUInt64)r->model->poly)                                    \
                                          : enif_make_uint(env, (unsigned int)r->model->poly);                                     \
        }                                                                                                                          \
        if (!enif_get_map_value(env, argv[1], ATOM_init, &init)) {                                                                 \
            init = (r->model->width > 32) ? enif_make_uint64(env, (ErlNifUInt64)r->model->init)                                    \
                                          : enif_make_uint(env, (unsigned int)r->model->init);                                     \
        }                                                                                                                          \
        if (!enif_get_map_value(env, argv[1], ATOM_refin, &refin)) {                                                               \
            refin = (r->model->refin) ? ATOM_true : ATOM_false;                                                                    \
        }                                                                                                                          \
        if (!enif_get_map_value(env, argv[1], ATOM_refout, &refout)) {                                                             \
            refout = (r->model->refout) ? ATOM_true : ATOM_false;                                                                  \
        }                                                                                                                          \
        if (!enif_get_map_value(env, argv[1], ATOM_xorout, &xorout)) {                                                             \
            xorout = (r->model->width > 32) ? enif_make_uint64(env, (ErlNifUInt64)r->model->xorout)                                \
                                            : enif_make_uint(env, (unsigned int)r->model->xorout);                                 \
        }                                                                                                                          \
        if (!enif_get_map_value(env, argv[1], ATOM_check, &check)) {                                                               \
            check = (r->model->width > 32) ? enif_make_uint64(env, (ErlNifUInt64)r->model->check)                                  \
                                           : enif_make_uint(env, (unsigned int)r->model->check);                                   \
        }                                                                                                                          \
        if (!enif_get_map_value(env, argv[1], ATOM_residue, &residue)) {                                                           \
            residue = (r->model->width > 32) ? enif_make_uint64(env, (ErlNifUInt64)r->model->residue)                              \
                                             : enif_make_uint(env, (unsigned int)r->model->residue);                               \
        }                                                                                                                          \
        if (!enif_get_map_value(env, argv[1], ATOM_sick, &sick)) {                                                                 \
            sick = (r->model->sick) ? ATOM_true : ATOM_false;                                                                      \
        }                                                                                                                          \
    } while (0)

    switch (old_resource->model->bits) {
    case 8:
        CRC_INIT_MAP_EXTEND_CALL(uint8);
        break;
    case 16:
        CRC_INIT_MAP_EXTEND_CALL(uint16);
        break;
    case 32:
        CRC_INIT_MAP_EXTEND_CALL(uint32);
        break;
    case 64:
        CRC_INIT_MAP_EXTEND_CALL(uint64);
        break;
    default:
        (void)enif_release_resource((void *)old_resource);
        return 0;
    }

#undef CRC_INIT_MAP_EXTEND_CALL

    ERL_NIF_TERM newargv[1];
    newargv[0] = enif_make_tuple9(env, width, poly, init, refin, refout, xorout, check, residue, sick);
    (void)enif_release_resource((void *)old_resource);
    return crc_init_tuple(env, 1, newargv, slow, resp);
}

static int
crc_init_ref(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[], bool slow, const crc_resource_t **resp)
{
    const crc_resource_t *old_resource = NULL;

    if (argc != 1 || !crc_resource_get(env, argv[0], &old_resource)) {
        return 0;
    }

    crc_resource_t *new_resource = crc_resource_create(old_resource, old_resource->model, slow);
    if (new_resource == NULL) {
        return 0;
    }
    *resp = new_resource;

    return 1;
}

static int
crc_init_tuple(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[], bool slow, const crc_resource_t **resp)
{
    int arity;
    const ERL_NIF_TERM *tuple;

    if (argc != 1 || !enif_get_tuple(env, argv[0], &arity, &tuple) || arity != 9) {
        return 0;
    }

    unsigned int width;
    ErlNifUInt64 poly;
    ErlNifUInt64 init;
    ERL_NIF_TERM refin;
    ERL_NIF_TERM refout;
    ErlNifUInt64 xorout;
    ErlNifUInt64 check;
    ErlNifUInt64 residue;
    ERL_NIF_TERM sick;

    refin = tuple[3];
    refout = tuple[4];
    sick = tuple[8];

    if (sick == ATOM_nil) {
        sick = ATOM_false;
    }

    if (!enif_get_uint(env, tuple[0], &width) || width > 0x40 || !enif_get_uint64(env, tuple[1], &poly) ||
        !enif_get_uint64(env, tuple[2], &init) || !(refin == ATOM_false || refin == ATOM_true) ||
        !(refout == ATOM_false || refout == ATOM_true) || !enif_get_uint64(env, tuple[5], &xorout) ||
        !(sick == ATOM_false || sick == ATOM_true)) {
        return 0;
    }

    if (tuple[6] == ATOM_nil) {
        check = 0;
    } else if (!enif_get_uint64(env, tuple[6], &check)) {
        return 0;
    }

    if (tuple[7] == ATOM_nil) {
        residue = 0;
    } else if (!enif_get_uint64(env, tuple[7], &residue)) {
        return 0;
    }

    ErlNifUInt64 msb_mask = 1;
    msb_mask <<= (width - 1);
    ErlNifUInt64 crc_mask = 1;
    crc_mask |= ((msb_mask - 1) << 1);

    if (poly > crc_mask || init > crc_mask || xorout > crc_mask || check > crc_mask || residue > crc_mask) {
        return 0;
    }

    /* Fast mode not supported for even polynomials */
    if (!slow && (poly % 2) == 0) {
        return 0;
    }

    const crc_model_t *model = NULL;
    crc_resource_t *resource = NULL;
    uint8_t bits = ((width / 8) + (((width % 8) | ((~(width % 8) + 1) >> 7)) & 1)) * 8;
    switch (bits) {
    case 8:
    case 16:
    case 32:
    case 64:
        break;
    default:
        if (bits > 8 && bits < 16) {
            bits = 16;
        } else if (bits > 16 && bits < 32) {
            bits = 32;
        } else if (bits > 32 && bits < 64) {
            bits = 64;
        } else {
            return 0;
        }
        break;
    }

#define CRC_INIT_TUPLE_CALL(type)                                                                                                  \
    do {                                                                                                                           \
        crc_model_##type##_t m_buff;                                                                                               \
        crc_model_##type##_t *m = &m_buff;                                                                                         \
        m->super._link.prev = m->super._link.next = NULL;                                                                          \
        (void)crc_linklist_init_anchor(&m->super._link);                                                                           \
        m->super.is_root = true;                                                                                                   \
        m->super.root_key = ATOM_nil;                                                                                              \
        m->super.root_keystring[0] = '\0';                                                                                         \
        m->super.bits = bits;                                                                                                      \
        m->sick = (sick == ATOM_true) ? true : false;                                                                              \
        m->width = (uint8_t)width;                                                                                                 \
        m->poly = (type##_t)poly;                                                                                                  \
        m->init = (type##_t)init;                                                                                                  \
        m->refin = (refin == ATOM_true) ? true : false;                                                                            \
        m->refout = (refout == ATOM_true) ? true : false;                                                                          \
        m->xorout = (type##_t)xorout;                                                                                              \
        m->check = (type##_t)check;                                                                                                \
        m->residue = (type##_t)residue;                                                                                            \
        if (crc_model_match(&m->super, &model)) {                                                                                  \
            resource = crc_resource_create(NULL, model, slow);                                                                     \
        } else {                                                                                                                   \
            (void)crc_model_init(&m->super);                                                                                       \
            resource = crc_resource_create(NULL, &m->super, slow);                                                                 \
            model = (void *)resource->model;                                                                                       \
        }                                                                                                                          \
    } while (0)

    switch (bits) {
    case 8:
        CRC_INIT_TUPLE_CALL(uint8);
        break;
    case 16:
        CRC_INIT_TUPLE_CALL(uint16);
        break;
    case 32:
        CRC_INIT_TUPLE_CALL(uint32);
        break;
    case 64:
        CRC_INIT_TUPLE_CALL(uint64);
        break;
    default:
        return 0;
    }

#undef CRC_INIT_TUPLE_CALL

    if (resource == NULL) {
        return 0;
    }

    if (model->root_key == ATOM_nil) {
        (void)crc_algorithm_compile((void *)model);
    }
    *resp = resource;

    return 1;
}
