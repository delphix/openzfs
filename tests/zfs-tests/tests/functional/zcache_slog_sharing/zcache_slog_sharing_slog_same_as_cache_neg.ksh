#!/bin/ksh -p
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or http://www.opensolaris.org/os/licensing.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#

#
# Copyright (c) 2022 by Delphix. All rights reserved.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/include/object_store.shlib
. $STF_SUITE/tests/functional/slog/slog.kshlib
. $STF_SUITE/tests/functional/zcache_slog_sharing/zcache_slog_sharing.kshlib


#
# DESCRIPTION:
#	Verify that the shared device(s) are partitioned and partition 1 is log
#	device and partition 2 is the cache. The zettacache device cannot be
#	used as slog device
#
# STRATEGY:
#	1. Get a list of devices that are available
#	2. For each device partition it into two parts such that 1/4 of the
#	   disk size is allocated to the log device & remaining 3/4 to the
#	   zcache device
#	3. Configure the zettacache devices
#	4. Create a pool and add all of configured zettacache devices
#	   to be used as slog devices
#	5. Verify that the pool cannot be created
#

verify_runnable "global"

if ! use_object_store; then
	log_unsupported "Test not applicable for block based run"
fi

function cleanup
{
	poolexists $TESTPOOL && destroy_pool $TESTPOOL
}

log_assert "Verify that the shared device(s) are partitioned into two parts." \
	" The first part should be usable as slog device and the second as zettacache" \
	" device. A zettacache device cannot be used as slog device"

log_onexit cleanup

# Create the pool
log_mustnot create_pool -p $TESTPOOL -l "log $CACHE_DEVICES"
log_mustnot poolexists $TESTPOOL


log_mustnot verify_zcache_devices_are_online $TESTPOOL $CACHE_DEVICES

log_pass "A zettacache device cannot be used as slog device"
