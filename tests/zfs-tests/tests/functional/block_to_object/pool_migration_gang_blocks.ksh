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
#	Ensure that we can migrate gang blocks correctly.
#
# STRATEGY:
#	1. Create block-based pool and populate it with some data.
#	2. Set the ganging tunable and do some more writes to force
#	   the creation of gang blocks.
#	3. Reset tunable.
#	4. Add object-store endpoint/vdev and remove block-based vdev.
#	5. Once removal/migration is done read gang blocks.
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
	# Set ganging tunable
	#
	log_must set_tunable64 METASLAB_FORCE_GANGING 4096

	#
	# Issue some writes to introduce gang blocks
	#
	dd if=/dev/urandom of=$TESTFILE1 bs=6k count=10240

	#
	# Make sure writes are synced and run zdb to check
	# for gang block counts in log
	#
	zpool sync $TESTPOOL
	log_must zdb -b $TESTPOOL

	#
	# Reset tunable
	#
	log_must set_tunable64 METASLAB_FORCE_GANGING 16777217

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
        # Unpause removal and wait for it to finish
        #
        log_must wait_for_removal $TESTPOOL

        #
        # (For logging purposes)
        #
        log_must zpool status $TESTPOOL

	#
	# Verify that zdb doesn't find any issues
	#
	log_must zdb -T $ZTS_OBJECT_STORE \
		-a $ZTS_OBJECT_ENDPOINT \
		-g $ZTS_REGION \
		--bucket $ZTS_BUCKET_NAME \
		$TESTPOOL

	#
	# Read all the gang blocks and ensure nothing
	# went wrong
	#
	dd if=$TESTFILE1 of=/dev/zero

	cleanup_testpool
done

log_pass "Successfully migrate gang blocks."
