
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

#include <sys/avl.h>
#include <sys/btree.h>
#include <sys/set.h>
#include <sys/bitops.h>
#include <sys/zfs_context.h>
#include <sys/fs/zfs.h>

option_u64_t none_u64 = {
	.ou_valid = B_FALSE,
	.ou_value = 0,
};

static int
sorted_set_u64_compare(const void *larg, const void *rarg)
{
	return (TREE_CMP(*(const uint32_t *)larg, *(const uint32_t *)rarg));
}

/*
 * Initialize a `sorted_set_u64_t`.
 *
 * The domain parameter specifies the largest value that can
 * be stored in the set. The set will use memory proportional
 * to this value, allocating domain>>32 sub-trees.
 */
void
sorted_set_u64_init(sorted_set_u64_t *sos, uint64_t domain)
{
	sos->ss_num_elems = 0;
	sos->ss_ntrees = (domain >> SORTED_SET_U64_SHIFT) + 1;
	sos->ss_trees = kmem_zalloc(sizeof (zfs_btree_t) * sos->ss_ntrees,
	    KM_SLEEP);
	for (uint64_t i = 0; i < sos->ss_ntrees; i++) {
		zfs_btree_create(&sos->ss_trees[i],
		    sorted_set_u64_compare, NULL, sizeof (uint32_t));
	}
}

/*
 * Teardown a `sorted_set_u64_t` freeing up all of its internal
 * data.
 */
void
sorted_set_u64_fini(sorted_set_u64_t *ss)
{
	for (uint64_t i = 0; i < ss->ss_ntrees; i++) {
		zfs_btree_clear(&ss->ss_trees[i]);
		zfs_btree_destroy(&ss->ss_trees[i]);
	}
	kmem_free(ss->ss_trees, sizeof (zfs_btree_t) * ss->ss_ntrees);
	memset(ss, 0, sizeof (*ss));
}

/*
 * Insert `value` into the set `ss`.
 *
 * If the value already exists in the set, it is also returned
 * as an optional. Otherwise `none_u64` is returned.
 */
option_u64_t
sorted_set_u64_insert(sorted_set_u64_t *ss, uint64_t value)
{
	uint64_t t = value >> SORTED_SET_U64_SHIFT;
	uint32_t tree_offset = (value % (1ULL << SORTED_SET_U64_SHIFT));

	ASSERT3U(t, <, ss->ss_ntrees);
	zfs_btree_index_t where = {0};
	if (zfs_btree_find(&ss->ss_trees[t], &tree_offset, &where) == NULL) {
		zfs_btree_add_idx(&ss->ss_trees[t], &tree_offset, &where);
		ss->ss_num_elems++;
		return (none_u64);
	}
	option_u64_t ret = {
	    .ou_valid = B_TRUE,
	    .ou_value = value,
	};
	return (ret);
}

/*
 * Search `ss` for `value` and mutate `idx` accordingly
 * to point to the location of `value` within the set.
 *
 * If `value` is found it is also returned as an optional,
 * otherwise `none_u64` is returned.
 *
 * Note: In the event that `value` is not found, `idx` is
 * still mutated accordingly to point to the location that
 * `value` would have been if it existed within `ss`.
 */
option_u64_t
sorted_set_u64_get(sorted_set_u64_t *ss,
    uint64_t value, sorted_set_u64_index_t *idx)
{
	uint64_t t = value >> SORTED_SET_U64_SHIFT;
	uint32_t tree_offset = (value % (1ULL << SORTED_SET_U64_SHIFT));

	idx->ssi_tree = t;
	uint32_t *v = zfs_btree_find(&ss->ss_trees[t],
	    &tree_offset, &idx->ssi_idx);

	if (v == NULL)
		return (none_u64);

	option_u64_t ret = {
	    .ou_valid = B_TRUE,
	    .ou_value = value,
	};
	return (ret);
}

/*
 * Get the next element in the ordered set `ss` from `idx`
 * if any.
 */
option_u64_t
sorted_set_u64_next(sorted_set_u64_t *ss,
    sorted_set_u64_index_t *idx)
{
	if (idx->ssi_tree == ss->ss_ntrees)
		return (none_u64);
	ASSERT3U(idx->ssi_tree, <, ss->ss_ntrees);

	while (idx->ssi_tree < ss->ss_ntrees) {
		uint32_t *value = zfs_btree_next(&ss->ss_trees[idx->ssi_tree],
		    &idx->ssi_idx, &idx->ssi_idx);
		if (value != NULL) {
			uint64_t ou_value =
			    (idx->ssi_tree << SORTED_SET_U64_SHIFT) + *value;
			option_u64_t ret = {
			    .ou_valid = B_TRUE,
			    .ou_value = ou_value,
			};
			return (ret);
		}
		memset(&idx->ssi_idx, 0, sizeof (zfs_btree_index_t));
		idx->ssi_tree++;
	}
	return (none_u64);
}
