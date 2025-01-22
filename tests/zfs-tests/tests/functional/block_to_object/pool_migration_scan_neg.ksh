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
#	Ensure that we can't start a scrub while migration removal
#	is active.
#
# STRATEGY:
#	1. Create block-based pool and populate it with some data.
#	2. Add object-store endpoint/vdev.
#	3. Set the scan tunable so the pre-removal scan doesn't make
#          any progress.
#	4. Set removal tunable so removal doesn't make any progress.
#	5. Submit removal of block device.
#	6. Attempt to start a scrub while removal scan is in progress.
#	   It should fail.
#	7. Attempt to cancel the removal scrub. The cancellation
#	   should fail.
#	8. Unset the scan tunable and wait for scan to finish.
#	9. Attempt to start a scrub while actual evacuation is in
#	   progress. It should fail.
#	10. Unset the removal tunable and wait for removal to finish.
#	11. Read from pre-object-store file ensuring that there are
#	   no issues with that file post-removal.
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
# Set scan and removal pause tunables
#
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
log_must set_tunable32 REMOVAL_SUSPEND_PROGRESS 1

#
# Remove the only block-based vdev in the pool
#
log_must zpool remove $TESTPOOL $DISK

#
# Sync at least once to make sure we've started
# the scan that's about to be suspended.
#
log_must zpool sync

#
# (For logging purposes)
#
log_must zpool status $TESTPOOL

#
# Attempt to start scrub while removal scanning
# is in progress.
#
log_mustnot zpool scrub $TESTPOOL

#
# Attempt to stop existing removal scanning.
#
log_mustnot zpool scrub -s $TESTPOOL

#
# (For logging purposes)
#
log_must zpool status $TESTPOOL

#
# Unpause scanning and wait for it to finish
#
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
log_must zpool wait -t bb_scan $TESTPOOL

#
# Sync at least once to make sure we've started
# the removal/evacuation that's about to be suspended.
#
log_must zpool sync

#
# (For logging purposes)
#
log_must zpool status $TESTPOOL

#
# Attempt to start scrub while removal/evacuation
# is in progress.
#
log_mustnot zpool scrub $TESTPOOL

#
# Unpause removal and wait for it to finish
#
log_must set_tunable32 REMOVAL_SUSPEND_PROGRESS 0
log_must wait_for_removal $TESTPOOL


#
# Ensure we can read the testfile with data from before
# the addition of the object store (should end up being
# indirect ops to the object store).
#
log_must dd if=$TESTFILE0 of=/dev/null

cleanup_testpool

log_pass "Scrubs are not allowed during active migration removal."
