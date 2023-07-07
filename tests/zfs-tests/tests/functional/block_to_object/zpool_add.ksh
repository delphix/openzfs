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
#	Ensure that we can add an object store vdev to an existing
#	block-based pool and do some writes on it without any
#	problems.
#
# STRATEGY:
#	1. Create block-based pool and populate it with some data.
#	2. Add object-store endpoint/vdev
#	3. Write some new data
#	4. Read data from both block-based devices and object-store.
#

verify_runnable "global"

if ! use_object_store; then
    log_unsupported "Need object store info to migrate block-based pool."
fi

setup_testpool
log_onexit cleanup_testpool

#
# Add object store
#
log_must zpool add -f -o object-endpoint=$ZTS_OBJECT_ENDPOINT \
        -o object-region=$ZTS_REGION \
        $TESTPOOL $ZTS_OBJECT_STORE $ZTS_BUCKET_NAME

#
# Record allocated space in object store and the normal
# disk before writes
#
log_must zpool sync $TESTPOOL
OBJ_START=$(zpool list -Hp -o name,alloc -v |  \
	grep "$ZTS_BUCKET_NAME" | awk '{print $3}')
DISK_START=$(zpool list -Hp -o name,alloc -v |  \
	grep "$DISK" | awk '{print $3}')


#
# Write some data that should end up in the object store
#
log_must randwritecomp $TESTFILE1 4096

#
# Record allocated space in object store and the normal
# disk after writes
#
log_must zpool sync $TESTPOOL
OBJ_END=$(zpool list -Hp -o name,alloc -v |  \
	grep "$ZTS_BUCKET_NAME" | awk '{print $3}')
DISK_END=$(zpool list -Hp -o name,alloc -v |  \
	grep "$DISK" | awk '{print $3}')

#
# There should be some allocations in the object store by now.
#
log_must [ $OBJ_START -lt $OBJ_END ]

#
# There should be no new allocations in the normal disk.
#
log_must [ $DISK_START -ge $DISK_END ]

#
# Display information for manual checking
#
log_must zpool list -v $TESTPOOL

log_pass "Successfully add object store vdev and write to it."
