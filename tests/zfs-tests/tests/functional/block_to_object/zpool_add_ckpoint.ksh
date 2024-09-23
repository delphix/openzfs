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
#	Ensure that we can't add an object store while the pool has
#	a checkpoint.
#

verify_runnable "global"

if ! use_object_store; then
    log_unsupported "Need object store info to migrate block-based pool."
fi

setup_testpool
log_onexit cleanup_testpool

log_must zpool checkpoint $TESTPOOL

log_mustnot zpool add -f -o object-endpoint=$ZTS_OBJECT_ENDPOINT \
	-o object-region=$ZTS_REGION \
	$TESTPOOL $ZTS_OBJECT_STORE $ZTS_BUCKET_NAME

log_pass "Cannot add object store when checkpointed."
