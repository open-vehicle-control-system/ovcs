// -*- mode: c++; tab-width: 4; indent-tabs-mode: nil; st-rulers: [132] -*-
// vim: ts=4 sw=4 ft=c++ et

#ifndef XNIF_TRACE_H
#define XNIF_TRACE_H

#include <assert.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include <erl_nif.h>

#ifdef __cplusplus
extern "C" {
#endif

extern int erts_fprintf(FILE *, const char *, ...);

#ifdef __cplusplus
}
#endif

// #define XNIF_TRACE 1
#ifdef XNIF_TRACE
#define XNIF_TRACE_C(c)                                                                                                            \
    do {                                                                                                                           \
        putchar(c);                                                                                                                \
        fflush(stdout);                                                                                                            \
    } while (0)
#define XNIF_TRACE_S(s)                                                                                                            \
    do {                                                                                                                           \
        fputs((s), stdout);                                                                                                        \
        fflush(stdout);                                                                                                            \
    } while (0)
#define XNIF_TRACE_F(...)                                                                                                          \
    do {                                                                                                                           \
        erts_fprintf(stderr, "%p ", (void *)enif_thread_self());                                                                   \
        erts_fprintf(stderr, __VA_ARGS__);                                                                                         \
        fflush(stderr);                                                                                                            \
    } while (0)
#else
#define XNIF_TRACE_C(c) ((void)(0))
#define XNIF_TRACE_S(s) ((void)(0))
#define XNIF_TRACE_F(...) ((void)(0))
#endif

#endif
