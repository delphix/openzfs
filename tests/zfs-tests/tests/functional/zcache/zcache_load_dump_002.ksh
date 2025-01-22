#!/bin/ksh -p
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
#       Verify that the persistent zetta cache feature load and dump
#       works fine with lower size of new zettacache device.
#
# STRATEGY:
#       1. Get a list of devices that are available
#       2. Stop the zfs-object-agent and add the list of devices that were
#          partitioned to be used as zettacache devices
#       3. Start the zfs-object-agent
#       4. Create a pool using object storage
#       5. Verify that the pool was created
#       6. Generate some zettacache data, running some IO operation on pool
#       7. Make sure Index and data populated. No pending merge
#       8. Destroy zettcache by stopping agent.
#       9. Create new empty zetta cache, lower size compare to previous one
#       10. Perform zcache load from the dump of the old cache

verify_runnable "global"

if ! use_object_store; then
        log_unsupported "Test not applicable for block based run"
fi

CACHE_DEVICES="$LARGE_PART_DEVICES"
function cleanup
{
        poolexists "$TESTPOOL" && destroy_pool "$TESTPOOL"
        zcache_remove_devices "$CACHE_DEVICES"
}

log_assert "Verify that the zettacache load and dump works with small size of"\
    " zettacache device"

log_onexit cleanup

log_note "Available devices [$AVAILABLE_DEVICES]"
log_note "Using cache devices [$LARGE_PART_DEVICES]"

log_must zcache_add_devices $LARGE_PART_DEVICES
verify_zcache_devices_were_added $LARGE_PART_DEVICES

log_must create_pool -p "$TESTPOOL"
log_must poolexists "$TESTPOOL"

log_must zfs create -o recordsize=8k -o compression=lz4 "$TESTPOOL"/"$TESTFS"

# Do some sync write
log_must fio --name=run_io --filename=/"$TESTPOOL"/"$TESTFS"/file1 \
    --size=2GiB --rw=randwrite --bs=4K --direct=0 \
    --numjobs=1 --ioengine=libaio --iodepth=1

sleep 10

log_must zcache sync --merge

log_must wait_for_pending_changes_to_merge

zcache_remove_devices $LARGE_PART_DEVICES

log_note "Adding smaller size partition to zcache"
# Swap paritition
CACHE_DEVICES="$SMALL_PART_DEVICES"
zcache_add_devices $SMALL_PART_DEVICES

log_must zcache load $TESTPOOL

wait_for_zcache_load

log_pass cleanup
