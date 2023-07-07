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
#	block-based pool and that we can import and export it. Once
#	the object-store vdev is added, we shouldn't be able to import
#	the pool without the object-store vdev.
#
# STRATEGY:
#	1. Create block-based pool and populate it with some data.
#	2. Add object-store endpoint/vdev
#	3. Write some new data
#	4. Export the pool
#	5. Attempt to import the pool by only specifying the block
#	   device (this should fail).
#	6. Import the pool normally.
#

verify_runnable "global"

if ! use_object_store; then
    log_unsupported "Need object store info to migrate block-based pool."
fi

setup_testpool
log_onexit cleanup_testpool

#
# Add object store
#
log_must zpool add -f -o object-endpoint=$ZTS_OBJECT_ENDPOINT \
        -o object-region=$ZTS_REGION \
        $TESTPOOL $ZTS_OBJECT_STORE $ZTS_BUCKET_NAME

#
# Write some data
#
log_must randwritecomp $TESTFILE1 4096

#
# Get pool guid
#
typeset GUID=$(zpool get -Hp -o value guid)

#
# Export pool
#
log_must zpool export $TESTPOOL

#
# Attempt to import by only specifying the block vdev
#
log_mustnot zpool import -d ${DEVICE_DIR:-/dev} $TESTPOOL
log_mustnot zpool import -d ${DEVICE_DIR:-/dev} $GUID

#
# Import pool using object-store parameters
#
log_must zpool import \
	-o object-endpoint=$ZTS_OBJECT_ENDPOINT \
	-o object-region=$ZTS_REGION \
	-d $ZTS_BUCKET_NAME \
	-d ${DEVICE_DIR:-/dev} \
	$GUID

log_pass "Successfully add object store vdev and write to it."
