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
#	Ensure that we can't add an object store vdev to an existing
#	block-based pool while a removal is taking place.
#
# STRATEGY:
#	1. Create block-based pool and populate it with some data.
#	2. Add second device to allow removal of the first one.
#	3. Start removal and pause it.
#	4. Attempt to add object-store endpoint/vdev mid-removal.
#	   This should fail.
#

verify_runnable "global"

if ! use_object_store; then
    log_unsupported "Need object store info to migrate block-based pool."
fi

log_onexit cleanup_testpool

setup_testpool

#
# Adding new device to allow removal of first one
#
log_must zpool add $TESTPOOL $EXTRADISK

#
# Set removal pause tunable
#
log_must set_tunable32 REMOVAL_SUSPEND_PROGRESS 1

#
# Remove the only block-based vdev in the pool and
# wait for removal to finish.
#
log_must zpool remove $TESTPOOL $DISK

#
# Sync some more data before adding the object store
#
log_must zpool sync $TESTPOOL

#
# Add object store
#
log_mustnot zpool add -f -o object-endpoint=$ZTS_OBJECT_ENDPOINT \
	-o object-region=$ZTS_REGION \
	$TESTPOOL $ZTS_OBJECT_STORE $ZTS_BUCKET_NAME

#
# Unpause removal
#
log_must set_tunable32 REMOVAL_SUSPEND_PROGRESS 0

#
# Wait for removal to finish
#
log_must wait_for_removal $TESTPOOL
log_must zpool sync $TESTPOOL

#
# Ensure we can read the testfile with data from before
# the addition of the object store (should end up being
# indirect ops to the object store).
#
log_must dd if=$TESTFILE0 of=/dev/null

cleanup_testpool

log_pass "Successfully prevent adding an object store mid-removal."
