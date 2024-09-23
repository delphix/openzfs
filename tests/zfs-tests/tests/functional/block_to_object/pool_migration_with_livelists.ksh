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
#	1. Create block-based pool and populate it with some data
#	   and a clone.
#	2. Set tunables for slowing down livelists.
#	3. Add object-store endpoint/vdev.
#	4. Delete clone to create livelist.
#	5. Remove vdev to finalize migration to object store.
#	6. Read from all files ensuring that there are no issues
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
	# Limit the rate at which space is freed by limiting the
	# size of livelists so that we end up with a number of them.
	#
	log_must set_tunable64 LIVELIST_MAX_ENTRIES 16

	#
	# Don't disable livelists, no matter how much clone diverges
	# from snapshot.
	#
	log_must set_tunable64 LIVELIST_MIN_PERCENT_SHARED -1

	#
	# Write a some data
	#
	log_must dd if=/dev/urandom of=$TESTFILE1 bs=1M count=128

	#
	# Take snapshot
	#
	log_must zfs snapshot $DATASET@snap
	log_must zpool sync

	#
	# Create clone and write to it
	#
	log_must zfs clone $DATASET@snap $TESTPOOL/clone
	for i in {1..100}
	do
		log_must dd if=/dev/urandom of=/$TESTPOOL/clone/data-$i \
			bs=1k count=512
		log_must zpool sync
	done

	#
	# Debug
	#
	log_must zfs list -t all

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
	# Destroy clone to create livelist
	#
	log_must zfs destroy $TESTPOOL/clone
	log_must zpool sync

	#
	# Remove the only block-based vdev in the pool and
	# wait for removal to finish.
	#
	log_must zpool remove $TESTPOOL $DISK
	log_must wait_for_removal $TESTPOOL
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

	#
	# Verify that zdb doesn't find any issues
	#
	log_must zdb -T $ZTS_OBJECT_STORE \
		-a $ZTS_OBJECT_ENDPOINT \
		-g $ZTS_REGION \
		--bucket $ZTS_BUCKET_NAME \
		$TESTPOOL

	cleanup_testpool
done

log_pass "Successfully migrate pool with livelists."
