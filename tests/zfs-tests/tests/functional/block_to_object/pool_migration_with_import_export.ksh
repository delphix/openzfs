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
#	Ensure that we can export and import the pool at different
#	phases of a block to object-store migration without any
#	issues.
#
# STRATEGY:
#	1. Create block-based pool and populate it with some data.
#	2. Add object-store endpoint/vdev.
#	3. Set scan tunable so the block boundary scan doesn't make
#	   any progress.
#	4. Set removal tunable so removal doesn't make any progress.
#	5. Submit removal of block device.
#	6. Export the pool and re-import it while scanning hasn't
#	   made any progress yet.
#	7. Set scan_vdev_limit tunable for the scan to be slower
#	   and unset the tunable that suspended the scan.
#	8. Export the pool and re-import it while the scan is
#	   making progress.
#	9. Reset scan_vdev_limit tunable and wait for scan to finish.
#	10. Export the pool and re-import it once the scan has
#	   finished but the evacuation hasn't made any progress.
#	11. Set remove_max_segment and remove_max_txg_bytes to slow
#	   the removal down and unset the tunable that had suspended
#	   it.
#	12. Export the pool and re-import it while the removal is
#	   making progress.
#	13. Unset the tunable and wait for removal to finish.
#	14. Read from pre-object-store file ensuring that there are
#	   no issues with any of the file data that were evacuated
#	   to the object store.
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
	log_must set_tunable32 REMOVAL_SUSPEND_PROGRESS 1
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1

	#
	# Remove the only block-based vdev in the pool
	#
	log_must zpool remove $TESTPOOL $DISK

	#
	# (For logging purposes)
	#
	log_must zpool status $TESTPOOL

	#
	# Get pool guid and export and re-import the pool before
	# the scan makes any progress.
	#
	typeset GUID=$(zpool get -Hp -o value guid)
	log_must zpool export $TESTPOOL
	log_must zpool import \
		-o object-endpoint=$ZTS_OBJECT_ENDPOINT \
		-o object-region=$ZTS_REGION \
		-d $ZTS_BUCKET_NAME \
		-d $IMPORT_DIR \
		$GUID

	#
	# (For logging purposes)
	#
	log_must zpool status $TESTPOOL

	#
	# Set the scan_vdev_limit tunable to slow down the scan
	# once it gets resumed, and unset the scan suspend tunable
	#
	log_must set_tunable64 SCAN_VDEV_LIMIT $ZFS_SCAN_VDEV_LIMIT_SLOW
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0

	#
	# Sync at least once so the scan makes some progress
	#
	log_must zpool sync $TESTPOOL

	#
	# Export and re-import the pool while scanning is slowly
	# making progress.
	#
	log_must zpool export $TESTPOOL
	log_must zpool import \
		-o object-endpoint=$ZTS_OBJECT_ENDPOINT \
		-o object-region=$ZTS_REGION \
		-d $ZTS_BUCKET_NAME \
		-d $IMPORT_DIR \
		$GUID

	#
	# (For logging purposes)
	#
	log_must zpool status $TESTPOOL

	#
	# Reset the scanning speed and wait for scan to finish
	#
	log_must set_tunable64 SCAN_VDEV_LIMIT $ZFS_SCAN_VDEV_LIMIT_DEFAULT
	log_must zpool wait -t bb_scan $TESTPOOL

	#
	# Export and re-import the pool once the scan has finished but
	# before we evacuate any data.
	#
	log_must zpool export $TESTPOOL
	log_must zpool import \
		-o object-endpoint=$ZTS_OBJECT_ENDPOINT \
		-o object-region=$ZTS_REGION \
		-d $ZTS_BUCKET_NAME \
		-d $IMPORT_DIR \
		$GUID

	#
	# Set the some removal tunables to slow down the evacuation
	# phase once it gets resumed, and unset the removal pause
	# tunable
	#
	log_must set_tunable32 REMOVE_MAX_SEGMENT 16384
	log_must set_tunable32 REMOVE_MAX_TXG_BYTES 1048576
	log_must set_tunable32 REMOVAL_SUSPEND_PROGRESS 0

	#
	# Sync at least once so removal makes some progress
	#
	log_must zpool sync $TESTPOOL

	#
	# Export and re-import the pool while evacuation is slowly
	# making progress.
	#
	log_must zpool export $TESTPOOL
	log_must zpool import \
		-o object-endpoint=$ZTS_OBJECT_ENDPOINT \
		-o object-region=$ZTS_REGION \
		-d $ZTS_BUCKET_NAME \
		-d $IMPORT_DIR \
		$GUID

	#
	# Reset removal speed and wait for it to finish
	#
	log_must set_tunable32 REMOVE_MAX_SEGMENT 16777216
	log_must set_tunable32 REMOVE_MAX_TXG_BYTES 134217728
	log_must wait_for_removal $TESTPOOL

	#
	# Ensure we can read the testfile with data from before
	# the addition of the object store (should end up being
	# indirect ops to the object store).
	#
	log_must dd if=$TESTFILE0 of=/dev/null

	cleanup_testpool
done

log_pass "Successfully migrate pool while pool export/import."
