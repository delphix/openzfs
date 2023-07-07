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
#	block-based pool while writes are taking place without
#	any problem.
#
# STRATEGY:
#	1. Create block-based pool and populate it with some data.
#	2. Start writing data to a file in the pool
#	3. Add object-store endpoint/vdev while writes are happening.
#	4. Stop writes when object-store has been added.
#

verify_runnable "global"

if ! use_object_store; then
    log_unsupported "Need object store info to migrate block-based pool."
fi

setup_testpool
log_onexit cleanup_testpool

#
# Start writing data in the background
#
randwritecomp $TESTFILE1 &
randwritecomp $TESTFILE1 &

#
# Add object store
#
log_must zpool add -f -o object-endpoint=$ZTS_OBJECT_ENDPOINT \
        -o object-region=$ZTS_REGION \
        $TESTPOOL $ZTS_OBJECT_STORE $ZTS_BUCKET_NAME

#
# Sync writes and kill any writers
#
log_must zpool sync $TESTPOOL
log_must pkill randwritecomp

log_pass "Successfully add object store vdev and write to it."
