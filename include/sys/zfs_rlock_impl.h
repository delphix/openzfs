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
 * Copyright (c) 2024 by Delphix. All rights reserved.
 */

#ifndef	_SYS_FS_ZFS_RLOCK_IMPL_H
#define	_SYS_FS_ZFS_RLOCK_IMPL_H

#ifdef	__cplusplus
extern "C" {
#endif

void zfs_rangelock2_init(zfs_rangelock_t *);
void zfs_rangelock2_fini(zfs_rangelock_t *);

zfs_range_cookie_t *zfs_rangelock2_enter(zfs_rangelock_t *,
    uint64_t, uint64_t, zfs_rangelock_type_t);
zfs_range_cookie_t *zfs_rangelock2_tryenter(zfs_rangelock_t *,
    uint64_t, uint64_t, zfs_rangelock_type_t);
void zfs_rangelock2_exit(zfs_range_cookie_t *);
void zfs_rangelock2_reduce(zfs_range_cookie_t *, uint64_t, uint64_t);

uint64_t zfs_range_cookie_offset(zfs_range_cookie_t *);
uint64_t zfs_range_cookie_length(zfs_range_cookie_t *);

#ifdef	__cplusplus
}
#endif

#endif	/* _SYS_FS_ZFS_RLOCK_H */
