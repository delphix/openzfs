/*
 * CDDL HEADER START
 *
 * This file and its contents are supplied under the terms of the
 * Common Development and Distribution License ("CDDL"), version 1.0.
 * You may only use this file in accordance with the terms of version
 * 1.0 of the CDDL.
 *
 * A full copy of the text of the CDDL should have accompanied this
 * source.  A copy of the CDDL is also available via the Internet at
 * http://www.illumos.org/license/CDDL.
 *
 * CDDL HEADER END
 */
/*
 * Copyright (c) 2023 by Delphix. All rights reserved.
 */
#ifndef	_SET_H
#define	_SET_H

#ifdef	__cplusplus
extern "C" {
#endif

#include	<sys/zfs_context.h>

/*
 * Used to either get the lower 32-bits out of a uint64_t
 * or shift the high 32-bits to fit into a uint32_t.
 */
#define	SORTED_SET_U64_SHIFT	32ULL

/*
 * An ordered set of `uin64_t` based on an array of `zfs_btree_t`s.
 *
 * This structure is optimizing for memory consumption. It does so
 * by using the high 32-bits of the uint64_t to index into its
 * array of `zfs_btree_t`'s, with those trees containing `uint32_t`
 * elements with the lower 32-bits of the uint64_t inserted to the
 * set. Compared to a single `zfs_btree_t` with uint64_t elements
 * this structure should use approximately half the RAM in most
 * cases.
 */
typedef struct sorted_set_u64 {
	/* Number of subtrees in `ss_trees` array */
	uint64_t ss_ntrees;

	/* Array of subtrees that the set consists of */
	zfs_btree_t *ss_trees;

	/* Number of elements in all subtrees */
	uint64_t ss_num_elems;
} sorted_set_u64_t;

/*
 * An index pointing to the consumers position within a sorted set.
 * This is used the same way as `zfs_btree_index_t` points within
 * a `zfs_btree_t`.
 */
typedef struct sorted_set_u64_index {
	/* Current index within the `ss_trees` array */
	uint64_t ssi_tree;

	/* Index within the subtree pointed by `ssi_tree` */
	zfs_btree_index_t ssi_idx;
} sorted_set_u64_index_t;

static inline uint64_t
sorted_set_u64_nelems(sorted_set_u64_t *ss)
{
	return (ss->ss_num_elems);
}

/* An optional `uint64_t` value */
typedef struct option_u64 {
	boolean_t ou_valid;
	uint64_t ou_value;
} option_u64_t;

/* No value */
extern option_u64_t none_u64;

static inline boolean_t
option_u64_is_some(option_u64_t o)
{
	return (o.ou_valid);
}

static inline uint64_t
option_u64_unwrap(option_u64_t o)
{
	if (likely(option_u64_is_some(o)))
		return (o.ou_value);
	panic("cannot unwrap empty option_u64");
	/* unreachable */
	return (o.ou_value);
}

void sorted_set_u64_init(sorted_set_u64_t *, uint64_t);
void sorted_set_u64_fini(sorted_set_u64_t *);
option_u64_t sorted_set_u64_insert(sorted_set_u64_t *, uint64_t);
option_u64_t sorted_set_u64_get(sorted_set_u64_t *, uint64_t,
    sorted_set_u64_index_t *);
option_u64_t sorted_set_u64_next(sorted_set_u64_t *, sorted_set_u64_index_t *);

#ifdef	__cplusplus
}
#endif

#endif	/* _SET_H */
