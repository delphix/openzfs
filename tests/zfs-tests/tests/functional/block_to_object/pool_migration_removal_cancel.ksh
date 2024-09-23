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
#	Ensure that we can cancel a removal migration without any
#	issues at its scanning and its evacuating stage.
#
# STRATEGY:
#	1. Create block-based pool and populate it with some data.
#	2. Add object-store endpoint/vdev.
#	3. Set the scan tunable so the pre-removal scan doesn't make
#          any progress.
#	4. Start a removal and then cancel it.
#	5. Unset scan tunable.
#	6. Start a scan showcasing that the removal scan is no longer
#	   in-progress and then cancel it.
#	7. Set the removal tunable so the evacuating part of the
#	   migration removal is stuck.
#	8. Submit new removal.
#	9. Wait for its scanning to be done and then cancel it.
#	10. Unset removal tunable to unblock removal.
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
# Submit removal command
#
log_must zpool remove $TESTPOOL $DISK

#
# Sync once to make sure that removal is in progress
#
log_must zpool sync

#
# (For logging purposes)
#
log_must zpool status $TESTPOOL

#
# Cancel removal command
#
log_must zpool remove -s $TESTPOOL

#
# Sync once to make sure that removal is cancelled
#
log_must zpool sync

#
# (For logging purposes)
#
log_must zpool status $TESTPOOL


#
# Unpause scanning and start a new scrub
# then wait for it to finish
#
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
log_must zpool scrub $TESTPOOL
log_must zpool scrub -w $TESTPOOL

#
# (For logging purposes)
#
log_must zpool status $TESTPOOL

#
# Set removal pause tunable
#
log_must set_tunable32 REMOVAL_SUSPEND_PROGRESS 1

#
# Submit removal command
#
log_must zpool remove $TESTPOOL $DISK

#
# Sync once to make sure that removal is in progress
#
log_must zpool sync

#
# (For logging purposes)
#
log_must zpool status $TESTPOOL

#
# Wait for scanning phase to finish
#
log_must zpool wait -t bb_scan $TESTPOOL

#
# Cancel removal command
#
log_must zpool remove -s $TESTPOOL

#
# Sync once to make sure that removal is cancelled
#
log_must zpool sync

#
# (For logging purposes)
#
log_must zpool status $TESTPOOL

#
# Unset removal tunable
#
log_must set_tunable32 REMOVAL_SUSPEND_PROGRESS 0

log_pass "Successfully cancel migration removal."
