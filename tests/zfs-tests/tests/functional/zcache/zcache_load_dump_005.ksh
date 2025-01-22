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

. "$STF_SUITE"/include/libtest.shlib
. "$STF_SUITE"/include/object_store.shlib
. "$STF_SUITE"/tests/functional/zcache/zcache_load_dump.kshlib

#
# DESCRIPTION:
#       Verify that the persistent zetta cache feature list-dumps
#
# STRATEGY:
#       1. Get a list of devices that are available
#       2. Stop the zfs-object-agent and add the list of devices that were
#          partitioned to be used as zettacache devices
#       3. Start the zfs-object-agent
#       4. Create a pool using object storage
#       5. Generate some zettacache data, running some IO operation on pool
#       8. Make sure Index and data populated. No pending merge
#       9. Wait for dump to be created and validate it.
#       9. Create new empty zetta cache
#       10.Run some IO on pool, wait for dump and validate list-dumps

verify_runnable "global"

if ! use_object_store; then
        log_unsupported "Test not applicable for block based run"
fi

function cleanup
{
        poolexists "$TESTPOOL" && destroy_pool "$TESTPOOL"
        zcache_remove_devices "$LARGE_PART_DEVICES"
        remove_cache_dump_interval
}

log_onexit cleanup

log_assert "Verify zettacache list-dumps"

log_note "Available devices [$AVAILABLE_DEVICES]"
log_note "Using cache devices [$LARGE_PART_DEVICES]"

log_must zcache_add_devices $LARGE_PART_DEVICES
verify_zcache_devices_were_added $LARGE_PART_DEVICES

log_must create_pool -p "$TESTPOOL" -l "log $SMALL_PART_DEVICES"
log_must poolexists "$TESTPOOL"

log_must zfs create -o recordsize=8k -o compression=lz4 "$TESTPOOL"/"$TESTFS"

# Do some sync write
log_must fio --name=run_io --filename=/"$TESTPOOL"/"$TESTFS"/file1 \
    --size=1048MiB --rw=randwrite --bs=4K --direct=0 \
    --numjobs=1 --ioengine=libaio --iodepth=1

sleep 10

log_must zcache sync --merge

log_must wait_for_pending_changes_to_merge

# Ensure dump has created
sleep 30

# Get list dumps
log_must verify_list_dumps $TESTPOOL 1
log_must validate_cache_data_with_dump_data_size "$TESTPOOL"

zcache_remove_devices $LARGE_PART_DEVICES

zcache_add_devices $LARGE_PART_DEVICES

# Do some sync write
log_must fio --name=run_io --filename=/"$TESTPOOL"/"$TESTFS"/file2 \
    --size=804MiB --rw=randwrite --bs=4K --direct=0 \
    --numjobs=1 --ioengine=libaio --iodepth=1

sleep 10

log_must zcache sync --merge

log_must wait_for_pending_changes_to_merge

# Ensure dump has created
sleep 30

log_must verify_list_dumps $TESTPOOL 2
log_must validate_cache_data_with_dump_data_size "$TESTPOOL"

log_pass cleanup
