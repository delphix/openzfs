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
# 	Ensure that we cannot remove the object store vdev or mark
#	it as non-allocatable.
#
# STRATEGY:
#	1. Create block-based pool and populate it with some data.
#	2. Add object-store endpoint/vdev
#	3. Attempt to remove it
#	4. Attempt to mark it as noalloc
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
# Attempt to remove the object store vdev
#
log_mustnot zpool remove $TESTPOOL $ZTS_BUCKET_NAME

#
# Attempt to mark object store vdev as noalloc
#
log_mustnot zpool set allocating=off $TESTPOOL $ZTS_BUCKET_NAME

log_pass "Cannot remove object store vdev or mark it noalloc."
