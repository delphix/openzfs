#!/bin/ksh -p

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
# Copyright (c) 2023 by Delphix. All rights reserved.
#

. $STF_SUITE/tests/functional/block_to_object/block_to_object.kshlib

#
# DESCRIPTION:
#	Ensure that ZIL writes are satisfied from normal class
#	vdevs in hybrid pool setups
#
# STRATEGY:
#	1. Create block-based pool and populate it with some data.
#	2. Add object-store endpoint/vdev (now hybrid pool)
#	3. Write some new data to a dataset with sync=always
#	4. Ensure no ZIL skip commit counters are 0.
#	5. Read data to ensure no errors come up
#

verify_runnable "global"

if ! use_object_store; then
    log_unsupported "Need object store info to migrate block-based pool."
fi

setup_testpool
log_onexit cleanup_testpool

#
# Create ZIL dataset and file for writes
#
log_must zfs create -o sync=always $TESTPOOL/zil_dataset
log_must truncate -s 2g /$TESTPOOL/zil_dataset/data

#
# Start ZIL writes
#
randwritecomp /$TESTPOOL/zil_dataset/data &
randwritecomp /$TESTPOOL/zil_dataset/data &


#
# Add object store
#
log_must zpool add -f -o object-endpoint=$ZTS_OBJECT_ENDPOINT \
        -o object-region=$ZTS_REGION \
        $TESTPOOL $ZTS_OBJECT_STORE $ZTS_BUCKET_NAME

#
# Sync writes and kill any writers
#
log_must zpool sync $TESTPOOL
log_must pkill randwritecomp


#
# Write some more data after syncing to make sure
# that the object store is really usable.
#
log_must zpool sync $TESTPOOL
log_must randwritecomp $TESTFILE1 4096

#
# Record any ZIL failures/skips
#
log_must zpool sync $TESTPOOL
ZIL_SKIPS=$(sudo cat /proc/spl/kstat/zfs/$TESTPOOL/objset-0x* | \
	grep zil_skip_zil_commit | \
	awk '{sum += $3} END {print sum}')

#
# There should be no zil commit failures.
#
log_must [ $ZIL_SKIPS -eq 0 ]

#
# Display information for manual checking
#
log_must zpool list -v $TESTPOOL

log_pass "Successfully satisfy ZIL writes in hybrid pools."
