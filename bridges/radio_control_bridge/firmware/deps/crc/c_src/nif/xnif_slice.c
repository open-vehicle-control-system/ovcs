// -*- mode: c++; tab-width: 4; indent-tabs-mode: nil; st-rulers: [132] -*-
// vim: ts=4 sw=4 ft=c++ et

#include <assert.h>

#include "xnif_slice.h"

/* Global Variables */

ErlNifResourceType *xnif_slice_resource_type = NULL;

/* Static Functions (Declarations) */

static void xnif_slice_dtor(ErlNifEnv *env, void *obj);
static ERL_NIF_TERM xnif_slice_trap(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

/* NIF Callbacks */

int
xnif_slice_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    if (xnif_slice_resource_type == NULL) {
        xnif_slice_resource_type =
            enif_open_resource_type(env, NULL, "xnif_slice", xnif_slice_dtor, ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);
        if (xnif_slice_resource_type == NULL) {
            return -1;
        }
    }
    return 0;
}

int
xnif_slice_upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data, ERL_NIF_TERM load_info)
{
    if (xnif_slice_resource_type == NULL) {
        return xnif_slice_load(env, priv_data, load_info);
    }
    return 0;
}

void
xnif_slice_unload(ErlNifEnv *env, void *priv_data)
{
    xnif_slice_resource_type = NULL;
    return;
}

/* Public Functions */

xnif_slice_t *
xnif_slice_create(const char *fun_name, const xnif_slice_func_t *func, size_t offset, size_t length)
{
    return xnif_slice_create_x(fun_name, func, offset, length, sizeof(xnif_slice_t));
}

xnif_slice_t *
xnif_slice_create_x(const char *fun_name, const xnif_slice_func_t *func, size_t offset, size_t length, size_t size)
{
    assert(size >= sizeof(xnif_slice_t));
    assert(offset <= length);
    xnif_slice_t *slice = (void *)enif_alloc_resource(xnif_slice_resource_type, size);
    if (slice == NULL) {
        return NULL;
    }
    (void)memset(slice, 0, size);
    (void)strncpy((char *)slice->fun_name, fun_name, sizeof(slice->fun_name) - 1);
    (void)memcpy(&slice->func, func, sizeof(xnif_slice_func_t));
    slice->phase = XNIF_SLICE_PHASE_INIT;
    slice->max_per_slice = XNIF_SLICE_MAX_PER_SLICE;
    slice->offset = offset;
    slice->length = length;
    return slice;
}

ERL_NIF_TERM
xnif_slice_schedule(ErlNifEnv *env, xnif_slice_t *slice, int argc, const ERL_NIF_TERM argv[])
{
    int i;
    assert(argc <= XNIF_SLICE_MAX_ARGC);
    slice->argc = argc + 1;
    slice->argv[0] = enif_make_resource(env, (void *)slice);
    for (i = 0; i < argc; i++) {
        slice->argv[i + 1] = argv[i];
    }
    if (slice->phase == XNIF_SLICE_PHASE_INIT) {
        slice->phase = XNIF_SLICE_PHASE_WORK;
    }
    (void)xnif_slice_release(slice);
    return enif_schedule_nif(env, slice->fun_name, 0, xnif_slice_trap, slice->argc, slice->argv);
}

/* Static Functions (Definitions) */

static void
xnif_slice_dtor(ErlNifEnv *env, void *obj)
{
    xnif_slice_t *slice = (void *)obj;
    if (slice->func.dtor != NULL) {
        (void)slice->func.dtor(env, slice);
    }
    return;
}

static ERL_NIF_TERM
xnif_slice_trap(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    xnif_slice_t *slice = NULL;

    if (argc < 1 || !enif_get_resource(env, argv[0], xnif_slice_resource_type, (void **)&slice)) {
        return enif_make_badarg(env);
    }

    slice->argc = argc - 1;
    if (slice->argc) {
        (void)memcpy(slice->argv, argv + 1, (argc - 1) * sizeof(ERL_NIF_TERM));
    }

    int phase;
    size_t offset;
    size_t reductions;
    ERL_NIF_TERM out_term;
    xnif_slice_trap_t trap_buff;
    xnif_slice_trap_t *trap = &trap_buff;
    trap->reductions = 0;
    trap->percent = 0;
    trap->total = 0;

    while (slice->offset < slice->length) {
        trap->start = enif_monotonic_time(ERL_NIF_USEC);
        phase = slice->phase;
        offset = slice->offset;
        reductions = slice->max_per_slice;
        if ((offset + reductions) > slice->length) {
            reductions = slice->length - offset;
        }
        if (phase >= XNIF_SLICE_PHASE_WORK) {
            XNIF_TRACE_F("xnif_slice_trap:%s:%d phase = %d, offset = %llu, reductions = %llu\n", __FILE__, __LINE__, phase, offset,
                         reductions);
            if ((slice->error = slice->func.work(env, slice, &phase, &offset, reductions)) != 0) {
                slice->phase = XNIF_SLICE_PHASE_ERROR;
                if (slice->func.error != NULL) {
                    out_term = slice->func.error(env, slice);
                } else {
                    out_term = enif_make_badarg(env);
                }
                return out_term;
            }
            if (offset > slice->offset) {
                trap->reductions += offset - slice->offset;
                slice->offset = offset;
            }
            if (slice->offset >= slice->length && phase == slice->phase) {
                phase = XNIF_SLICE_PHASE_DONE;
            }
            if (phase != slice->phase) {
                slice->phase = phase;
            }
        }
        if (phase == XNIF_SLICE_PHASE_DONE) {
            break;
        }
        trap->stop = enif_monotonic_time(ERL_NIF_USEC);
        /* determine how much of the timeslice was used */
        trap->timeslice = trap->stop - trap->start;
        trap->percent = (int)((trap->timeslice * 100) / XNIF_SLICE_TIMEOUT);
        trap->total += trap->percent;
        if (trap->percent > 100) {
            trap->percent = 100;
        } else if (trap->percent == 0) {
            trap->percent = 1;
        }
        if (enif_consume_timeslice(env, trap->percent) != 0) {
            XNIF_TRACE_F("xnif_slice_trap:%s:%d trap->total = %d\n", __FILE__, __LINE__, trap->total);
            /* the timeslice has been used up, so adjust our max_per_slice byte count based on the processing we've done, then
             * reschedule to run again */
            slice->max_per_slice = trap->reductions;
            if (trap->total > 100) {
                int m = (int)(trap->total / 100);
                if (m == 1) {
                    slice->max_per_slice -= (unsigned long)(slice->max_per_slice * (trap->total - 100) / 100);
                } else {
                    slice->max_per_slice = (unsigned long)(slice->max_per_slice / m);
                }
            }
            if (slice->max_per_slice < XNIF_SLICE_MIN_PER_SLICE) {
                slice->max_per_slice = XNIF_SLICE_MIN_PER_SLICE;
            }
            int i;
            for (i = slice->argc; i > 0; i--) {
                slice->argv[i] = slice->argv[i - 1];
            }
            slice->argc += 1;
            slice->argv[0] = argv[0];
            return enif_schedule_nif(env, slice->fun_name, 0, xnif_slice_trap, slice->argc, slice->argv);
        }
    }

    out_term = slice->func.done(env, slice);
    return out_term;
}
