// -*- mode: c++; tab-width: 4; indent-tabs-mode: nil; st-rulers: [132] -*-
// vim: ts=4 sw=4 ft=c++ et

#ifndef XNIF_SLICE_H
#define XNIF_SLICE_H

#include <assert.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include <erl_nif.h>

#include "xnif_trace.h"

/* Global Definitions */

#ifndef XNIF_SLICE_MAX_ARGC
#define XNIF_SLICE_MAX_ARGC 10
#endif
#ifndef XNIF_SLICE_MAX_PER_SLICE
#define XNIF_SLICE_MAX_PER_SLICE 20000 // 20 KB
#endif
#ifndef XNIF_SLICE_MIN_PER_SLICE
#define XNIF_SLICE_MIN_PER_SLICE 1000 // 1 KB
#endif
#ifndef XNIF_SLICE_TIMEOUT
#define XNIF_SLICE_TIMEOUT 500 // 0.5 milliseconds
#endif

#define XNIF_SLICE_PHASE_ERROR -2
#define XNIF_SLICE_PHASE_INIT -1
#define XNIF_SLICE_PHASE_DONE 0
#define XNIF_SLICE_PHASE_WORK 1

/* Global Types */

typedef struct xnif_slice_func_s xnif_slice_func_t;
typedef struct xnif_slice_s xnif_slice_t;
typedef struct xnif_slice_trap_s xnif_slice_trap_t;
typedef int xnif_slice_work_t(ErlNifEnv *env, xnif_slice_t *slice, int *phasep, size_t *offsetp, size_t reductions);
typedef ERL_NIF_TERM xnif_slice_done_t(ErlNifEnv *env, xnif_slice_t *slice);
typedef void xnif_slice_dtor_t(ErlNifEnv *env, xnif_slice_t *slice);

struct xnif_slice_func_s {
    xnif_slice_work_t *work;
    xnif_slice_done_t *done;
    xnif_slice_dtor_t *dtor;
    xnif_slice_done_t *error;
};

struct xnif_slice_s {
    const char fun_name[256];
    xnif_slice_func_t func;
    int phase;
    size_t max_per_slice;
    size_t offset;
    size_t length;
    int error;
    void *data;
    int argc;
    ERL_NIF_TERM argv[XNIF_SLICE_MAX_ARGC + 1];
};

struct xnif_slice_trap_s {
    ErlNifTime start;
    ErlNifTime stop;
    ErlNifTime timeslice;
    size_t reductions;
    int percent;
    int total;
};

#ifdef __cplusplus
extern "C" {
#endif

/* Global Variables */

extern ErlNifResourceType *xnif_slice_resource_type;

/* NIF Callbacks */

extern int xnif_slice_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info);
extern int xnif_slice_upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data, ERL_NIF_TERM load_info);
extern void xnif_slice_unload(ErlNifEnv *env, void *priv_data);

/* Public Functions */

extern xnif_slice_t *xnif_slice_create(const char *fun_name, const xnif_slice_func_t *func, size_t offset, size_t length);
extern xnif_slice_t *xnif_slice_create_x(const char *fun_name, const xnif_slice_func_t *func, size_t offset, size_t length,
                                         size_t size);
extern ERL_NIF_TERM xnif_slice_schedule(ErlNifEnv *env, xnif_slice_t *slice, int argc, const ERL_NIF_TERM argv[]);
static void xnif_slice_release(xnif_slice_t *slice);

inline void
xnif_slice_release(xnif_slice_t *slice)
{
    (void)enif_release_resource((void *)slice);
}

#ifdef __cplusplus
}
#endif

#endif
