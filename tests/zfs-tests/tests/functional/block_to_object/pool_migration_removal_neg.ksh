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
. $STF_SUITE/tests/functional/cli_root/zpool_wait/zpool_wait.kshlib

#
# DESCRIPTION:
#	Ensure that we can't start a migration removal while an
#	active scrub exists.
#
# STRATEGY:
#	1. Create block-based pool and populate it with some data.
#	2. Add object-store endpoint/vdev.
#	3. Set the scan tunable so the pre-removal scan doesn't make
#          any progress.
#	4. Start a scrub.
#	5. Attempt to start the removal of block device. This should
#	   fail.
#	6. Unset the scan tunable and wait for scan to finish.
#	7. Start a removal and make sure it gets submitted successfully.
#

verify_runnable "global"

if ! use_object_store; then
    log_unsupported "Need object store info to migrate block-based pool."
fi

log_onexit cleanup_testpool

setup_testpool

#
# Sync some data before adding the object store
#
log_must zpool sync $TESTPOOL

#
# Add object store
#
log_must zpool add -f -o object-endpoint=$ZTS_OBJECT_ENDPOINT \
	-o object-region=$ZTS_REGION \
	$TESTPOOL $ZTS_OBJECT_STORE $ZTS_BUCKET_NAME

#
# Set scan pause tunable
#
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1

#
# Start scrub
#
log_must zpool scrub $TESTPOOL

#
# Sync once to make sure that scrub is in progress
#
log_must zpool sync

#
# (For logging purposes)
#
log_must zpool status $TESTPOOL

#
# Attempt to remove the only block-based vdev in the pool
#
log_mustnot zpool remove $TESTPOOL $DISK

#
# (For logging purposes)
#
log_must zpool status $TESTPOOL

#
# Unpause scanning and wait for it to finish
#
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
log_must zpool wait -t scrub $TESTPOOL

#
# (For logging purposes)
#
log_must zpool status $TESTPOOL

#
# Removal command should be successful now
#
log_must zpool remove $TESTPOOL $DISK

#
# (For logging purposes)
#
log_must zpool status $TESTPOOL

log_pass "Successfully block migration removals while scrubing."
