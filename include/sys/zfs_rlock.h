/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").
 * You may not use this file except in compliance with the License.
 *
 * You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
 * or https://opensource.org/licenses/CDDL-1.0.
 * See the License for the specific language governing permissions
 * and limitations under the License.
 *
 * When distributing Covered Code, include this CDDL HEADER in each
 * file and include the License file at usr/src/OPENSOLARIS.LICENSE.
 * If applicable, add the following below this CDDL HEADER, with the
 * fields enclosed by brackets "[]" replaced with your own identifying
 * information: Portions Copyright [yyyy] [name of copyright owner]
 *
 * CDDL HEADER END
 */
/*
 * Copyright 2006 Sun Microsystems, Inc.  All rights reserved.
 * Use is subject to license terms.
 */
/*
 * Copyright (c) 2018, 2024 by Delphix. All rights reserved.
 */

#ifndef	_SYS_FS_ZFS_RLOCK_H
#define	_SYS_FS_ZFS_RLOCK_H

#ifdef	__cplusplus
extern "C" {
#endif

#include <sys/avl.h>

typedef enum {
	RL_READER,
	RL_WRITER
} zfs_rangelock_type_t;

typedef enum {
	RI_OLD,
	RI_NEW
} zfs_rangelock_impl_t;

struct zfs_locked_range;

typedef struct zfs_rangelock {
	zfs_rangelock_impl_t rl_impl;
	avl_tree_t rl_tree; /* contains locked_range_t */
	kmutex_t rl_lock;
} zfs_rangelock_t;

typedef void zfs_range_cookie_t;

void zfs_rangelock_init(zfs_rangelock_t *);
void zfs_rangelock_fini(zfs_rangelock_t *);

zfs_range_cookie_t *zfs_rangelock_enter(zfs_rangelock_t *,
    uint64_t, uint64_t, zfs_rangelock_type_t);
zfs_range_cookie_t *zfs_rangelock_tryenter(zfs_rangelock_t *,
    uint64_t, uint64_t, zfs_rangelock_type_t);
void zfs_rangelock_exit(zfs_range_cookie_t *);
void zfs_rangelock_reduce(zfs_range_cookie_t *, uint64_t, uint64_t);

uint64_t zfs_locked_range_offset(zfs_range_cookie_t *);
uint64_t zfs_locked_range_length(zfs_range_cookie_t *);

#ifdef	__cplusplus
}
#endif

#endif	/* _SYS_FS_ZFS_RLOCK_H */
