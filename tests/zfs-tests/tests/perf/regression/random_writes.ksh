#!/bin/ksh

#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# http://www.illumos.org/license/CDDL.
#

#
# Copyright (c) 2015, 2022 by Delphix. All rights reserved.
#

#
# Description:
# Trigger fio runs using the random_writes job file. The number of runs and
# data collected is determined by the PERF_* variables. See do_fio_run for
# details about these variables.
#
# Prior to each fio run the dataset is recreated, and fio writes new files
# into an otherwise empty pool.
#
# Thread/Concurrency settings:
#    PERF_NTHREADS defines the number of files created in the test filesystem,
#    as well as the number of threads that will simultaneously drive IO to
#    those files.  The settings chosen are from measurements in the
#    PerfAutoESX/ZFSPerfESX Environments, selected at concurrency levels that
#    are at peak throughput but lowest latency.  Higher concurrency introduces
#    queue time latency and would reduce the impact of code-induced performance
#    regressions.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/perf/perf.shlib

function cleanup
{
	# kill fio and iostat
	pkill fio
	pkill iostat
	destroy_perf_pool
}

trap "log_fail \"Measure IO stats during random read load\"" SIGTERM
log_onexit cleanup

recreate_perf_pool
populate_perf_filesystems

# Aim to fill the pool to 50% capacity while accounting for a 3x compressratio.
if use_object_store; then
	export TOTAL_SIZE=$((128 * 1024 * 1024 * 1024))
else
	export TOTAL_SIZE=$(($(get_prop avail $PERFPOOL) * 3 / 2))
fi

# Variables specific to this test for use by fio.
export PERF_NTHREADS=${PERF_NTHREADS:-'32 128'}
export PERF_NTHREADS_PER_FS=${PERF_NTHREADS_PER_FS:-'0'}
export PERF_IOSIZES=${PERF_IOSIZES:-'8k'}
export PERF_SYNC_TYPES=${PERF_SYNC_TYPES:-'0 1'}

log_note "Random writes with settings: $(print_perf_settings)"
do_fio_run random_writes.fio true false
log_pass "Measure IO stats during random write load"
