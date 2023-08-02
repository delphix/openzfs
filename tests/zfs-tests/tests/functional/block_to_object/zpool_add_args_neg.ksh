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
#	Test invalid arguments passed to zpool-add when adding an
#	object store vdev.
#

verify_runnable "global"

if ! use_object_store; then
    log_unsupported "Need object store info to migrate block-based pool."
fi

setup_testpool
log_onexit cleanup_testpool

#
# Attempt to add object store without -f option
#
log_mustnot zpool add -o object-endpoint=$ZTS_OBJECT_ENDPOINT \
	-o object-region=$ZTS_REGION \
	$TESTPOOL $ZTS_OBJECT_STORE $ZTS_BUCKET_NAME

#
# Attempt to add object store without bucket name
#
log_mustnot zpool add -f -o object-endpoint=$ZTS_OBJECT_ENDPOINT \
	-o object-region=$ZTS_REGION \
	$TESTPOOL $ZTS_OBJECT_STORE

#
# Attempt to add object store without endpoint property
#
log_mustnot zpool add -f \
	-o object-region=$ZTS_REGION \
	$TESTPOOL $ZTS_OBJECT_STORE $ZTS_BUCKET_NAME

#
# Attempt to add object store without region property
#
log_mustnot zpool add -f -o object-endpoint=$ZTS_OBJECT_ENDPOINT \
	$TESTPOOL $ZTS_OBJECT_STORE $ZTS_BUCKET_NAME

#
# Attempt without both endpoint and region properties
#
log_mustnot zpool add -f \
	$TESTPOOL $ZTS_OBJECT_STORE $ZTS_BUCKET_NAME

#
# Attempt to add other vdevs together with object store
#
log_mustnot zpool add -f -o object-endpoint=$ZTS_OBJECT_ENDPOINT \
	-o object-region=$ZTS_REGION \
	$TESTPOOL $EXTRADISK $ZTS_OBJECT_STORE $ZTS_BUCKET_NAME

#
# Attempt to add two object stores at the same time
#
log_mustnot zpool add -f -o object-endpoint=$ZTS_OBJECT_ENDPOINT \
	-o object-region=$ZTS_REGION \
	$TESTPOOL $ZTS_OBJECT_STORE $ZTS_BUCKET_NAME \
	$ZTS_OBJECT_STORE $ZTS_BUCKET_NAME

#
# Attempt with bogus bucket name
#
log_mustnot zpool add -f -o object-endpoint=$ZTS_OBJECT_ENDPOINT \
	-o object-region=$ZTS_REGION \
	$TESTPOOL $ZTS_OBJECT_STORE thisisbogus

#
# Attempt with bogus region
#
log_mustnot zpool add -f -o object-endpoint=$ZTS_OBJECT_ENDPOINT \
	-o object-region=thisisbogus \
	$TESTPOOL $ZTS_OBJECT_STORE $ZTS_BUCKET_NAME

#
# Attempt with bogus endpoint
#
log_mustnot zpool add -f -o object-endpoint=thisisbogus \
	-o object-region=$ZTS_REGION \
	$TESTPOOL $ZTS_OBJECT_STORE $ZTS_BUCKET_NAME

log_pass "Fail as expected when adding object store with invalid args."
