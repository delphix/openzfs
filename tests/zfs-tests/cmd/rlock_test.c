/*
 * This file and its contents are supplied under the terms of the
 * Common Development and Distribution License ("CDDL"), version 1.0.
 * You may only use this file in accordance with the terms of version
 * 1.0 of the CDDL.
 *
 * A full copy of the text of the CDDL should have accompanied this
 * source.  A copy of the CDDL is also available via the Internet at
 * http://www.illumos.org/license/CDDL.
 */

/*
 * Copyright (c) 2024 by Delphix. All rights reserved.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/zfs_context.h>
#include <sys/zfs_rlock.h>
#include <sys/time.h>
#include <sys/resource.h>

static int seed = 0;
static int timeout = 180;
static int file_limit = 64 * 1024;
static int range_limit = 100;
static int mix = 75;

static int verbosity = 0;

static uint64_t reads = 0;
static uint64_t writes = 0;

static uint64_t active_readers = 0;
static uint64_t active_writers = 0;

zfs_rangelock_t rangelock;
extern boolean_t zfs_rangelock_progressive;

static void
usage(int exit_value)
{
	(void) fprintf(stderr, "Usage:\tbtree_test [-r <seed>] [-n <threads>] "
	    "[-t timeout>] [-m <r/w mix]>\n");
	(void) fprintf(stderr, "\t[-l <limit>]\n");
	(void) fprintf(stderr, "\t-n number of threads [default: 100]\n");
	(void) fprintf(stderr, "\t-l the size of the \"file\" "
	    "[default: 64k]\n");
	(void) fprintf(stderr, "\t-w the max size of the range to lock "
	    "[default: 100]\n");
	(void) fprintf(stderr, "\t-r random seed [default: from "
	    "gettimeofday()]\n");
	(void) fprintf(stderr, "\t-t seconds to let the test run "
	    "[default: 180]\n");
	(void) fprintf(stderr, "\t-m percentage of threads to have as readers "
	    "[default: 75]\n");
	exit(exit_value);
}

static void *
stats_thread(void *arg)
{
	(void) arg;
	time_t t0;
	struct timeval tp;
	(void) gettimeofday(&tp, NULL);
	t0 = tp.tv_sec;
	uint64_t total_readers = 0, total_writers = 0, counts = 0;
	while (1) {
		usleep(10000);
		total_readers += atomic_load_64(&active_readers);
		total_writers += atomic_load_64(&active_writers);
		counts++;
		(void) gettimeofday(&tp, NULL);
		if (tp.tv_sec > t0 + timeout) {
			break;
		}
	}
	fprintf(stdout, "Average active readers: %lf, "
	    "average active writers: %lf\n", total_readers/(double)counts,
	    total_writers/(double)counts);
	return (NULL);
}

static void *
worker_thread(void *arg)
{
	uint64_t tid = (uint64_t)arg;
	time_t t0;
	struct timeval tp;
	int64_t local_reads = 0, local_writes = 0;

	(void) gettimeofday(&tp, NULL);
	t0 = tp.tv_sec;

	struct random_data data;
	char buf[256];
	VERIFY0(initstate_r(seed + tid, buf, 256, &data));

	while (1) {
		int32_t random;
		VERIFY0(random_r(&data, &random));
		zfs_rangelock_type_t type =
		    random % 100 <= mix ? RL_READER : RL_WRITER;

		VERIFY0(random_r(&data, &random));
		int32_t start = random % (file_limit - 1);
		VERIFY0(random_r(&data, &random));
		int32_t len = range_limit == 1 ? 1 :
		    (random % (range_limit - 1)) + 1;
		if (len + start >= file_limit)
			len = file_limit - start - 1;

		if (verbosity) {
			fprintf(stderr, "tid %lu: before %u %u %d\n", tid,
			    start, len, type);
		}
		zfs_range_cookie_t *cookie = zfs_rangelock_enter(&rangelock,
		    start, len, type);
		if (type == RL_READER)
			atomic_add_64(&active_readers, 1);
		else
			atomic_add_64(&active_writers, 1);
		if (verbosity) {
			fprintf(stderr, "tid %lu: during %u %u %d\n", tid,
			    start, len, type);
		}
		VERIFY0(random_r(&data, &random));
		int32_t sleep_len = (random % 1000) + 500;
		usleep(sleep_len);
		if (type == RL_READER)
			atomic_add_64(&active_readers, -1);
		else
			atomic_add_64(&active_writers, -1);
		zfs_rangelock_exit(cookie);
		if (verbosity) {
			fprintf(stderr, "tid %lu: after %u %u %d\n", tid, start,
			    len, type);
		}
		if (type == RL_READER)
			local_reads++;
		else
			local_writes++;

		(void) gettimeofday(&tp, NULL);
		if (tp.tv_sec > t0 + timeout) {
			atomic_add_64(&reads, local_reads);
			atomic_add_64(&writes, local_writes);
			break;
		}
	}
	return (NULL);
}

int
main(int argc, char *argv[])
{
	struct timeval tp;
	int c;

	int nthreads = 100;

	while ((c = getopt(argc, argv, "l:n:m:r:t:w:vN")) != -1) {
		switch (c) {
		case 'l':
			file_limit = atoi(optarg);
			break;
		case 'm':
			mix = atoi(optarg);
			break;
		case 'n':
			nthreads = atoi(optarg);
			break;
		case 'r':
			seed = atoi(optarg);
			break;
		case 't':
			timeout = atoi(optarg);
			break;
		case 'w':
			range_limit = atoi(optarg);
			break;
		case 'v':
			verbosity++;
			break;
		case 'N':
			zfs_rangelock_progressive = B_TRUE;
			break;
		case 'h':
		default:
			usage(1);
			break;
		}
	}
	(void) gettimeofday(&tp, NULL);
	int start = tp.tv_sec;
	if (seed == 0)
		seed = tp.tv_sec;

	zfs_rangelock_init(&rangelock);

	fprintf(stderr, "Seed: %u\n", seed);

	pthread_t *tid = malloc(nthreads * sizeof (*tid));
	for (uint64_t i = 0; i < nthreads; i++) {
		pthread_create(tid + i, NULL, worker_thread, (void *)i);
	}
	pthread_t stat_tid;
	pthread_create(&stat_tid, NULL, stats_thread, NULL);
	sleep(timeout);
	fprintf(stdout, "Collecting threads...\n");
	void *status = NULL;
	for (int i = 0; i < nthreads; i++) {
		pthread_join(tid[i], &status);
	}
	pthread_join(stat_tid, &status);

	(void) gettimeofday(&tp, NULL);
	int duration = tp.tv_sec - start;

	fprintf(stdout,
	    "Reads: %lu, Writes: %lu\n Reads/s: %lf, Writes/s: %lf\n",
	    reads, writes, ((double)reads)/duration/nthreads,
	    ((double)writes)/duration/nthreads);

	zfs_rangelock_fini(&rangelock);

	return (0);
}
