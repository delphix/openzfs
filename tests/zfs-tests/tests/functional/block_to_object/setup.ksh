#!/bin/ksh -p
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or http://www.opensolaris.org/os/licensing.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#

#
# Copyright (c) 2023 by Delphix. All rights reserved.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/include/object_store.shlib

if ! use_object_store; then
	log_unsupported "Test not applicable for block based run"
fi

if [ -z "$GITHUB_WORKFLOW" ]; then
	if [ $(wc -w <<<$ZETTACACHE_DEVICES) -lt 2 ]; then
		log_unsupported "Tests require two block devices"
	fi

	# These tests use the Zettacache devices to create block based pools for
	# migration. They get added back as Zettacache devices in the cleanup
	# script.
	log_must zcache_remove_devices $ZETTACACHE_DEVICES

	# Removing the cache devices can leave the labels in a state that
	# `zpool add` # cannot handle. Force a pool creation and destruction to
	# avoid this.
	log_must zpool create -f foo $ZETTACACHE_DEVICES
	log_must zpool destroy foo
fi

log_pass
