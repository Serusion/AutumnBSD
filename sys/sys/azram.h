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
 * Interface to azram(4), the compressed cache in front of swap: the
 * statistics in vm.azram.stats.  See azram(4) for the semantics.
 */

#ifndef _SYS_AZRAM_H_
#define _SYS_AZRAM_H_

#include <sys/types.h>

/*
 * Compressed sizes of the pages tried, in buckets of 1/64 page: bucket
 * i holds the sizes from i/64 page (exclusive) to (i+1)/64 page
 * (inclusive), and bucket 64 the pages that LZ4 made larger than a page.
 */
#define	AZRAM_NBUCKET		65

/* st_flags */
#define	AZRAM_F_ENABLE		0x01	/* vm.azram.enable */
#define	AZRAM_F_MEASURE		0x02	/* vm.azram.measure */
#define	AZRAM_F_BOOTOFF		0x04	/* the boot flag turned azram off */

/* Counters, since boot or since the last reset. */
struct azram_counters {
	uint64_t	c_tried;	/* pages looked at on their way to swap */
	uint64_t	c_seen_same;	/* of those, pages of one byte value */
	uint64_t	c_stored;	/* pages kept compressed */
	uint64_t	c_stored_same;	/* pages kept as one byte value */
	uint64_t	c_rej_size;	/* refused: compressed above reject_size */
	uint64_t	c_rej_budget;	/* refused: the pool was at pool_max */
	uint64_t	c_rej_nomem;	/* refused: no memory */
	uint64_t	c_loads;	/* pages paged in from azram */
	uint64_t	c_loads_same;	/* of those, pages of one byte value */
	uint64_t	c_frees;	/* entries dropped with their swap slot */
	uint64_t	c_swap_writes;	/* pages written to the swap device */
	uint64_t	c_swap_reads;	/* pages read from the swap device */
	uint64_t	c_swap_read_ns;	/* time spent waiting for those reads */
	uint64_t	c_compress_ns;	/* time spent compressing */
	uint64_t	c_decompress_ns; /* time spent decompressing or filling */
	uint64_t	c_hist[AZRAM_NBUCKET]; /* compressed sizes of the pages
					   tried, other than one-value pages */
};

/* vm.azram.stats; writing it resets the counters. */
struct azram_stats {
	uint32_t	st_flags;	/* AZRAM_F_* */
	uint32_t	st_pagesize;
	uint32_t	st_reject_size;	/* vm.azram.reject_size, bytes */
	uint32_t	st_class_size;	/* size classes are multiples of this */
	uint64_t	st_pool_max;	/* vm.azram.pool_max, bytes */
	uint64_t	st_reset_time;	/* uptime (s) of the last reset, or 0 */
	uint64_t	st_uptime;	/* uptime (s) now */

	/* What azram holds now. */
	uint64_t	st_entries;	/* pages kept compressed */
	uint64_t	st_same_entries; /* pages kept as one byte value */
	uint64_t	st_data_bytes;	/* their compressed sizes, summed */
	uint64_t	st_class_bytes;	/* the same, rounded up to size classes */
	uint64_t	st_pool_bytes;	/* memory the pool holds for them */
	uint64_t	st_meta_bytes;	/* memory of the entries and the index */

	struct azram_counters st_c;
};

#endif	/* _SYS_AZRAM_H_ */
