/* Hand-written config.h for building libmp3lame 3.100 on Apple platforms
 * without running `./configure` (no autotools in this build). Portable-C
 * path only: HAVE_NASM and HAVE_XMMINTRIN_H are deliberately left undefined
 * so nothing in libmp3lame reaches for x86 assembly or SSE intrinsics —
 * this must build and run identically on arm64 and the x86_64 simulator.
 */
#ifndef LAME_APP_CONFIG_H
#define LAME_APP_CONFIG_H

#define STDC_HEADERS 1
#define HAVE_MEMCPY 1
#define HAVE_STRCHR 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1
/* Decoder-only path (mpglib_interface.c) is excluded from the vendored
 * source entirely — this bridge only ever encodes — so HAVE_MPGLIB is left
 * undefined rather than defined-false (the upstream file gates on #ifdef,
 * not on the macro's value). */

/* util.c/util.h reach for glibc's <ieee754.h> ieee754_float32_t, which
 * doesn't exist on Darwin. `float` is IEEE 754 single-precision on every
 * platform this builds for (arm64, x86_64 simulator), so this is exact,
 * not an approximation. */
typedef float ieee754_float32_t;

#endif
