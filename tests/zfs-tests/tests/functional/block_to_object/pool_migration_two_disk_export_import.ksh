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
#	Ensure that we can do an export/import between removal of 2 disks.
#

verify_runnable "global"

if ! use_object_store; then
    log_unsupported "Need object store info to migrate block-based pool."
fi

log_onexit cleanup_testpool

setup_testpool

log_must zpool add $TESTPOOL $EXTRADISK

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
# Set noalloc on both disks, then remove first disk.  We will gather
# the block boundary info for the second disk as well.
#
log_must zpool set allocating=off $TESTPOOL $DISK
log_must zpool set allocating=off $TESTPOOL $EXTRADISK
log_must zpool remove $TESTPOOL $DISK
log_must wait_for_removal $TESTPOOL

#
# Export/import
#
log_must zpool status $TESTPOOL
typeset GUID=$(zpool get -Hp -o value guid)
log_must zpool export $TESTPOOL
log_must zpool import \
	-o object-endpoint=$ZTS_OBJECT_ENDPOINT \
	-o object-region=$ZTS_REGION \
	-d $ZTS_BUCKET_NAME \
	-d $IMPORT_DIR \
	$GUID

#
# Remove second disk
#
log_must zpool status $TESTPOOL
log_must zpool remove $TESTPOOL $EXTRADISK
log_must wait_for_removal $TESTPOOL
log_must zpool status $TESTPOOL

log_pass "Successfully cancel migration removal."
