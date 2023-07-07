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
#	block-based pool and remove any block-based vdev while writes
#	are taking place without any problem.
#
# STRATEGY:
#	1. Create block-based pool and populate it with some data.
#	2. Start writing data to a file in the pool
#	3. Add object-store endpoint/vdev while writes are happening.
#	4. Stop writes when block removal is done.
#	5. Read from all files ensuring that there are no issues
#	   post-removal.
#

verify_runnable "global"

if ! use_object_store; then
    log_unsupported "Need object store info to migrate block-based pool."
fi

log_onexit cleanup_testpool

#
# Testing for both ashift 9 and 12 to emulate the most common
# block sizes out there - 512 (e.g. ESX, AWS) and 4K (e.g. Azure)
#
for ashift in 9 12; do
	setup_testpool $ashift

	#
	# Start writing data in the background
	#
	randwritecomp $TESTFILE1 &
	randwritecomp $TESTFILE1 &

	#
	# Sync some more data before adding the object store
	#
	log_must zpool sync $TESTPOOL

	#
	# Add object store
	#
	log_must zpool add -f -o object-endpoint=$ZTS_OBJECT_ENDPOINT \
		-o object-region=$ZTS_REGION \
		$TESTPOOL $ZTS_OBJECT_STORE $ZTS_BUCKET_NAME

	#
	# Sync writes up to this point
	#
	log_must zpool sync $TESTPOOL

	#
	# Remove the only block-based vdev in the pool and
	# wait for removal to finish.
	#
	log_must zpool remove $TESTPOOL $DISK
	log_must wait_for_removal $TESTPOOL


	#
	# Kill any writers and sync all writes
	#
	log_must pkill randwritecomp
	log_must zpool sync $TESTPOOL

	#
	# Ensure we can read the testfile with data from before
	# the addition of the object store (should end up being
	# indirect ops to the object store).
	#
	log_must dd if=$TESTFILE0 of=/dev/null

	#
	# Ensure all other data can be also read.
	#
	log_must dd if=$TESTFILE1 of=/dev/null

	cleanup_testpool
done

log_pass "Successfully add object store vdev and write to it."
