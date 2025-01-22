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
# Copyright (c) 2024 by Delphix. All rights reserved.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/include/object_store.shlib
. $STF_SUITE/tests/functional/zcache/zcache_load_dump.kshlib

if ! use_object_store; then
        log_unsupported "Test not applicable for block based run"
fi

if [ -n "$GITHUB_WORKFLOW" ]; then
    log_unsupported "Test not supported for Github workflow based run"
fi

if grep -q "/dev/loop" <<< "$AVAILABLE_DEVICES"; then
    log_unsupported "Test not applicable with loop devices"
fi

# Skip test if we are not able to find additional disks
# for the test
if [ -z "$AVAILABLE_DEVICES" ]; then
    log_unsupported "Test requires additional disks to be used as" \
        " zettacache. None found"
fi

for device in $AVAILABLE_DEVICES; do
    log_note "Partitioning device: $device"
    log_must create_slog_zcache_partition $device
done

set_cache_dump_interval "30 seconds"

log_pass
