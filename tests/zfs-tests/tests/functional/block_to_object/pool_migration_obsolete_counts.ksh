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
#	Ensure that obsolete counts work as expected by purposefully
#	deleting pre-migration and ensuring that the in-memory
#	indirect mappings get reduced/go away.
#
# STRATEGY:
#	1. Create block-based pool and populate it with some data.
#	2. Add object-store endpoint/vdev.
#	3. Submit removal of block device, migrating the pool.
#	4. Read from pre-object-store file ensuring that there are
#	   no issues with that file post-removal.
#	5. Record indirect mappings/obsolete counts before deletions.
#	6. Delete pre-migration data.
#	5. Check indirect mappings/obsolete counts again and compare
#	   them to the ones recorded pre-deletion.
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
	#
	# Prepare the setup by adjusting the following tunables to
	# make it easier to trigger condensing of indirect mappings.
	#
	log_must set_tunable64 CONDENSE_INDIRECT_OBSOLETE_PCT 1
	log_must set_tunable64 CONDENSE_MIN_MAPPING_BYTES 1

	#
	# Adjust the following tunable to create a lot of small
	# indirect mappings and create more memory pressure after
	# removal is done.
	#
	log_must set_tunable32 REMOVE_MAX_SEGMENT 512

	setup_testpool $ashift

	#
	# Write some more data to the indirect mappings are populated.
	#
	log_must dd if=/dev/urandom of=$TESTFILE1 bs=10K count=4096

	#
	# Sync data before adding the object store
	#
	log_must zpool sync $TESTPOOL

	#
	# Add object store
	#
	log_must zpool add -f -o object-endpoint=$ZTS_OBJECT_ENDPOINT \
		-o object-region=$ZTS_REGION \
		$TESTPOOL $ZTS_OBJECT_STORE $ZTS_BUCKET_NAME

	#
	# Remove the only block-based vdev in the pool
	#
	log_must zpool remove $TESTPOOL $DISK

	#
	# (For logging purposes)
	#
	log_must zpool status $TESTPOOL

	#
	# Unpause removal and wait for it to finish
	#
	log_must wait_for_removal $TESTPOOL

	#
	# Ensure we can read the testfile with data from before
	# the addition of the object store (should end up being
	# indirect ops to the object store).
	#
	log_must dd if=$TESTFILE0 of=/dev/null
	log_must zpool sync $TESTPOOL

	#
	# (For logging purposes)
	#
	log_must zpool status $TESTPOOL

	#
	# Record indirect mappings
	#
	mappings_before=$(zdb -b -T $ZTS_OBJECT_STORE \
		-a $ZTS_OBJECT_ENDPOINT -g $ZTS_REGION \
		--bucket $ZTS_BUCKET_NAME $TESTPOOL | \
		grep "indirect vdev" | cut -d ' ' -f 6)

	#
	# Delete all data in the pool by deleting the dataset
	# created by `setup_testpool`.
	#
	log_must zfs destroy $DATASET

	#
	# Push a few spa_syncs so the condensing thread gets
	# woken up and submits some work.
	#
	for i in {1..15}; do
		sleep 1
		log_must zpool sync $TESTPOOL
	done

	#
	# (For logging purposes)
	#
	log_must zpool status $TESTPOOL

	#
	# Record indirect mappings and compare
	#
	mappings_after=$(zdb -b -T $ZTS_OBJECT_STORE \
		-a $ZTS_OBJECT_ENDPOINT -g $ZTS_REGION \
		--bucket $ZTS_BUCKET_NAME $TESTPOOL | \
		grep "indirect vdev" | cut -d ' ' -f 6)
	log_must [ $mappings_before -gt $mappings_after ]

	#
	# Reset all tunables.
	#
	log_must set_tunable32 REMOVE_MAX_SEGMENT 16777216
	log_must set_tunable64 CONDENSE_MIN_MAPPING_BYTES 131072
	log_must set_tunable64 CONDENSE_INDIRECT_OBSOLETE_PCT 25


	cleanup_testpool
done

log_pass "Successfully migrate pool while pool export/import."
