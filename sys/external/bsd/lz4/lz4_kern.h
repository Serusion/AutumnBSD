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
 * LZ4 block compression for the kernel.  This is a thin layer over the
 * upstream library in dist/, so that its callers need not see the
 * library's header, which wants the standard C headers.
 */

#ifndef _EXTERNAL_BSD_LZ4_LZ4_KERN_H_
#define _EXTERNAL_BSD_LZ4_LZ4_KERN_H_

#include <sys/types.h>

/* Largest output for n bytes of input, as LZ4_COMPRESSBOUND(). */
#define	LZ4_KERN_BOUND(n)	((n) + (n) / 255 + 16)

/*
 * lz4_kern_compress(state, src, srclen, dst, dstcap)
 *	Compress srclen bytes at src into dst.  Return the compressed
 *	length, or 0 if it would not fit in dstcap bytes.  state is
 *	lz4_kern_statesize() bytes, pointer aligned, and is scratch: one
 *	caller at a time.
 *
 * lz4_kern_decompress(src, srclen, dst, dstcap)
 *	Decompress the block of srclen bytes at src into dst.  Return the
 *	decompressed length, or -1 if the block is malformed or its data
 *	would not fit in dstcap bytes.  Never reads or writes outside the
 *	two buffers.
 */
size_t	lz4_kern_statesize(void);
int	lz4_kern_compress(void *, const void *, int, void *, int);
int	lz4_kern_decompress(const void *, int, void *, int);

#endif	/* _EXTERNAL_BSD_LZ4_LZ4_KERN_H_ */
