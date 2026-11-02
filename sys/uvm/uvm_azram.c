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
 * azram: a compressed cache in front of swap.
 *
 * Anonymous pages on their way to the swap device are kept in memory,
 * compressed with LZ4, under the swap slot that UVM has allocated for
 * them.  A page that cannot be kept is written to the device as before,
 * so azram can always say no: to a page that does not compress, when its
 * pool is full, and when memory is short.
 *
 * Store.  uvm_swap_put() hands azram_store() each cluster of pages the
 * pagedaemon writes out, with their consecutive slots.  A page whose
 * bytes are all the same is kept as that byte in the index itself.  Any
 * other page is compressed into a per-CPU buffer; if it shrank to
 * vm.azram.reject_size bytes or less, it is copied into the pool of the
 * smallest size class that holds it.  uvm_swap_put() completes the pages
 * kept at once, as if their write had finished, and writes the others to
 * the device in runs of consecutive slots.  Nothing here sleeps for
 * memory: the pagedaemon is trying to free some.  Every allocation is
 * PR_NOWAIT, and leaves the kernel's reserve, and AZRAM_FREE_SLACK pages
 * above it, alone, as an ordinary allocation would: uvm_pagealloc_strat()
 * would let a system LWP, such as the pagedaemon, take the reserve.  A
 * page that fits in memory the pool has already is stored however little
 * memory is free, which frees a page.
 *
 * Load.  uvm_swap_get() asks azram_load() before it reads the device.
 * The entry stays after the page-in: UVM keeps the slot while the page
 * is clean, and frees such a page again without writing it.  An entry
 * that does not decompress to exactly a page means that the pool is
 * corrupt, and panics rather than hand wrong data to a process.
 *
 * Free.  uvm_swap_free() drops the entries of the slots it frees before
 * it gives them back, so that a slot is never reused with an old entry;
 * uvm_swap_markbad() drops them too, since a bad slot is never read.
 * swap_off() pages everything in and frees its slots, which leaves no
 * entry on the device.
 *
 * Contexts.  A store comes from the pagedaemon and a load from a page
 * fault or swapoff, in thread context.  A free can also come from the
 * completion of an asynchronous write to swap, which biodone() may run
 * in a soft interrupt: so the pools are IPL_SOFTBIO, and the leaves of
 * the index come from a pool rather than kmem(9).
 *
 * Serialization.  UVM never stores, loads or frees one slot in two
 * threads at once: the page is busy during a store and during a load,
 * and its owner frees the slot only after the page is unbusied (a page
 * freed while busy is marked PG_RELEASED and freed by whoever unbusies
 * it).  So the locks here protect the index, not the lifetime of an
 * entry.  The index is a table of leaves of AZRAM_LEAFSIZE words,
 * indexed by drum slot; the words of a leaf, and its directory entry,
 * are protected by one of AZRAM_NLOCKS mutexes.  A load decompresses
 * under that mutex, so that an entry stays put while it is read even
 * once something else can drop it (writeback, phase 2).  The directory
 * grows at swapon with all the mutexes held, and is never shrunk.
 *
 * Pool.  Compressed data goes to one pool(9) per size class, in steps of
 * 1/64 page up to 7/8 page.  A class takes its memory in chunks of 2 to
 * 16 pages, the smallest that leaves at most 1/32 unused at its end;
 * with one-page chunks a 2.1 KB page would take a whole page.  The
 * chunks are counted against vm.azram.pool_max, so the budget holds
 * however fragmented the pool gets.
 *
 * vm.azram.measure compresses the pages that go to swap only to count
 * their sizes, without keeping them, to estimate what azram would save.
 * The swap device counters work with azram off too, for a baseline.
 */

#include <sys/cdefs.h>
__KERNEL_RCSID(0, "$NetBSD$");

#include <sys/param.h>
#include <sys/types.h>
#include <sys/atomic.h>
#include <sys/azram.h>
#include <sys/kernel.h>
#include <sys/kmem.h>
#include <sys/mutex.h>
#include <sys/percpu.h>
#include <sys/pool.h>
#include <sys/reboot.h>
#include <sys/sysctl.h>
#include <sys/systm.h>
#include <sys/time.h>
#include <sys/vmem.h>

#include <uvm/uvm.h>
#include <uvm/uvm_azram.h>

#include <external/bsd/lz4/lz4_kern.h>

/*
 * On x86 the boot flag -4 (RB_MD4) keeps azram off for one boot, as it
 * keeps aprefetch(4) off: /etc/rc.d/azram leaves vm.azram.enable alone
 * when vm.azram.boot_disabled is set.  Other ports have no such flag yet.
 */
#if defined(__i386__) || defined(__x86_64__)
#define	AZRAM_BOOT_DISABLED()	((boothowto & RB_MD4) != 0)
#else
#define	AZRAM_BOOT_DISABLED()	false
#endif

#define	AZRAM_LEAFSHIFT		9
#define	AZRAM_LEAFSIZE		(1U << AZRAM_LEAFSHIFT)	/* slots per leaf */
#define	AZRAM_LEAFMASK		(AZRAM_LEAFSIZE - 1)
#define	AZRAM_NLOCKS		64
#define	AZRAM_NCLASS		56	/* size classes, 1/64 to 7/8 page */
#define	AZRAM_NCHUNK		4	/* chunk sizes, 2 to 16 pages */
#define	AZRAM_FREEBATCH		32	/* entries dropped per lock hold */
#define	AZRAM_FREE_SLACK	4	/* pages, see above */

/*
 * A word of the index: 0 for no entry, a pointer to the struct
 * azram_entry of a compressed page, or the byte of a page whose bytes
 * are all the same, tagged in bit 0.
 */
#define	AZRAM_W_SAME		((uintptr_t)1)
#define	AZRAM_W_MKSAME(b)	(((uintptr_t)(b) << 8) | AZRAM_W_SAME)
#define	AZRAM_W_BYTE(w)		((uint8_t)((w) >> 8))

/* Why the last chunk allocation failed. */
#define	AZRAM_FAIL_NOMEM	0
#define	AZRAM_FAIL_BUDGET	1

struct azram_entry {
	void		*ae_data;	/* in azram_pools[ae_class] */
	uint16_t	ae_size;	/* compressed bytes */
	uint8_t		ae_class;
	uint8_t		ae_flags;	/* none yet */
	uint32_t	ae_atime;	/* time_uptime of the last store or load */
};

struct azram_leaf {
	uintptr_t	al_w[AZRAM_LEAFSIZE];
};

struct azram_dir {
	struct azram_leaf *ad_leaf;
	u_int		ad_count;	/* words of ad_leaf that are not 0 */
};

/*
 * Per CPU.  ac_c is written only by its CPU, with preemption off.  A
 * store takes the buffers of the CPU it starts on, under ac_lock, and
 * keeps them if it moves to another CPU meanwhile.
 */
struct azram_cpu {
	kmutex_t	ac_lock;	/* ac_state, ac_buf */
	void		*ac_state;	/* LZ4 compression state */
	uint8_t		*ac_buf;	/* the compressed page */
	struct azram_counters ac_c;
};

static int		azram_enable;
static int		azram_measure;
static int		azram_reject_size;
static uint64_t		azram_pool_max;		/* bytes */
static u_int		azram_pool_maxpages;
static int		azram_boot_disabled;
static bool		azram_ready;

static u_int		azram_step;		/* bytes per size class */
static size_t		azram_bufsize;

static struct pool	azram_pools[AZRAM_NCLASS];
static char		azram_pool_names[AZRAM_NCLASS][16];
static struct pool_allocator azram_pallocs[AZRAM_NCHUNK];
static struct pool	azram_entry_pool;
static struct pool	azram_leaf_pool;
static percpu_t		*azram_percpu;		/* struct azram_cpu * */

static union {
	kmutex_t	lock;
	uint8_t		pad[COHERENCY_UNIT];
} azram_locks[AZRAM_NLOCKS] __cacheline_aligned;
__CTASSERT(sizeof(kmutex_t) <= COHERENCY_UNIT);

/* Changed with all of azram_locks held, read with one of them held. */
static struct azram_dir	*azram_dir;
static u_int		azram_ndir;
static kmutex_t		azram_grow_lock;	/* serializes the changes */

static volatile u_int	azram_nentries;		/* compressed pages */
static volatile u_int	azram_nsame;		/* one-value pages */
static volatile u_long	azram_data_bytes;
static volatile u_long	azram_class_bytes;
static volatile u_int	azram_pool_pages;	/* pages of the chunks */
static volatile int	azram_chunk_fail;	/* AZRAM_FAIL_* */

static kmutex_t		azram_stats_lock;	/* azram_base, _reset_time */
static struct azram_counters azram_base;
static uint64_t		azram_reset_time;

__CTASSERT(sizeof(struct azram_counters) % sizeof(uint64_t) == 0);

static inline kmutex_t *
azram_lock(u_int l)
{

	return &azram_locks[l % AZRAM_NLOCKS].lock;
}

static inline uint64_t
azram_nsec(void)
{
	struct timespec ts;

	nanouptime(&ts);
	return timespec2ns(&ts);
}

static inline bool
azram_empty(void)
{

	return atomic_load_relaxed(&azram_nentries) == 0 &&
	    atomic_load_relaxed(&azram_nsame) == 0;
}

/*
 * Counters of this CPU, until azram_counters_exit().  Preemption is off
 * in between.
 */
static inline struct azram_counters *
azram_counters_enter(void)
{
	struct azram_cpu * const *acp = percpu_getref(azram_percpu);

	return &(*acp)->ac_c;
}

static inline void
azram_counters_exit(void)
{

	percpu_putref(azram_percpu);
}

#define	AZRAM_COUNT(field, n)	do {					\
	azram_counters_enter()->field += (n);				\
	azram_counters_exit();						\
} while (/*CONSTCOND*/0)

static struct azram_cpu *
azram_mycpu(void)
{
	struct azram_cpu * const *acp;
	struct azram_cpu *ac;

	acp = percpu_getref(azram_percpu);
	ac = *acp;
	percpu_putref(azram_percpu);
	return ac;
}

/*
 * Whether free memory is so low that azram should not take npages more.
 * Only asked when azram is about to allocate, so it can afford an exact
 * count.
 */
static bool
azram_memlow(u_int npages)
{

	return uvm_availmem(false) <
	    uvmexp.reserve_kernel + AZRAM_FREE_SLACK + (int)npages;
}

/*
 * Pool chunks.  The budget is charged before the memory is allocated,
 * so that concurrent allocations cannot overshoot it together.
 */
static void *
azram_chunk_alloc(struct pool *pp, int flags)
{
	const vsize_t size = pp->pr_alloc->pa_pagesz;
	const u_int npages = size >> PAGE_SHIFT;
	const u_int max = atomic_load_relaxed(&azram_pool_maxpages);
	vmem_addr_t va;
	u_int cur;

	do {
		cur = atomic_load_relaxed(&azram_pool_pages);
		if (cur > max || max - cur < npages) {
			azram_chunk_fail = AZRAM_FAIL_BUDGET;
			return NULL;
		}
	} while (atomic_cas_uint(&azram_pool_pages, cur, cur + npages) != cur);

	/* Never sleep, whatever pool(9) asks for: see above. */
	if (azram_memlow(npages) || uvm_km_va_starved_p() ||
	    uvm_km_kmem_alloc(kmem_va_arena, size, VM_NOSLEEP | VM_INSTANTFIT,
		&va) != 0) {
		atomic_add_int(&azram_pool_pages, -(int)npages);
		return NULL;
	}
	return (void *)va;
}

static void
azram_chunk_free(struct pool *pp, void *v)
{
	const vsize_t size = pp->pr_alloc->pa_pagesz;

	uvm_km_kmem_free(kmem_va_arena, (vaddr_t)v, size);
	atomic_add_int(&azram_pool_pages, -(int)(size >> PAGE_SHIFT));
}

/* Pages of the entry and leaf pools: as pool_page_alloc(), but see above. */
static void *
azram_meta_alloc(struct pool *pp, int flags)
{
	vmem_addr_t va;

	if (azram_memlow(1) ||
	    uvm_km_kmem_alloc(kmem_va_arena, PAGE_SIZE,
		VM_NOSLEEP | VM_INSTANTFIT, &va) != 0)
		return NULL;
	return (void *)va;
}

static void
azram_meta_free(struct pool *pp, void *v)
{

	uvm_km_kmem_free(kmem_va_arena, (vaddr_t)v, PAGE_SIZE);
}

static struct pool_allocator azram_meta_palloc = {
	.pa_alloc = azram_meta_alloc,
	.pa_free = azram_meta_free,
	.pa_pagesz = 0,		/* PAGE_SIZE */
};

/*
 * The chunk size for a size class: the smallest that leaves at most
 * 1/32 of it unused, or else the one that leaves the least.
 */
static u_int
azram_chunk_for(u_int size)
{
	u_int j, best;

	best = 0;
	for (j = 0; j < AZRAM_NCHUNK; j++) {
		const uint64_t csize = (uint64_t)PAGE_SIZE << (j + 1);
		const uint64_t bsize = (uint64_t)PAGE_SIZE << (best + 1);

		if ((csize % size) * 32 <= csize)
			return j;
		if ((csize % size) * bsize < (bsize % size) * csize)
			best = j;
	}
	return best;
}

static inline u_int
azram_bucket(int size)
{
	const u_int b = (u_int)(size - 1) / azram_step;

	return MIN(b, AZRAM_NBUCKET - 1);
}

/*
 * Whether all the bytes of the page are the same, and which.
 */
static bool
azram_onevalue(const void *page, uint8_t *bytep)
{
	const u_long *p = page;
	const u_long v = p[0];
	size_t i;

	if (v != (v & 0xff) * (~0UL / 0xff))
		return false;
	for (i = 1; i < PAGE_SIZE / sizeof(*p); i++) {
		if (p[i] != v)
			return false;
	}
	*bytep = (uint8_t)v;
	return true;
}

/*
 * Index.
 */

static uintptr_t
azram_word(u_int l, u_int i)
{

	KASSERT(mutex_owned(azram_lock(l)));
	if (l >= azram_ndir || azram_dir[l].ad_leaf == NULL)
		return 0;
	return azram_dir[l].ad_leaf->al_w[i];
}

static void
azram_drop(uintptr_t w)
{
	struct azram_entry *e;

	KASSERT(w != 0);
	if (w & AZRAM_W_SAME) {
		atomic_dec_uint(&azram_nsame);
		return;
	}
	e = (struct azram_entry *)w;
	atomic_add_long(&azram_data_bytes, -(long)e->ae_size);
	atomic_add_long(&azram_class_bytes,
	    -(long)((e->ae_class + 1) * azram_step));
	atomic_dec_uint(&azram_nentries);
	pool_put(&azram_pools[e->ae_class], e->ae_data);
	pool_put(&azram_entry_pool, e);
}

/*
 * Record w under slot.  Fails only if there is no memory for a leaf.
 */
static bool
azram_insert(int slot, uintptr_t w)
{
	const u_int l = (u_int)slot >> AZRAM_LEAFSHIFT;
	const u_int i = (u_int)slot & AZRAM_LEAFMASK;
	kmutex_t * const lock = azram_lock(l);
	struct azram_leaf *leaf = NULL;
	struct azram_dir *d;
	uintptr_t old;

	mutex_enter(lock);
	if (__predict_false(l >= azram_ndir)) {
		/* Not a slot of a swap device azram_swapon() saw. */
		mutex_exit(lock);
		return false;
	}
	if (azram_dir[l].ad_leaf == NULL) {
		mutex_exit(lock);
		if ((leaf = pool_get(&azram_leaf_pool, PR_NOWAIT)) == NULL)
			return false;
		memset(leaf, 0, sizeof(*leaf));
		mutex_enter(lock);
	}
	d = &azram_dir[l];
	if (d->ad_leaf == NULL) {
		d->ad_leaf = leaf;
		leaf = NULL;
	}
	old = d->ad_leaf->al_w[i];
	d->ad_leaf->al_w[i] = w;
	if (old == 0)
		d->ad_count++;
	mutex_exit(lock);

	if (leaf != NULL)
		pool_put(&azram_leaf_pool, leaf);
	if (__predict_false(old != 0)) {
		/* UVM frees a slot before it uses it again. */
		KASSERTMSG(old == 0, "azram: slot %d stored twice", slot);
		azram_drop(old);
	}
	return true;
}

/*
 * Store one page.  Return whether azram keeps it; with keep false, only
 * look at it for the counters.
 */
static bool
azram_store1(int slot, struct vm_page *pg, bool keep)
{
	struct azram_counters *c;
	struct azram_cpu *ac;
	struct azram_entry *e;
	uint64_t t0, t1;
	vaddr_t kva;
	void *data;
	int size, fail;
	u_int class;
	uint8_t b;

	kva = uvm_pagermapin(&pg, 1,
	    UVMPAGER_MAPIN_WRITE | UVMPAGER_MAPIN_WAITOK);
	if (azram_onevalue((const void *)kva, &b)) {
		uvm_pagermapout(kva, 1);
		AZRAM_COUNT(c_seen_same, 1);
		if (!keep)
			return false;
		if (!azram_insert(slot, AZRAM_W_MKSAME(b))) {
			AZRAM_COUNT(c_rej_nomem, 1);
			return false;
		}
		atomic_inc_uint(&azram_nsame);
		AZRAM_COUNT(c_stored_same, 1);
		return true;
	}

	ac = azram_mycpu();
	data = NULL;
	class = 0;
	fail = -1;
	mutex_enter(&ac->ac_lock);
	t0 = azram_nsec();
	size = lz4_kern_compress(ac->ac_state, (const void *)kva, PAGE_SIZE,
	    ac->ac_buf, (int)azram_bufsize);
	t1 = azram_nsec();
	KASSERT(size > 0);
	if (keep && size > atomic_load_relaxed(&azram_reject_size)) {
		fail = 0;
	} else if (keep) {
		class = (u_int)(size - 1) / azram_step;
		azram_chunk_fail = AZRAM_FAIL_NOMEM;
		data = pool_get(&azram_pools[class], PR_NOWAIT);
		if (data != NULL)
			memcpy(data, ac->ac_buf, size);
		else
			fail = azram_chunk_fail == AZRAM_FAIL_BUDGET ? 1 : 2;
	}
	mutex_exit(&ac->ac_lock);
	uvm_pagermapout(kva, 1);

	c = azram_counters_enter();
	c->c_compress_ns += t1 - t0;
	c->c_hist[azram_bucket(size)]++;
	if (fail == 0)
		c->c_rej_size++;
	else if (fail == 1)
		c->c_rej_budget++;
	else if (fail == 2)
		c->c_rej_nomem++;
	azram_counters_exit();
	if (data == NULL)
		return false;

	if ((e = pool_get(&azram_entry_pool, PR_NOWAIT)) == NULL)
		goto nomem;
	e->ae_data = data;
	e->ae_size = (uint16_t)size;
	e->ae_class = (uint8_t)class;
	e->ae_flags = 0;
	e->ae_atime = (uint32_t)time_uptime;
	if (!azram_insert(slot, (uintptr_t)e)) {
		pool_put(&azram_entry_pool, e);
		goto nomem;
	}
	atomic_inc_uint(&azram_nentries);
	atomic_add_long(&azram_data_bytes, size);
	atomic_add_long(&azram_class_bytes, (class + 1) * azram_step);
	AZRAM_COUNT(c_stored, 1);
	return true;

nomem:
	pool_put(&azram_pools[class], data);
	AZRAM_COUNT(c_rej_nomem, 1);
	return false;
}

/*
 * The external interface, for uvm_swap.c.
 */

bool
azram_active(void)
{

	return azram_ready && (atomic_load_relaxed(&azram_enable) != 0 ||
	    atomic_load_relaxed(&azram_measure) != 0);
}

/*
 * azram_store: offer the pages pgs[0..npages), going to the swap slots
 * from slot on.  stored[i] says whether azram keeps page i; the caller
 * writes the others to the device.  The pages are busy; nothing is
 * locked.
 */
void
azram_store(int slot, struct vm_page **pgs, int npages, bool *stored)
{
	const bool keep = atomic_load_relaxed(&azram_enable) != 0;
	int i;

	for (i = 0; i < npages; i++) {
		AZRAM_COUNT(c_tried, 1);
		stored[i] = azram_store1(slot + i, pgs[i], keep);
	}
}

/*
 * azram_load: fill the busy page pg with the page stored under slot, if
 * any.  Return whether there was one.
 */
bool
azram_load(int slot, struct vm_page *pg)
{
	const u_int l = (u_int)slot >> AZRAM_LEAFSHIFT;
	const u_int i = (u_int)slot & AZRAM_LEAFMASK;
	kmutex_t * const lock = azram_lock(l);
	struct azram_counters *c;
	struct azram_entry *e;
	uint64_t t0, t1;
	uintptr_t w;
	vaddr_t kva;
	int n;

	if (!azram_ready || azram_empty())
		return false;

	kva = uvm_pagermapin(&pg, 1,
	    UVMPAGER_MAPIN_READ | UVMPAGER_MAPIN_WAITOK);
	mutex_enter(lock);
	if ((w = azram_word(l, i)) == 0) {
		mutex_exit(lock);
		uvm_pagermapout(kva, 1);
		return false;
	}
	t0 = azram_nsec();
	if (w & AZRAM_W_SAME) {
		memset((void *)kva, AZRAM_W_BYTE(w), PAGE_SIZE);
	} else {
		e = (struct azram_entry *)w;
		n = lz4_kern_decompress(e->ae_data, e->ae_size, (void *)kva,
		    PAGE_SIZE);
		if (n != PAGE_SIZE)
			panic("azram: slot %d: %d bytes decompressed from %u",
			    slot, n, e->ae_size);
		e->ae_atime = (uint32_t)time_uptime;
	}
	t1 = azram_nsec();
	mutex_exit(lock);
	uvm_pagermapout(kva, 1);

	c = azram_counters_enter();
	c->c_loads++;
	if (w & AZRAM_W_SAME)
		c->c_loads_same++;
	c->c_decompress_ns += t1 - t0;
	azram_counters_exit();
	return true;
}

/*
 * azram_free: drop the entries of the slots startslot..startslot+nslots-1,
 * which are being freed.  Return how many there were.
 */
int
azram_free(int startslot, int nslots)
{
	uintptr_t drop[AZRAM_FREEBATCH];
	struct azram_leaf *leaf;
	struct azram_dir *d;
	kmutex_t *lock;
	u_int slot, end, l, n, j;
	int total;

	if (!azram_ready || azram_empty())
		return 0;

	total = 0;
	slot = (u_int)startslot;
	end = slot + (u_int)nslots;
	while (slot < end) {
		l = slot >> AZRAM_LEAFSHIFT;
		lock = azram_lock(l);
		mutex_enter(lock);
		if (l >= azram_ndir) {
			mutex_exit(lock);
			break;
		}
		if (azram_dir[l].ad_leaf == NULL) {
			mutex_exit(lock);
			slot = (l + 1) << AZRAM_LEAFSHIFT;
			continue;
		}
		d = &azram_dir[l];
		for (n = 0; slot < end && (slot >> AZRAM_LEAFSHIFT) == l &&
		    n < AZRAM_FREEBATCH; slot++) {
			uintptr_t * const wp = &d->ad_leaf->al_w[slot &
			    AZRAM_LEAFMASK];

			if (*wp != 0) {
				drop[n++] = *wp;
				*wp = 0;
				d->ad_count--;
			}
		}
		leaf = NULL;
		if (d->ad_count == 0) {
			leaf = d->ad_leaf;
			d->ad_leaf = NULL;
		}
		mutex_exit(lock);

		for (j = 0; j < n; j++)
			azram_drop(drop[j]);
		if (leaf != NULL)
			pool_put(&azram_leaf_pool, leaf);
		if (n > 0)
			AZRAM_COUNT(c_frees, n);
		total += n;
	}
	return total;
}

static void
azram_lockall(void)
{
	u_int i;

	for (i = 0; i < AZRAM_NLOCKS; i++)
		mutex_enter(&azram_locks[i].lock);
}

static void
azram_unlockall(void)
{
	u_int i;

	for (i = AZRAM_NLOCKS; i-- > 0;)
		mutex_exit(&azram_locks[i].lock);
}

/*
 * azram_swapon: a swap device is about to go live at drum slots
 * drumoffset..drumoffset+drumsize-1; make the index cover them.
 */
void
azram_swapon(int drumoffset, int drumsize)
{
	struct azram_dir *nd, *od;
	u_int need, on;

	if (!azram_ready)
		return;
	need = howmany((u_int)drumoffset + (u_int)drumsize, AZRAM_LEAFSIZE);
	if (need <= atomic_load_relaxed(&azram_ndir))
		return;
	nd = kmem_zalloc(need * sizeof(*nd), KM_SLEEP);
	mutex_enter(&azram_grow_lock);
	if (need <= azram_ndir) {
		mutex_exit(&azram_grow_lock);
		kmem_free(nd, need * sizeof(*nd));
		return;
	}
	azram_lockall();
	od = azram_dir;
	on = azram_ndir;
	if (on > 0)
		memcpy(nd, od, on * sizeof(*nd));
	azram_dir = nd;
	azram_ndir = need;
	azram_unlockall();
	mutex_exit(&azram_grow_lock);
	if (od != NULL)
		kmem_free(od, on * sizeof(*od));
}

/*
 * azram_swapoff: the swap device at drumoffset..drumoffset+drumsize-1 is
 * going away.  swap_off() has paged everything in and freed the slots,
 * so nothing should be left.
 */
void
azram_swapoff(int drumoffset, int drumsize)
{
	int n;

	if ((n = azram_free(drumoffset, drumsize)) != 0)
		printf("azram: dropped %d entries left on a swap device\n", n);
}

void
azram_count_swapwrite(int npages)
{

	if (azram_ready)
		AZRAM_COUNT(c_swap_writes, npages);
}

uint64_t
azram_swapread_start(void)
{

	return azram_nsec();
}

void
azram_swapread_done(uint64_t t0)
{
	const uint64_t t1 = azram_nsec();
	struct azram_counters *c;

	if (!azram_ready)
		return;
	c = azram_counters_enter();
	c->c_swap_reads++;
	c->c_swap_read_ns += t1 - t0;
	azram_counters_exit();
}

/*
 * Statistics.
 */

static void
azram_sum(void *p, void *arg, struct cpu_info *ci)
{
	struct azram_cpu * const *acp = p;
	const uint64_t *src = (const uint64_t *)&(*acp)->ac_c;
	uint64_t *dst = arg;
	size_t i;

	for (i = 0; i < sizeof(struct azram_counters) / sizeof(*dst); i++)
		dst[i] += src[i];
}

static void
azram_getstats(struct azram_stats *st)
{
	struct azram_counters c;
	const uint64_t *base;
	uint64_t *cp;
	size_t i;

	memset(st, 0, sizeof(*st));
	st->st_flags = (azram_enable ? AZRAM_F_ENABLE : 0) |
	    (azram_measure ? AZRAM_F_MEASURE : 0) |
	    (azram_boot_disabled ? AZRAM_F_BOOTOFF : 0);
	st->st_pagesize = PAGE_SIZE;
	st->st_reject_size = azram_reject_size;
	st->st_class_size = azram_step;
	st->st_pool_max = azram_pool_max;
	st->st_uptime = time_uptime;
	if (!azram_ready)
		return;

	st->st_entries = azram_nentries;
	st->st_same_entries = azram_nsame;
	st->st_data_bytes = azram_data_bytes;
	st->st_class_bytes = azram_class_bytes;
	st->st_pool_bytes = ptoa((uint64_t)azram_pool_pages);
	st->st_meta_bytes =
	    ptoa((uint64_t)azram_entry_pool.pr_npages) +
	    ptoa((uint64_t)azram_leaf_pool.pr_npages) +
	    (uint64_t)azram_ndir * sizeof(struct azram_dir) +
	    (uint64_t)ncpu * (sizeof(struct azram_cpu) +
		lz4_kern_statesize() + azram_bufsize);

	memset(&c, 0, sizeof(c));
	percpu_foreach(azram_percpu, azram_sum, &c);
	cp = (uint64_t *)&c;
	base = (const uint64_t *)&azram_base;
	mutex_enter(&azram_stats_lock);
	for (i = 0; i < sizeof(c) / sizeof(*cp); i++)
		cp[i] -= base[i];
	st->st_reset_time = azram_reset_time;
	mutex_exit(&azram_stats_lock);
	st->st_c = c;
}

static void
azram_resetstats(void)
{
	struct azram_counters c;

	if (!azram_ready)
		return;
	memset(&c, 0, sizeof(c));
	percpu_foreach(azram_percpu, azram_sum, &c);
	mutex_enter(&azram_stats_lock);
	azram_base = c;
	azram_reset_time = time_uptime;
	mutex_exit(&azram_stats_lock);
}

/*
 * Initialization, from uvm_swap_init(), before any swap device exists.
 */

static void
azram_cpu_init(void *p, void *cookie, struct cpu_info *ci)
{
	struct azram_cpu **acp = p;
	struct azram_cpu *ac;

	ac = kmem_zalloc(sizeof(*ac), KM_SLEEP);
	mutex_init(&ac->ac_lock, MUTEX_DEFAULT, IPL_NONE);
	ac->ac_state = kmem_alloc(lz4_kern_statesize(), KM_SLEEP);
	ac->ac_buf = kmem_alloc(azram_bufsize, KM_SLEEP);
	*acp = ac;
}

void
azram_init(void)
{
	u_int i, j, size;

	azram_step = PAGE_SIZE / 64;
	azram_bufsize = LZ4_KERN_BOUND(PAGE_SIZE);
	azram_reject_size = PAGE_SIZE * 3 / 4;
	azram_pool_max = ptoa((uint64_t)physmem) / 4;
	azram_pool_maxpages = (u_int)(azram_pool_max >> PAGE_SHIFT);
	if (AZRAM_BOOT_DISABLED()) {
		azram_boot_disabled = 1;
		aprint_normal("azram: disabled by boot flag\n");
	}

	for (i = 0; i < AZRAM_NLOCKS; i++)
		mutex_init(&azram_locks[i].lock, MUTEX_DEFAULT, IPL_SOFTBIO);
	mutex_init(&azram_grow_lock, MUTEX_DEFAULT, IPL_NONE);
	mutex_init(&azram_stats_lock, MUTEX_DEFAULT, IPL_NONE);

	for (j = 0; j < AZRAM_NCHUNK; j++) {
		azram_pallocs[j].pa_alloc = azram_chunk_alloc;
		azram_pallocs[j].pa_free = azram_chunk_free;
		azram_pallocs[j].pa_pagesz = PAGE_SIZE << (j + 1);
	}
	for (i = 0; i < AZRAM_NCLASS; i++) {
		size = (i + 1) * azram_step;
		j = azram_chunk_for(size);
		snprintf(azram_pool_names[i], sizeof(azram_pool_names[i]),
		    "azram%u", size);
		pool_init(&azram_pools[i], size, 0, 0,
		    PR_NOTOUCH | PR_NOALIGN, azram_pool_names[i],
		    &azram_pallocs[j], IPL_SOFTBIO);
		/* Give an empty chunk back unless one more is free. */
		pool_sethiwat(&azram_pools[i],
		    azram_pallocs[j].pa_pagesz / size);
	}
	pool_init(&azram_entry_pool, sizeof(struct azram_entry), 0, 0, 0,
	    "azramentry", &azram_meta_palloc, IPL_SOFTBIO);
	pool_sethiwat(&azram_entry_pool, PAGE_SIZE / sizeof(struct azram_entry));
	pool_init(&azram_leaf_pool, sizeof(struct azram_leaf), 0, 0, 0,
	    "azramleaf", &azram_meta_palloc, IPL_SOFTBIO);
	pool_sethiwat(&azram_leaf_pool, 4);
	azram_percpu = percpu_create(sizeof(struct azram_cpu *),
	    azram_cpu_init, NULL, NULL);
	azram_ready = true;
}

/*
 * sysctl.
 */

static int
sysctl_azram_bool(SYSCTLFN_ARGS)
{
	struct sysctlnode node = *rnode;
	int * const p = rnode->sysctl_data;
	int val = *p, error;

	node.sysctl_data = &val;
	error = sysctl_lookup(SYSCTLFN_CALL(&node));
	if (error || newp == NULL)
		return error;
	if (val != 0 && val != 1)
		return EINVAL;
	atomic_store_relaxed(p, val);
	return 0;
}

static int
sysctl_azram_reject_size(SYSCTLFN_ARGS)
{
	struct sysctlnode node = *rnode;
	int val = azram_reject_size, error;

	node.sysctl_data = &val;
	error = sysctl_lookup(SYSCTLFN_CALL(&node));
	if (error || newp == NULL)
		return error;
	if (val < (int)azram_step || val > (int)(AZRAM_NCLASS * azram_step))
		return EINVAL;
	atomic_store_relaxed(&azram_reject_size, val);
	return 0;
}

static int
sysctl_azram_pool_max(SYSCTLFN_ARGS)
{
	struct sysctlnode node = *rnode;
	uint64_t val = azram_pool_max;
	int error;

	node.sysctl_data = &val;
	error = sysctl_lookup(SYSCTLFN_CALL(&node));
	if (error || newp == NULL)
		return error;
	if (val > ptoa((uint64_t)physmem))
		return EINVAL;
	azram_pool_max = val;
	atomic_store_relaxed(&azram_pool_maxpages, (u_int)(val >> PAGE_SHIFT));
	return 0;
}

static int
sysctl_azram_stats(SYSCTLFN_ARGS)
{
	struct sysctlnode node = *rnode;
	struct azram_stats st;
	int error;

	azram_getstats(&st);
	node.sysctl_data = &st;
	node.sysctl_size = sizeof(st);
	error = sysctl_lookup(SYSCTLFN_CALL(&node));
	if (error || newp == NULL)
		return error;
	azram_resetstats();
	return 0;
}

SYSCTL_SETUP(sysctl_vm_azram_setup, "sysctl vm.azram setup")
{
	const struct sysctlnode *rnode;

	if (sysctl_createv(clog, 0, NULL, &rnode,
	    CTLFLAG_PERMANENT,
	    CTLTYPE_NODE, "azram",
	    SYSCTL_DESCR("Compressed cache in front of swap"),
	    NULL, 0, NULL, 0,
	    CTL_VM, CTL_CREATE, CTL_EOL) != 0)
		return;

	sysctl_createv(clog, 0, &rnode, NULL,
	    CTLFLAG_PERMANENT | CTLFLAG_READWRITE,
	    CTLTYPE_INT, "enable",
	    SYSCTL_DESCR("Keep pages compressed in memory on their way "
		"to swap"),
	    sysctl_azram_bool, 0, &azram_enable, 0,
	    CTL_CREATE, CTL_EOL);
	sysctl_createv(clog, 0, &rnode, NULL,
	    CTLFLAG_PERMANENT | CTLFLAG_READWRITE,
	    CTLTYPE_INT, "measure",
	    SYSCTL_DESCR("Compress the pages that go to swap only to count "
		"their sizes"),
	    sysctl_azram_bool, 0, &azram_measure, 0,
	    CTL_CREATE, CTL_EOL);
	sysctl_createv(clog, 0, &rnode, NULL,
	    CTLFLAG_PERMANENT | CTLFLAG_READWRITE,
	    CTLTYPE_QUAD, "pool_max",
	    SYSCTL_DESCR("Bytes of memory the compressed pages may take"),
	    sysctl_azram_pool_max, 0, &azram_pool_max, 0,
	    CTL_CREATE, CTL_EOL);
	sysctl_createv(clog, 0, &rnode, NULL,
	    CTLFLAG_PERMANENT | CTLFLAG_READWRITE,
	    CTLTYPE_INT, "reject_size",
	    SYSCTL_DESCR("Largest compressed size of a page kept, in bytes"),
	    sysctl_azram_reject_size, 0, &azram_reject_size, 0,
	    CTL_CREATE, CTL_EOL);
	sysctl_createv(clog, 0, &rnode, NULL,
	    CTLFLAG_PERMANENT,
	    CTLTYPE_INT, "boot_disabled",
	    SYSCTL_DESCR("Whether the boot flag kept azram off for this boot"),
	    NULL, 0, &azram_boot_disabled, 0,
	    CTL_CREATE, CTL_EOL);
	sysctl_createv(clog, 0, &rnode, NULL,
	    CTLFLAG_PERMANENT | CTLFLAG_READWRITE,
	    CTLTYPE_STRUCT, "stats",
	    SYSCTL_DESCR("Statistics, struct azram_stats; writing resets "
		"the counters"),
	    sysctl_azram_stats, 0, NULL, sizeof(struct azram_stats),
	    CTL_CREATE, CTL_EOL);
}
