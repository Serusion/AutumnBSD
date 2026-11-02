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

/* azramctl: control azram(4) and show what it holds. */

#include <sys/cdefs.h>
__RCSID("$NetBSD$");

#include <sys/param.h>
#include <sys/azram.h>
#include <sys/sysctl.h>

#include <err.h>
#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <util.h>

#define	MB(bytes)	((double)(bytes) / (1024 * 1024))
#define	BARW		40

struct cmd {
	const char	*c_name;
	int		(*c_func)(int, char **);
	const char	*c_args;
};

static int	cmd_status(int, char **);
static int	cmd_hist(int, char **);
static int	cmd_enable(int, char **);
static int	cmd_disable(int, char **);
static int	cmd_measure(int, char **);
static int	cmd_set(int, char **);
static int	cmd_reset(int, char **);

static const struct cmd cmds[] = {
	{ "status",	cmd_status,	"" },
	{ "hist",	cmd_hist,	"" },
	{ "enable",	cmd_enable,	"" },
	{ "disable",	cmd_disable,	"" },
	{ "measure",	cmd_measure,	"on | off" },
	{ "set",	cmd_set,	"pool_max size[%] | reject_size bytes" },
	{ "reset",	cmd_reset,	"" },
};

__dead static void
usage(void)
{
	size_t i;

	for (i = 0; i < __arraycount(cmds); i++)
		(void)fprintf(stderr, "%s %s %s%s%s\n",
		    i == 0 ? "usage:" : "      ", getprogname(),
		    cmds[i].c_name, cmds[i].c_args[0] ? " " : "",
		    cmds[i].c_args);
	exit(1);
}

static void
getsysctl(const char *name, void *p, size_t len)
{
	size_t l = len;

	if (sysctlbyname(name, p, &l, NULL, 0) == -1)
		err(1, "%s", name);
	if (l != len)
		errx(1, "%s: %zu bytes, expected %zu; kernel and %s differ",
		    name, l, len, getprogname());
}

static void
setsysctl(const char *name, const void *p, size_t len)
{

	if (sysctlbyname(name, NULL, NULL, p, len) == -1)
		err(1, "%s", name);
}

static void
setint(const char *name, int val)
{

	setsysctl(name, &val, sizeof(val));
}

static void
getstats(struct azram_stats *st)
{

	getsysctl("vm.azram.stats", st, sizeof(*st));
}

static double
per(uint64_t a, uint64_t b)
{

	return b == 0 ? 0.0 : (double)a / (double)b;
}

static double
pct(uint64_t a, uint64_t b)
{

	return 100.0 * per(a, b);
}

/* Microseconds per event, from nanoseconds in total. */
static double
usec(uint64_t ns, uint64_t n)
{

	return per(ns, n) / 1000.0;
}

static const char *
statename(const struct azram_stats *st)
{

	if (st->st_flags & AZRAM_F_ENABLE)
		return "enabled";
	if (st->st_flags & AZRAM_F_MEASURE)
		return "measuring only (pages go to swap)";
	if (st->st_flags & AZRAM_F_BOOTOFF)
		return "disabled by the boot flag";
	return "disabled";
}

static int
cmd_status(int argc, char **argv)
{
	struct azram_stats st;
	const struct azram_counters *c = &st.st_c;
	uint64_t physmem, held, saved, cost, ncomp;
	u_int i;

	if (argc != 1)
		usage();
	getstats(&st);
	getsysctl("hw.physmem64", &physmem, sizeof(physmem));

	ncomp = 0;
	for (i = 0; i < AZRAM_NBUCKET; i++)
		ncomp += c->c_hist[i];
	held = st.st_entries + st.st_same_entries;
	cost = st.st_pool_bytes + st.st_meta_bytes;
	saved = held * st.st_pagesize > cost ?
	    held * st.st_pagesize - cost : 0;

	printf("state:       %s\n", statename(&st));
	printf("settings:    pool_max %.1f MB (%.0f%% of memory), "
	    "reject_size %" PRIu32 " bytes\n", MB(st.st_pool_max),
	    pct(st.st_pool_max, physmem), st.st_reject_size);
	printf("held:        %" PRIu64 " pages (%.1f MB): %" PRIu64
	    " compressed, %" PRIu64 " of one byte value\n", held,
	    MB(held * st.st_pagesize), st.st_entries, st.st_same_entries);
	printf("memory:      %.1f MB of pool (%.1f%% of pool_max), "
	    "%.1f MB of metadata; %.1f MB saved\n", MB(st.st_pool_bytes),
	    pct(st.st_pool_bytes, st.st_pool_max), MB(st.st_meta_bytes),
	    MB(saved));
	printf("compression: %.1f MB of data, ratio %.2f; the pool holds "
	    "%.2f times the data\n", MB(st.st_data_bytes),
	    per(st.st_entries * st.st_pagesize, st.st_data_bytes),
	    per(st.st_pool_bytes, st.st_data_bytes));
	if (st.st_reset_time != 0)
		printf("counters:    since a reset %" PRIu64 " s ago\n",
		    st.st_uptime - st.st_reset_time);
	else
		printf("counters:    since boot, %" PRIu64 " s ago\n",
		    st.st_uptime);
	printf("pageouts:    %" PRIu64 " pages offered; %" PRIu64
	    " kept compressed, %" PRIu64 " of one byte value\n",
	    c->c_tried, c->c_stored, c->c_stored_same);
	printf("refused:     %" PRIu64 " larger than reject_size, %" PRIu64
	    " over pool_max, %" PRIu64 " short of memory\n",
	    c->c_rej_size, c->c_rej_budget, c->c_rej_nomem);
	printf("pageins:     %" PRIu64 " from azram (%" PRIu64
	    " of one byte value), %.1f us each\n", c->c_loads,
	    c->c_loads_same, usec(c->c_decompress_ns, c->c_loads));
	printf("compressed:  %" PRIu64 " pages, %.1f us each\n", ncomp,
	    usec(c->c_compress_ns, ncomp));
	printf("freed:       %" PRIu64 " entries with their swap slot\n",
	    c->c_frees);
	printf("swap device: %" PRIu64 " pages written, %" PRIu64
	    " read, %.2f ms per read\n", c->c_swap_writes, c->c_swap_reads,
	    usec(c->c_swap_read_ns, c->c_swap_reads) / 1000.0);
	return 0;
}

static int
cmd_hist(int argc, char **argv)
{
	/* Candidate thresholds, in 1/64 page. */
	static const u_int cand[] = { 32, 40, 48, 56 };
	struct azram_stats st;
	const struct azram_counters *c = &st.st_c;
	uint64_t total, looked, cum, max, kept, cls;
	u_int step, i, j, k;

	if (argc != 1)
		usage();
	getstats(&st);
	step = st.st_class_size;

	total = 0;
	max = 0;
	for (i = 0; i < AZRAM_NBUCKET; i++) {
		total += c->c_hist[i];
		max = MAX(max, c->c_hist[i]);
	}
	looked = total + c->c_seen_same;
	printf("compressed sizes of %" PRIu64 " pages on their way to swap, "
	    "and %" PRIu64 " of one byte value:\n", total, c->c_seen_same);
	if (looked == 0) {
		printf("none yet; see \"%s measure on\"\n", getprogname());
		return 0;
	}

	printf("%11s %10s %6s %6s\n", "bytes", "pages", "%", "cum %");
	cum = 0;
	for (i = 0; i < AZRAM_NBUCKET; i++) {
		char range[32];
		int bar;

		if (c->c_hist[i] == 0)
			continue;
		cum += c->c_hist[i];
		if (i < AZRAM_NBUCKET - 1)
			(void)snprintf(range, sizeof(range), "%u-%u",
			    i * step + 1, (i + 1) * step);
		else
			(void)snprintf(range, sizeof(range), "%u-",
			    st.st_pagesize + 1);
		bar = (int)((c->c_hist[i] * BARW + max - 1) / max);
		printf("%11s %10" PRIu64 " %6.1f %6.1f %.*s%s\n", range,
		    c->c_hist[i], pct(c->c_hist[i], total), pct(cum, total),
		    bar, "########################################",
		    (i + 1) * step == st.st_reject_size ? "  <- reject_size" :
		    "");
	}

	/*
	 * What a threshold would keep: the one-value pages, and those that
	 * compress to it or less, each taking its size class (the upper end
	 * of its bucket, since buckets and classes are both 1/64 page).
	 */
	printf("\n%11s %8s %12s\n", "reject_size", "kept %", "ratio kept");
	for (j = 0; j < __arraycount(cand); j++) {
		const u_int r = cand[j] * step;

		kept = c->c_seen_same;
		cls = 0;
		for (k = 0; k < cand[j]; k++) {
			kept += c->c_hist[k];
			cls += c->c_hist[k] * (k + 1) * step;
		}
		printf("%11u %8.1f %12.2f%s\n", r, pct(kept, looked),
		    per((kept - c->c_seen_same) * st.st_pagesize, cls),
		    r == st.st_reject_size ? "  (current)" : "");
	}
	return 0;
}

static int
cmd_enable(int argc, char **argv)
{

	if (argc != 1)
		usage();
	setint("vm.azram.enable", 1);
	return 0;
}

static int
cmd_disable(int argc, char **argv)
{

	if (argc != 1)
		usage();
	setint("vm.azram.enable", 0);
	return 0;
}

static int
cmd_measure(int argc, char **argv)
{

	if (argc != 2)
		usage();
	if (strcmp(argv[1], "on") == 0)
		setint("vm.azram.measure", 1);
	else if (strcmp(argv[1], "off") == 0)
		setint("vm.azram.measure", 0);
	else
		usage();
	return 0;
}

static int
cmd_set(int argc, char **argv)
{
	uint64_t physmem, v64;
	int64_t n;
	char *ep;
	size_t len;

	if (argc != 3)
		usage();
	if (strcmp(argv[1], "pool_max") == 0) {
		len = strlen(argv[2]);
		if (len > 1 && argv[2][len - 1] == '%') {
			errno = 0;
			n = strtoll(argv[2], &ep, 10);
			if (errno != 0 || ep != argv[2] + len - 1 || n < 0 ||
			    n > 100)
				errx(1, "%s: not a percentage", argv[2]);
			getsysctl("hw.physmem64", &physmem, sizeof(physmem));
			v64 = physmem / 100 * (uint64_t)n;
		} else {
			if (dehumanize_number(argv[2], &n) == -1 || n < 0)
				errx(1, "%s: not a size", argv[2]);
			v64 = (uint64_t)n;
		}
		setsysctl("vm.azram.pool_max", &v64, sizeof(v64));
	} else if (strcmp(argv[1], "reject_size") == 0) {
		errno = 0;
		n = strtoll(argv[2], &ep, 10);
		if (errno != 0 || *ep != '\0' || n <= 0 || n > INT32_MAX)
			errx(1, "%s: not a number of bytes", argv[2]);
		setint("vm.azram.reject_size", (int)n);
	} else
		usage();
	return 0;
}

static int
cmd_reset(int argc, char **argv)
{
	struct azram_stats st;

	if (argc != 1)
		usage();
	memset(&st, 0, sizeof(st));
	setsysctl("vm.azram.stats", &st, sizeof(st));
	return 0;
}

int
main(int argc, char **argv)
{
	size_t i;

	if (argc < 2)
		return cmd_status(1, argv);
	for (i = 0; i < __arraycount(cmds); i++) {
		if (strcmp(argv[1], cmds[i].c_name) == 0)
			return (*cmds[i].c_func)(argc - 1, argv + 1);
	}
	usage();
}
