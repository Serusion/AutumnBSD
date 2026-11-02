/*	$NetBSD$	*/

/*-
 * Copyright (c) 2026 yuragi
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

/*
 * Kernel glue for the upstream LZ4 library (dist/, version 1.10.0).
 *
 * dist/lz4.c is built unchanged, with the headers in include/ standing
 * in for the standard C ones.  files.lz4 builds it with LZ4_HEAPMODE=1
 * and LZ4_USER_MEMORY_FUNCTIONS: with LZ4_HEAPMODE=0 the functions that
 * make their own compression state keep it on the stack (16 KB), which
 * a kernel stack cannot spare.  The kernel passes a state it allocated
 * up front to the _extState functions instead, and the allocator below
 * always fails, so that the other functions return an error rather
 * than allocate behind the caller's back.
 */

#include <sys/cdefs.h>
__KERNEL_RCSID(0, "$NetBSD$");

#include <sys/types.h>
#include <sys/systm.h>

#include "lz4.h"

#include <external/bsd/lz4/lz4_kern.h>

void	*LZ4_malloc(size_t);
void	*LZ4_calloc(size_t, size_t);
void	LZ4_free(void *);

__CTASSERT(LZ4_KERN_BOUND(4096) == LZ4_COMPRESSBOUND(4096));

void *
LZ4_malloc(size_t size)
{

	return NULL;
}

void *
LZ4_calloc(size_t n, size_t size)
{

	return NULL;
}

void
LZ4_free(void *p)
{

	KASSERT(p == NULL);
}

size_t
lz4_kern_statesize(void)
{

	return (size_t)LZ4_sizeofState();
}

int
lz4_kern_compress(void *state, const void *src, int srclen, void *dst,
    int dstcap)
{

	return LZ4_compress_fast_extState(state, src, dst, srclen, dstcap, 1);
}

int
lz4_kern_decompress(const void *src, int srclen, void *dst, int dstcap)
{
	int n;

	n = LZ4_decompress_safe(src, dst, srclen, dstcap);
	return n < 0 ? -1 : n;
}
