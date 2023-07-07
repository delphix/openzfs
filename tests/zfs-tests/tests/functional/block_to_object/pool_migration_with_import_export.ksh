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
#	Ensure that we can export and import the pool while a block
#	to object-store migration is taking place, with the migration
#	completing successfully at the end.
#
# STRATEGY:
#	1. Create block-based pool and populate it with some data.
#	2. Add object-store endpoint/vdev.
#	3. Set removal tunable so removal doesn't make any progress.
#	4. Submit removal of block device.
#	5. Export the pool and re-import it.
#	6. Unset the tunable and wait for removal to finish.
#	7. Read from pre-object-store file ensuring that there are
#	   no issues with that file post-removal.
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
	# Set removal pause tunable
	#
	log_must set_tunable32 REMOVAL_SUSPEND_PROGRESS 1

	#
	# Remove the only block-based vdev in the pool
	#
	log_must zpool remove $TESTPOOL $DISK

	#
	# (For logging purposes)
	#
	log_must zpool status $TESTPOOL

	#
	# Get pool guid and export the pool
	#
	typeset GUID=$(zpool get -Hp -o value guid)
	log_must zpool export $TESTPOOL

	#
	# Re-import the pool
	#
	log_must zpool import \
		-o object-endpoint=$ZTS_OBJECT_ENDPOINT \
		-o object-region=$ZTS_REGION \
		-d $ZTS_BUCKET_NAME \
		-d ${DEVICE_DIR:-/dev} \
		$GUID

	#
	# (For logging purposes)
	#
	log_must zpool status $TESTPOOL

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
done

log_pass "Successfully migrate pool while pool export/import."
