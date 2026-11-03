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
 * aprefd: collect the access entries of a recording window from
 * /dev/aprefetch, save them as a trace, and rebuild a profile from the
 * last few traces.
 *
 * Without -s the window is the boot window, and the profile the boot
 * profile.  With -s, aprefd opens a window for a login session, closes
 * it once the reads that miss the cache have stopped, and keeps the
 * traces and the profile of that user and session in APREF_SESSDIR.
 *
 * All windows go through the same rings, and read(2) cannot tell one
 * window from the next: opening a window discards what is left of the
 * last one, and a reader of the last one would go on reading the new
 * one.  So each aprefd holds an exclusive flock(2) on the device while
 * it reads, and a session waits for it until the boot aprefd has read
 * the boot window to the end.
 */

#include <sys/cdefs.h>
__RCSID("$NetBSD$");

#include <sys/param.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysctl.h>

#include <ctype.h>
#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

#include "aprefio.h"

#define	MAXKEEP		9		/* traces kept at most */
#define	MAXPAGES	(1024 * 1024)	/* distinct pages in a profile */
#define	MAXBLOCKS	(256 * 1024)	/* distinct metadata blocks */
#define	MAXSESSION	64		/* length of a session name */
#define	LOCKWAIT	10		/* seconds a session waits to read */
#define	POLLMS		100		/* msec between looks at a session */

/* The entries collected so far. */
struct tracebuf {
	struct aprefetch_rec	*tb_recs;
	size_t			 tb_n;
	size_t			 tb_max;
	size_t			 tb_lost;	/* past APREF_TRACEMAX */
};

/* A page seen in the traces. */
struct page {
	uint64_t	pg_fsid;
	uint64_t	pg_ino;
	uint32_t	pg_gen;
	uint32_t	pg_pgno;
	uint32_t	pg_msec;	/* first read, in the newest trace */
	uint8_t		pg_count;	/* traces that have it */
	int8_t		pg_last;	/* last trace that counted it */
	bool		pg_used;
};

/* A metadata block seen in the traces; the rest is as for a page. */
struct mblk {
	uint64_t	mb_fsid;
	uint64_t	mb_ino;
	uint64_t	mb_off;		/* block number */
	uint32_t	mb_gen;
	uint32_t	mb_kind;	/* APREF_KIND_* */
	uint32_t	mb_size;	/* in the newest trace that has it */
	uint32_t	mb_msec;
	uint8_t		mb_count;
	int8_t		mb_last;
	bool		mb_used;
};

struct fscount {
	uint64_t	fs_fsid;
	uint64_t	fs_pages;
};

/* A profile entry to be: a run of pages of one file, or a metadata block. */
struct run {
	uint64_t	r_fsid;
	uint64_t	r_ino;
	uint64_t	r_off;		/* first page, or block number */
	uint32_t	r_gen;
	uint32_t	r_npages;
	uint32_t	r_msec;
	uint32_t	r_kind;
	uint32_t	r_size;
};

static bool		dflag;
static bool		Mflag;		/* no metadata in the profile */
static volatile sig_atomic_t quit;

static struct page	*table;
static size_t		tablemask;
static size_t		npages;
static bool		full;

static struct mblk	*mtable;
static size_t		mtablemask;
static size_t		nblocks;
static bool		mfull;

__dead static void	usage(void);
static void		logmsg(int, const char *, ...) __printflike(2, 3);

static void
logmsg(int pri, const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	if (dflag) {
		(void)vfprintf(stderr, fmt, ap);
		(void)fputc('\n', stderr);
	} else
		vsyslog(pri, fmt, ap);
	va_end(ap);
}

static void
onsignal(int sig)
{

	quit = 1;
}

/* Add n entries; those past APREF_TRACEMAX are only counted. */
static int
addrecs(struct tracebuf *tb, const struct aprefetch_rec *rec, size_t n)
{
	struct aprefetch_rec *nrecs;
	size_t max;

	if (tb->tb_n + n > APREF_TRACEMAX) {
		tb->tb_lost += n;
		return 0;
	}
	if (tb->tb_n + n > tb->tb_max) {
		max = MAX(tb->tb_max, 4096);
		while (max < tb->tb_n + n)
			max *= 2;
		max = MIN(max, APREF_TRACEMAX);
		if ((nrecs = realloc(tb->tb_recs, max * sizeof(*nrecs))) ==
		    NULL) {
			logmsg(LOG_ERR, "out of memory");
			return -1;
		}
		tb->tb_recs = nrecs;
		tb->tb_max = max;
	}
	memcpy(&tb->tb_recs[tb->tb_n], rec, n * sizeof(*rec));
	tb->tb_n += n;
	return 0;
}

/*
 * Take the lock of the readers of the device, waiting for ever, or at
 * most wait seconds.
 */
static int
lockdev(int fd, unsigned int wait)
{
	const struct timespec nap = { 0, POLLMS * 1000000L };
	unsigned int n;

	if (wait == 0) {
		while (flock(fd, LOCK_EX) == -1) {
			if (errno != EINTR || quit)
				return -1;
		}
		return 0;
	}
	for (n = 0; flock(fd, LOCK_EX | LOCK_NB) == -1; n++) {
		if (errno != EWOULDBLOCK || quit)
			return -1;
		if (n >= wait * (1000 / POLLMS))
			return -1;
		(void)nanosleep(&nap, NULL);
	}
	return 0;
}

/* Read access entries until the window closes and the device says EOF. */
static int
collect(int fd, struct tracebuf *tb)
{
	struct aprefetch_rec buf[256];
	ssize_t len;

	for (;;) {
		if ((len = read(fd, buf, sizeof(buf))) == -1) {
			if (errno == EINTR && !quit)
				continue;
			if (errno != EINTR)
				logmsg(LOG_ERR, "read %s: %s", APREFETCH_DEV,
				    strerror(errno));
			return -1;
		}
		if (len == 0)
			return 0;
		if (addrecs(tb, buf, (size_t)len / sizeof(buf[0])) == -1)
			return -1;
	}
}

/*
 * Collect the entries of a session window, which the caller has opened
 * and fd reads without waiting.  Close the window once no read has
 * missed the cache for idle msec, or after limit msec, and read the
 * rest up to EOF.  The entries still being merged are flushed before
 * the window is closed, in case they hold a miss.  A window closed by
 * the kernel, on kern.aprefetch.record_timeout, ends in the same way.
 */
static int
collect_session(int fd, struct tracebuf *tb, uint64_t idle, uint64_t limit)
{
	const struct timespec nap = { 0, POLLMS * 1000000L };
	struct aprefetch_rec buf[256];
	struct aprefetch_status as;
	uint64_t now = 0, lastmiss = 0;
	bool flushed = false, stopped = false;
	ssize_t len;
	size_t i, n;

	for (;;) {
		if ((len = read(fd, buf, sizeof(buf))) > 0) {
			n = (size_t)len / sizeof(buf[0]);
			for (i = 0; i < n; i++) {
				if ((buf[i].ar_flags & APREF_REC_MISS) != 0)
					lastmiss = MAX(lastmiss,
					    buf[i].ar_msec);
			}
			if (addrecs(tb, buf, n) == -1)
				goto fail;
			continue;
		}
		if (len == 0)
			break;
		if (errno != EAGAIN && errno != EINTR) {
			logmsg(LOG_ERR, "read %s: %s", APREFETCH_DEV,
			    strerror(errno));
			goto fail;
		}
		if (quit)
			goto fail;
		if (!stopped) {
			if (ioctl(fd, APREFIOC_STATUS, &as) == -1) {
				logmsg(LOG_ERR, "APREFIOC_STATUS: %s",
				    strerror(errno));
				goto fail;
			}
			if (as.as_window == APREF_WIN_CLOSED)
				continue;	/* read the rest */
			now = as.as_window_msec;
			if (now < limit && now - MIN(now, lastmiss) < idle)
				flushed = false;
			else if (!flushed) {
				(void)ioctl(fd, APREFIOC_FLUSH);
				flushed = true;
				continue;
			} else {
				if (ioctl(fd, APREFIOC_RECSTOP) == -1) {
					logmsg(LOG_ERR, "APREFIOC_RECSTOP: %s",
					    strerror(errno));
					goto fail;
				}
				stopped = true;
				continue;
			}
		}
		(void)nanosleep(&nap, NULL);
	}
	if (stopped)
		logmsg(LOG_INFO, "closed the window at %.1f s, the last miss "
		    "was at %.1f s", now / 1000.0, lastmiss / 1000.0);
	else
		logmsg(LOG_INFO, "the window closed before the session "
		    "settled");
	return 0;
fail:
	if (!stopped)
		(void)ioctl(fd, APREFIOC_RECSTOP);
	return -1;
}

/* The name of trace i: base itself for the newest, then base.1 and so on. */
static int
tracename(char *buf, size_t len, const char *base, int i)
{
	int n;

	if (i == 0)
		n = snprintf(buf, len, "%s", base);
	else
		n = snprintf(buf, len, "%s.%d", base, i);
	if (n < 0 || (size_t)n >= len) {
		errno = ENAMETOOLONG;
		return -1;
	}
	return 0;
}

/* Make room for a new trace: base becomes base.1, and so on. */
static void
rotate(const char *base, int keep)
{
	char from[PATH_MAX], to[PATH_MAX];
	int i;

	for (i = MAXKEEP; i >= keep; i--) {
		if (tracename(from, sizeof(from), base, i) == 0)
			(void)unlink(from);
	}
	for (i = keep - 1; i >= 1; i--) {
		if (tracename(from, sizeof(from), base, i - 1) == -1 ||
		    tracename(to, sizeof(to), base, i) == -1)
			continue;
		if (rename(from, to) == -1 && errno != ENOENT)
			logmsg(LOG_WARNING, "rename %s: %s", from,
			    strerror(errno));
	}
}

/* Save the entries collected as the newest trace. */
static int
savetrace(const char *base, int keep, const struct tracebuf *tb,
    uint64_t ndropped)
{

	if (tb->tb_lost > 0)
		logmsg(LOG_WARNING, "dropped %zu entries past %d", tb->tb_lost,
		    APREF_TRACEMAX);
	rotate(base, keep);
	if (aprefio_save_trace(base, tb->tb_recs, (uint32_t)tb->tb_n,
	    ndropped) == -1) {
		logmsg(LOG_ERR, "%s: %s", base, strerror(errno));
		return -1;
	}
	logmsg(LOG_INFO, "%s: %zu entries", base, tb->tb_n);
	return 0;
}

static size_t
pagehash(uint64_t fsid, uint64_t ino, uint32_t gen, uint32_t pgno)
{
	uint64_t x;

	x = (ino ^ ((uint64_t)gen << 32) ^ (fsid * 0x9e3779b97f4a7c15ULL)) *
	    0xff51afd7ed558ccdULL;
	x ^= (uint64_t)pgno * 0xc4ceb9fe1a85ec53ULL;
	x ^= x >> 33;
	return (size_t)x & tablemask;
}

/* Count a page read in trace t at msec. */
static void
addpage(int t, uint64_t fsid, uint64_t ino, uint32_t gen, uint32_t pgno,
    uint32_t msec)
{
	struct page *pg;
	size_t h;

	for (h = pagehash(fsid, ino, gen, pgno);; h = (h + 1) & tablemask) {
		pg = &table[h];
		if (!pg->pg_used)
			break;
		if (pg->pg_fsid == fsid && pg->pg_ino == ino &&
		    pg->pg_gen == gen && pg->pg_pgno == pgno) {
			if (pg->pg_last != t) {
				pg->pg_last = (int8_t)t;
				pg->pg_count++;
			} else if (pg->pg_count == 1 && msec < pg->pg_msec) {
				/* Still in the newest trace that has it. */
				pg->pg_msec = msec;
			}
			return;
		}
	}
	if (npages >= MAXPAGES) {
		full = true;
		return;
	}
	pg->pg_used = true;
	pg->pg_fsid = fsid;
	pg->pg_ino = ino;
	pg->pg_gen = gen;
	pg->pg_pgno = pgno;
	pg->pg_msec = msec;
	pg->pg_count = 1;
	pg->pg_last = (int8_t)t;
	npages++;
}

static size_t
blockhash(uint32_t kind, uint64_t fsid, uint64_t ino, uint32_t gen,
    uint64_t off)
{
	uint64_t x;

	x = (ino ^ ((uint64_t)gen << 32) ^ (fsid * 0x9e3779b97f4a7c15ULL) ^
	    kind) * 0xff51afd7ed558ccdULL;
	x ^= off * 0xc4ceb9fe1a85ec53ULL;
	x ^= x >> 33;
	return (size_t)x & mtablemask;
}

/* Count a metadata block read in trace t, as addpage() does. */
static void
addblock(int t, const struct aprefetch_rec *r)
{
	const uint32_t kind = APREF_REC_KIND(r->ar_flags);
	struct mblk *mb;
	size_t h;

	for (h = blockhash(kind, r->ar_fsid, r->ar_ino, r->ar_gen, r->ar_off);;
	    h = (h + 1) & mtablemask) {
		mb = &mtable[h];
		if (!mb->mb_used)
			break;
		if (mb->mb_kind == kind && mb->mb_fsid == r->ar_fsid &&
		    mb->mb_ino == r->ar_ino && mb->mb_gen == r->ar_gen &&
		    mb->mb_off == r->ar_off) {
			if (mb->mb_last != t) {
				mb->mb_last = (int8_t)t;
				mb->mb_count++;
			} else if (mb->mb_count == 1 &&
			    r->ar_msec < mb->mb_msec) {
				mb->mb_msec = r->ar_msec;
			}
			return;
		}
	}
	if (nblocks >= MAXBLOCKS) {
		mfull = true;
		return;
	}
	mb->mb_used = true;
	mb->mb_fsid = r->ar_fsid;
	mb->mb_ino = r->ar_ino;
	mb->mb_off = r->ar_off;
	mb->mb_gen = r->ar_gen;
	mb->mb_kind = kind;
	mb->mb_size = r->ar_size;
	mb->mb_msec = r->ar_msec;
	mb->mb_count = 1;
	mb->mb_last = (int8_t)t;
	nblocks++;
}

static int
page_cmp(const void *a, const void *b)
{
	const struct page *p = a, *q = b;

	if (p->pg_fsid != q->pg_fsid)
		return p->pg_fsid < q->pg_fsid ? -1 : 1;
	if (p->pg_ino != q->pg_ino)
		return p->pg_ino < q->pg_ino ? -1 : 1;
	if (p->pg_gen != q->pg_gen)
		return p->pg_gen < q->pg_gen ? -1 : 1;
	if (p->pg_pgno != q->pg_pgno)
		return p->pg_pgno < q->pg_pgno ? -1 : 1;
	return 0;
}

static int
run_cmp(const void *a, const void *b)
{
	const struct run *r = a, *s = b;

	if (r->r_msec != s->r_msec)
		return r->r_msec < s->r_msec ? -1 : 1;
	if (r->r_kind != s->r_kind)
		return r->r_kind < s->r_kind ? -1 : 1;
	if (r->r_fsid != s->r_fsid)
		return r->r_fsid < s->r_fsid ? -1 : 1;
	if (r->r_ino != s->r_ino)
		return r->r_ino < s->r_ino ? -1 : 1;
	return r->r_off < s->r_off ? -1 : r->r_off > s->r_off;
}

static int
fs_cmp(const void *a, const void *b)
{
	const struct fscount *f = a, *g = b;

	return f->fs_pages > g->fs_pages ? -1 : f->fs_pages < g->fs_pages;
}

/* A hash table with room for twice want slots, a power of two. */
static void *
newtable(size_t want, size_t size, size_t *maskp)
{
	size_t n;
	void *p;

	for (n = 1024; n < 2 * want; n <<= 1)
		continue;
	if ((p = calloc(n, size)) == NULL)
		return NULL;
	*maskp = n - 1;
	return p;
}

/*
 * Rebuild the profile prof from the newest keep traces named after base:
 * keep the pages and metadata blocks read in at least min of them, in
 * the order in which the newest trace that has them read them first.
 */
static int
buildprof(const char *base, const char *prof, int keep, int min)
{
	struct aprefio_trace tr;
	struct aprefetch_prof_ent *pe;
	struct page *pg;
	struct mblk *mb;
	struct run *runs, *r;
	struct fscount fsc[64];
	char path[PATH_MAX];
	uint64_t fsid[APREF_PROF_MAXFS];
	uint64_t total = 0, mtotal = 0;
	size_t i, j, n, nmeta, nruns, nent, maxent, nfsc = 0, nmetaent = 0;
	uint32_t k, p;
	int t, ntraces = 0, need, nfs = 0, error;
	const long pgsz = sysconf(_SC_PAGESIZE);
	int pgshift;

	for (pgshift = 0; (1L << pgshift) < pgsz; pgshift++)
		continue;

	/* Size the tables for the newest trace, with room for the others. */
	for (t = 0; t < keep; t++) {
		if (tracename(path, sizeof(path), base, t) == -1 ||
		    aprefio_load_trace(path, &tr) == -1)
			continue;
		for (k = 0; k < tr.t_hdr.th_nrecs; k++) {
			if (APREF_REC_KIND(tr.t_recs[k].ar_flags) ==
			    APREF_KIND_DATA)
				total += tr.t_recs[k].ar_npages;
			else
				mtotal++;
		}
		aprefio_free_trace(&tr);
	}
	table = newtable(MIN(total, MAXPAGES), sizeof(*table), &tablemask);
	mtable = newtable(MIN(mtotal, MAXBLOCKS), sizeof(*mtable),
	    &mtablemask);
	if (table == NULL || mtable == NULL) {
		logmsg(LOG_ERR, "out of memory");
		free(table);
		free(mtable);
		return -1;
	}

	for (t = 0; t < keep; t++) {
		if (tracename(path, sizeof(path), base, t) == -1 ||
		    aprefio_load_trace(path, &tr) == -1) {
			if (errno != ENOENT)
				logmsg(LOG_WARNING, "%s: %s", path,
				    strerror(errno));
			continue;
		}
		ntraces++;
		for (k = 0; k < tr.t_hdr.th_nrecs; k++) {
			const struct aprefetch_rec * const rec = &tr.t_recs[k];
			uint64_t first;

			if (APREF_REC_KIND(rec->ar_flags) != APREF_KIND_DATA) {
				if (!Mflag && rec->ar_size != 0 &&
				    rec->ar_size <= MAXBSIZE)
					addblock(t, rec);
				continue;
			}
			first = rec->ar_off >> pgshift;
			if (first + rec->ar_npages > UINT32_MAX)
				continue;
			for (p = 0; p < rec->ar_npages; p++)
				addpage(t, rec->ar_fsid, rec->ar_ino,
				    rec->ar_gen, (uint32_t)(first + p),
				    rec->ar_msec);
		}
		aprefio_free_trace(&tr);
	}
	if (full)
		logmsg(LOG_WARNING, "more than %d distinct pages; ignored "
		    "the rest", MAXPAGES);
	if (mfull)
		logmsg(LOG_WARNING, "more than %d distinct metadata blocks; "
		    "ignored the rest", MAXBLOCKS);
	need = MIN(min, ntraces);

	/* The pages and blocks read often enough. */
	for (i = j = 0; i <= tablemask; i++) {
		if (table[i].pg_used && table[i].pg_count >= need)
			table[j++] = table[i];
	}
	n = j;
	qsort(table, n, sizeof(*table), page_cmp);
	for (i = j = 0; i <= mtablemask; i++) {
		if (mtable[i].mb_used && mtable[i].mb_count >= need)
			mtable[j++] = mtable[i];
	}
	nmeta = j;
	if ((runs = calloc(MAX(n + nmeta, 1), sizeof(*runs))) == NULL) {
		logmsg(LOG_ERR, "out of memory");
		free(table);
		free(mtable);
		return -1;
	}

	/* Pages grouped into runs per file, and the blocks as they are. */
	for (i = 0, nruns = 0; i < n; i++) {
		pg = &table[i];
		if (nruns > 0) {
			r = &runs[nruns - 1];
			if (r->r_fsid == pg->pg_fsid && r->r_ino == pg->pg_ino &&
			    r->r_gen == pg->pg_gen &&
			    r->r_off + r->r_npages == pg->pg_pgno) {
				r->r_npages++;
				r->r_msec = MIN(r->r_msec, pg->pg_msec);
				continue;
			}
		}
		r = &runs[nruns++];
		r->r_fsid = pg->pg_fsid;
		r->r_ino = pg->pg_ino;
		r->r_gen = pg->pg_gen;
		r->r_off = pg->pg_pgno;
		r->r_npages = 1;
		r->r_msec = pg->pg_msec;
		r->r_kind = APREF_KIND_DATA;
		r->r_size = 0;
	}
	for (i = 0; i < nmeta; i++) {
		mb = &mtable[i];
		r = &runs[nruns++];
		r->r_fsid = mb->mb_fsid;
		r->r_ino = mb->mb_ino;
		r->r_gen = mb->mb_gen;
		r->r_off = mb->mb_off;
		r->r_npages = (uint32_t)howmany(mb->mb_size, (uint32_t)pgsz);
		r->r_msec = mb->mb_msec;
		r->r_kind = mb->mb_kind;
		r->r_size = mb->mb_size;
	}
	free(table);
	table = NULL;
	free(mtable);
	mtable = NULL;
	qsort(runs, nruns, sizeof(*runs), run_cmp);

	/* At most APREF_PROF_MAXFS file systems, those with the most pages. */
	for (i = 0; i < nruns; i++) {
		for (j = 0; j < nfsc; j++)
			if (fsc[j].fs_fsid == runs[i].r_fsid)
				break;
		if (j == nfsc) {
			if (nfsc == __arraycount(fsc))
				continue;
			fsc[nfsc].fs_fsid = runs[i].r_fsid;
			fsc[nfsc].fs_pages = 0;
			nfsc++;
		}
		fsc[j].fs_pages += runs[i].r_npages;
	}
	qsort(fsc, nfsc, sizeof(fsc[0]), fs_cmp);
	nfs = (int)MIN(nfsc, APREF_PROF_MAXFS);
	for (j = 0; j < (size_t)nfs; j++)
		fsid[j] = fsc[j].fs_fsid;

	maxent = (APREF_PROF_MAXSIZE - sizeof(struct aprefetch_prof_hdr)) /
	    sizeof(*pe);
	if ((pe = calloc(MAX(MIN(nruns, maxent), 1), sizeof(*pe))) == NULL) {
		logmsg(LOG_ERR, "out of memory");
		free(runs);
		return -1;
	}
	for (i = nent = 0; i < nruns && nent < maxent; i++) {
		r = &runs[i];
		for (j = 0; j < (size_t)nfs; j++)
			if (fsid[j] == r->r_fsid)
				break;
		if (j == (size_t)nfs)
			continue;
		pe[nent].pe_fsid = r->r_fsid;
		pe[nent].pe_ino = r->r_ino;
		pe[nent].pe_gen = r->r_gen;
		pe[nent].pe_off = r->r_kind == APREF_KIND_DATA ?
		    r->r_off << pgshift : r->r_off;
		pe[nent].pe_npages = r->r_npages;
		pe[nent].pe_kind = r->r_kind;
		pe[nent].pe_size = r->r_size;
		if (r->r_kind != APREF_KIND_DATA)
			nmetaent++;
		nent++;
	}
	free(runs);

	error = aprefio_save_prof(prof, pe, (uint32_t)nent, fsid,
	    (uint32_t)nfs);
	if (error == -1)
		logmsg(LOG_ERR, "%s: %s", prof, strerror(errno));
	else
		logmsg(LOG_INFO, "%s: %zu entries, %zu of metadata, from %d "
		    "traces", prof, nent, nmetaent, ntraces);
	free(pe);
	return error;
}

static uint64_t
dropped(void)
{
	struct aprefetch_stats st;
	size_t len = sizeof(st);

	if (sysctlbyname("kern.aprefetch.stats", &st, &len, NULL, 0) == -1)
		return 0;
	return st.st_dropped;
}

/* A session name becomes part of file names: keep it plain. */
static bool
sessionok(const char *s)
{
	size_t i;

	if (s[0] == '\0' || s[0] == '.' || strlen(s) > MAXSESSION)
		return false;
	for (i = 0; s[i] != '\0'; i++) {
		if (!isalnum((unsigned char)s[i]) &&
		    strchr("+-._", s[i]) == NULL)
			return false;
	}
	return true;
}

/* Make the directory of the sessions, which only root may look into. */
static int
sessiondir(void)
{
	struct stat st;

	if (mkdir(APREF_SESSDIR, 0700) == -1 && errno != EEXIST)
		return -1;
	if (lstat(APREF_SESSDIR, &st) == -1)
		return -1;
	if (!S_ISDIR(st.st_mode)) {
		errno = ENOTDIR;
		return -1;
	}
	if (st.st_uid != 0) {
		errno = EPERM;
		return -1;
	}
	if ((st.st_mode & ALLPERMS) != 0700 && chmod(APREF_SESSDIR, 0700) == -1)
		return -1;
	return 0;
}

/*
 * Open a window for a session, once nobody else is reading the device,
 * and collect it.
 */
static int
record_session(int fd, struct tracebuf *tb, uint64_t idle, uint64_t limit,
    uint64_t *ndroppedp)
{
	uint64_t before;

	if (lockdev(fd, LOCKWAIT) == -1) {
		if (!quit)
			logmsg(LOG_WARNING, "%s is still being read; not "
			    "recording", APREFETCH_DEV);
		return -1;
	}
	before = dropped();
	if (ioctl(fd, APREFIOC_RECSTART) == -1) {
		logmsg(LOG_WARNING, "cannot open a window: %s",
		    strerror(errno));
		return -1;
	}
	if (collect_session(fd, tb, idle, limit) == -1)
		return -1;
	*ndroppedp = dropped() - before;
	return 0;
}

__dead static void
usage(void)
{

	(void)fprintf(stderr,
	    "usage: %s [-dMn] [-k keep] [-m min]\n"
	    "       %s -s [-dMn] [-i idle] [-k keep] [-m min] [-t limit] "
	    "uid session\n", getprogname(), getprogname());
	exit(1);
}

int
main(int argc, char **argv)
{
	struct sigaction sa;
	struct tracebuf tb;
	char base[PATH_MAX], prof[PATH_MAX];
	uint64_t ndropped = 0;
	unsigned int idle = 0, limit = 0;
	bool nflag = false, sflag = false;
	int ch, fd, keep = 3, min = 2, e, error, n1, n2;
	uid_t uid;

	while ((ch = getopt(argc, argv, "di:k:Mm:nst:")) != -1) {
		switch (ch) {
		case 'd':
			dflag = true;
			break;
		case 'i':
			idle = (unsigned int)strtoi(optarg, NULL, 10, 1, 3600,
			    &e);
			if (e)
				errx(1, "-i: seconds from 1 to 3600");
			break;
		case 'k':
			keep = (int)strtoi(optarg, NULL, 10, 1, MAXKEEP, &e);
			if (e)
				errx(1, "-k: number of traces from 1 to %d",
				    MAXKEEP);
			break;
		case 'm':
			min = (int)strtoi(optarg, NULL, 10, 1, MAXKEEP, &e);
			if (e)
				errx(1, "-m: number of traces from 1 to %d",
				    MAXKEEP);
			break;
		case 'M':
			Mflag = true;
			break;
		case 'n':
			nflag = true;
			break;
		case 's':
			sflag = true;
			break;
		case 't':
			limit = (unsigned int)strtoi(optarg, NULL, 10, 1, 3600,
			    &e);
			if (e)
				errx(1, "-t: seconds from 1 to 3600");
			break;
		default:
			usage();
		}
	}
	argc -= optind;
	argv += optind;
	if (min > keep)
		errx(1, "-m %d is more than -k %d", min, keep);

	if (sflag) {
		if (argc != 2)
			usage();
		uid = (uid_t)strtoi(argv[0], NULL, 10, 0, UID_MAX, &e);
		if (e)
			errx(1, "%s: not a user id", argv[0]);
		if (!sessionok(argv[1]))
			errx(1, "%s: not a session name", argv[1]);
		n1 = snprintf(base, sizeof(base), "%s/%u-%s.trace",
		    APREF_SESSDIR, (unsigned int)uid, argv[1]);
		n2 = snprintf(prof, sizeof(prof), "%s/%u-%s.prof",
		    APREF_SESSDIR, (unsigned int)uid, argv[1]);
		if (n1 < 0 || (size_t)n1 >= sizeof(base) || n2 < 0 ||
		    (size_t)n2 >= sizeof(prof))
			errx(1, "%s: name too long", argv[1]);
		if (idle == 0)
			idle = 3;
		if (limit == 0)
			limit = 30;
	} else {
		if (argc != 0 || idle != 0 || limit != 0)
			usage();
		(void)strlcpy(base, APREF_TRACEFILE, sizeof(base));
		(void)strlcpy(prof, APREFETCH_BOOTPROF, sizeof(prof));
	}

	/* A session is read as it comes, to see when it has settled. */
	if ((fd = open(APREFETCH_DEV, O_RDONLY | (sflag ? O_NONBLOCK : 0))) ==
	    -1)
		err(1, "%s", APREFETCH_DEV);
	if (sflag && sessiondir() == -1)
		err(1, "%s", APREF_SESSDIR);
	if (!dflag) {
		openlog(getprogname(), LOG_PID, LOG_DAEMON);
		if (daemon(0, 0) == -1)
			err(1, "daemon");
		if (!sflag)
			(void)pidfile(NULL);
	}

	/* No SA_RESTART: a signal ends a read(2) that waits for entries. */
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = onsignal;
	(void)sigemptyset(&sa.sa_mask);
	(void)sigaction(SIGTERM, &sa, NULL);
	(void)sigaction(SIGINT, &sa, NULL);
	(void)sigaction(SIGHUP, &sa, NULL);

	memset(&tb, 0, sizeof(tb));
	if (sflag)
		error = record_session(fd, &tb, idle * 1000ULL,
		    limit * 1000ULL, &ndropped);
	else if ((error = lockdev(fd, 0)) == 0) {
		error = collect(fd, &tb);
		ndropped = dropped();
	}
	/* Let the next reader in. */
	(void)close(fd);
	if (error == -1) {
		free(tb.tb_recs);
		return quit ? 0 : 1;
	}
	if (tb.tb_n == 0) {
		logmsg(LOG_INFO, "nothing was recorded");
		return 0;
	}

	error = savetrace(base, keep, &tb, ndropped);
	free(tb.tb_recs);
	if (error == -1)
		return 1;
	if (!nflag && buildprof(base, prof, keep, min) == -1)
		return 1;
	return 0;
}
