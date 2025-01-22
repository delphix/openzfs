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
 * Copyright 2010 Sun Microsystems, Inc.  All rights reserved.
 * Use is subject to license terms.
 */
/*
 * Copyright (c) 2012, 2024 by Delphix. All rights reserved.
 */

/*
 * This file contains the code to implement file range locking in ZFS. This is
 * the second such implementation, and this implementation is largely the same
 * as the original from a rules/API perspective. The major difference is that
 * this implementation is focused on reducing the locking overhead by avoiding
 * unnecessary wakeups.
 *
 * Additional goals
 * ----------------
 * 1. No starvation of readers or writers
 * 2. No wakeups that don't make forward progress*
 * 3. No O(f(filesize)) operations
 *
 * Differences from the previous version
 * -------------------------------------
 * The major design difference between this version and the previous one is a
 * willingness to split locks. This adds some code complexity, and more
 * allocations. The upside is that you no longer have to broadcast all reader
 * and writers on the condvars every time, which massively reduces the impact
 * of the thundering herd problem. This version also solves the third reader-
 * writer problem, by preventing readers from starving.
 *
 * Terminology note
 * ----------------
 * "Enter" and "Exit" are used to refer to the rangelock as a whole.
 * "Acquire" and "Release" are used to refer to individual locks.
 *
 * Dispatch
 * --------
 * The new design does not always allow as much parallelism as the
 * original. As a result, we don't enable them by default for all use
 * cases. There is a tunable that can be used that will cause all
 * newly-created rangelocks to use the new algorithm, which can be enabled and
 * disabled at any time.
 *
 * Common case
 * -----------
 * The (hopefully) usual case is of no overlaps or contention for locks. On
 * entry to rangelock_enter(), a locked_range_t is allocated; the tree
 * searched that finds no overlap, and *this* locked_range_t is placed in the
 * tree.
 *
 * Overlaps/Conflicts
 * ------------------
 * Each entry in the tree covers a specific part of the file. If a lock
 * request comes in that conflicts with an existing hold and the request is
 * the same as the existing hold it will simply wait on that entry's condvars
 * (whichever is appropriate for a lock of that type). If it isn't exactly the
 * same, we split the request up and lock each portion in order. First, any
 * prefix before the first conflicted range is locked immediately. Then, we
 * wait on each conflicting range in turn. If we need to split an existing
 * range to only lock the necessary portion, we do so. Anyone else waiting on
 * that range will see when they are awoken that they also need to grab the
 * newly-split portion of the range. Finally, any tail after the last
 * conflicted range is also locked.
 *
 * Thread coordination
 * -------------------
 * In order to make wakeups efficient and to ensure multiple continuous
 * readers on a range don't starve a writer for the same range lock, two
 * condition variables are allocated in each rl_t. We only wake up the thread(s)
 * who now owns the lock, so all wakeups are associated with at least some
 * amount of forward progress.
 *
 * Appends/grows
 * -------------
 * Appends and block growing is handled the same as in the base rlock.
 */

#include <sys/inttypes.h>
#include <sys/zfs_context.h>
#include <sys/zfs_rlock.h>
#include <sys/zfs_rlock_impl.h>
#include <sys/debug.h>

typedef struct zfs_range_cookie {
	zfs_rangelock_t *rc_rangelock; /* must be first */
	uint64_t rc_offset;	/* file range offset */
	uint64_t rc_length;	/* file range length */
	zfs_rangelock_type_t rc_type; /* range type */
	void *rc_hint1, *rc_hint2;
} zfs_range_cookie_impl_t;

typedef struct zfs_locked_range2 {
	avl_node_t	lr_node;		/* avl node link */
	uint64_t	lr_offset;		/* file range offset */
	uint64_t	lr_length;		/* file range length */
	uint64_t	lr_psl;			/* pre-split length */
	kcondvar_t	lr_write_cv;		/* cv for waiting writers */
	kcondvar_t	lr_read_cv;		/* cv for waiting readers */
	uint32_t	lr_writers_waiting;	/* number of waiting writers */
	uint32_t	lr_readers_waiting;	/* number of waiting readers */
	/*
	 * number of readers holding lock; note that if this is 0, there is
	 * a writer
	 */
	uint32_t	lr_readers_held;
} zfs_locked_range2_t;

/*
 * AVL comparison function used to order range locks
 * Locks are ordered on the start offset of the range.
 */
static int
zfs_rangelock2_compare(const void *arg1, const void *arg2)
{
	const zfs_locked_range2_t *rl1 = (const zfs_locked_range2_t *)arg1;
	const zfs_locked_range2_t *rl2 = (const zfs_locked_range2_t *)arg2;

	return (TREE_CMP(rl1->lr_offset, rl2->lr_offset));
}

static zfs_locked_range2_t *
new_lock(uint64_t off, uint64_t len, zfs_rangelock_type_t type)
{
	ASSERT3U(off + len, >, off);
	zfs_locked_range2_t *new = kmem_alloc(sizeof (*new), KM_SLEEP);
	new->lr_offset = off;
	new->lr_length = len;
	new->lr_psl = 0;
	new->lr_writers_waiting = 0;
	new->lr_readers_waiting = 0;
	new->lr_readers_held = type == RL_READER ? 1 : 0;

	cv_init(&new->lr_read_cv, NULL, CV_DEFAULT, NULL);
	cv_init(&new->lr_write_cv, NULL, CV_DEFAULT, NULL);
	return (new);
}

static zfs_locked_range2_t *
new_lock_from_cookie(zfs_range_cookie_impl_t *cookie)
{
	zfs_locked_range2_t *new = new_lock(cookie->rc_offset,
	    cookie->rc_length, cookie->rc_type);
	cookie->rc_hint1 = cookie->rc_hint2 = new;
	return (new);
}

void
zfs_rangelock2_init(zfs_rangelock_t *rl)
{
	rl->rl_impl = RI_NEW;
	mutex_init(&rl->rl_lock, NULL, MUTEX_DEFAULT, NULL);
	avl_create(&rl->rl_tree, zfs_rangelock2_compare,
	    sizeof (zfs_locked_range2_t), offsetof(zfs_locked_range2_t,
	    lr_node));
}

void
zfs_rangelock2_fini(zfs_rangelock_t *rl)
{
	mutex_destroy(&rl->rl_lock);
	avl_destroy(&rl->rl_tree);
}

static zfs_locked_range2_t *
find_first_collision(avl_tree_t *tree, zfs_range_cookie_impl_t *cookie)
{
	zfs_locked_range2_t search;
	avl_index_t where;
	uint64_t off = cookie->rc_offset;
	uint64_t len = cookie->rc_length;
	search.lr_offset = off;
	search.lr_length = len;

	ASSERT3U(len, !=, 0);

	/*
	 * Look for any locks in the range.
	 */
	zfs_locked_range2_t *prev = avl_find(tree, &search, &where);
	if (prev == NULL)
		prev = avl_nearest(tree, where, AVL_BEFORE);

	/*
	 * Check the previous range for a writer lock overlap.
	 */
	if (prev && (off < prev->lr_offset + prev->lr_length))
		return (prev);

	zfs_locked_range2_t *next = avl_nearest(tree, where, AVL_AFTER);
	if (next && next->lr_offset < off + len)
		return (next);

	return (NULL);
}

/*
 * Returns B_TRUE if the lock can be taken without blocking. In the worst case,
 * this is O(tree size).
 */
static boolean_t
check_nonblock(avl_tree_t *tree, zfs_locked_range2_t *collision, uint64_t off,
    uint64_t len, zfs_rangelock_type_t type)
{
	ASSERT(collision);
	do {
		if (type == RL_READER) {
			if (collision->lr_writers_waiting ||
			    collision->lr_readers_held == 0) {
				return (B_FALSE);
			}
		} else {
			ASSERT3U(type, ==, RL_WRITER);
			return (B_FALSE);
		}
		collision = AVL_NEXT(tree, collision);
	} while (collision && collision->lr_offset > off + len);
	return (B_TRUE);
}

/*
 * Add to the right counters for this acquisition. Also returns if we
 * successfully got the lock.
 */
static boolean_t
acquire_lock_metrics(zfs_locked_range2_t *lock, zfs_rangelock_type_t type)
{
	if (type == RL_READER) {
		if (lock->lr_readers_waiting || lock->lr_readers_held == 0) {
			lock->lr_readers_waiting++;
		} else {
			lock->lr_readers_held++;
			return (B_TRUE);
		}
	} else {
		ASSERT3U(type, ==, RL_WRITER);
		// If the lock exists, it is held by someone. We always wait.
		lock->lr_writers_waiting++;
	}
	return (B_FALSE);
}

static zfs_locked_range2_t *
split_lock(avl_tree_t *tree, zfs_locked_range2_t *lock, uint64_t split,
    boolean_t owned)
{
	ASSERT3U(split, >, lock->lr_offset);
	ASSERT3U(split, <, lock->lr_offset + lock->lr_length);
	uint64_t new_len = lock->lr_length - (split - lock->lr_offset);
	ASSERT3U(new_len, <, lock->lr_length);
	if (!owned) {
		if (lock->lr_psl == 0) {
			lock->lr_psl = lock->lr_length;
		} else {
			ASSERT3U(lock->lr_psl, >, lock->lr_length);
		}
	}
	zfs_locked_range2_t *new = new_lock(split, new_len,
	    lock->lr_readers_held == 0 ?  RL_WRITER : RL_READER);
	new->lr_readers_held = lock->lr_readers_held;

	lock->lr_length = lock->lr_length - new_len;
	avl_insert_here(tree, new, lock, AVL_AFTER);
	return (new);
}

/*
 * Actually do the waiting on each lock in the range we're trying to acquire.
 */
static void
acquire_ranges(zfs_rangelock_t *rl, zfs_range_cookie_impl_t *cookie,
    zfs_locked_range2_t *collision)
{
	uint64_t off = cookie->rc_offset, len = cookie->rc_length;
	zfs_rangelock_type_t type = cookie->rc_type;
	avl_tree_t *tree = &rl->rl_tree;
	ASSERT3P(collision, !=, NULL);

	zfs_locked_range2_t *sleep;

	// Add a prefix lock if necessary
	if (collision->lr_offset > off) {
		zfs_locked_range2_t *new = new_lock(off,
		    collision->lr_offset - off, type);
		avl_insert_here(&rl->rl_tree, new, collision, AVL_BEFORE);
		cookie->rc_hint1 = new;
		sleep = collision;
	} else if (collision->lr_offset != off) {
		// Split the collision lock if necessary
		sleep = split_lock(tree, collision, off, B_FALSE);
		cookie->rc_hint1 = sleep;
	} else {
		sleep = collision;
		cookie->rc_hint1 = sleep;
	}

	cookie->rc_hint2 = sleep;
	uint64_t held_off = sleep->lr_offset;
	ASSERT3U(held_off, <, off + len);
	while (held_off < off + len) {
		ASSERT3U(held_off, ==, sleep->lr_offset);
		cookie->rc_hint2 = sleep;
		// Split the lock we're considering if we would end in it
		if (sleep->lr_offset + sleep->lr_length > off + len) {
			(void) split_lock(tree, sleep, off + len,
			    B_FALSE);
		}
		boolean_t acquired_fast = acquire_lock_metrics(sleep, type);
		if (!acquired_fast) {
			if (type == RL_READER) {
				cv_wait(&sleep->lr_read_cv, &rl->rl_lock);
			} else {
				ASSERT3U(type, ==, RL_WRITER);
				cv_wait(&sleep->lr_write_cv, &rl->rl_lock);
			}
		}
		zfs_locked_range2_t *next = AVL_NEXT(tree, sleep);
		uint64_t acquired_length = sleep->lr_length;
		/*
		 * If the range changed while we were asleep, but after it
		 * was given to us, iterate over all the relevant splits.
		 */
		if (sleep->lr_psl != 0 && !acquired_fast) {
			uint64_t end = sleep->lr_offset + sleep->lr_psl;
			acquired_length = sleep->lr_psl;
			ASSERT3U(next->lr_offset, <, end);
			while (next != NULL && next->lr_offset < end) {
				ASSERT3U(next->lr_offset, ==,
				    sleep->lr_offset + sleep->lr_length);
				sleep = next;
				next = AVL_NEXT(tree, sleep);
			}
			cookie->rc_hint2 = sleep;
		}
		held_off += acquired_length;
		ASSERT3U(held_off, <=, off + len);

		/*
		 * Find the next locked range, and lock anything between the one
		 * we just completed and there.
		 */
		uint64_t next_start =
		    next == NULL ? UINT64_MAX : next->lr_offset;
		if (next_start > held_off) {
			uint64_t end = MIN(next_start, off + len);
			if (end == held_off)
				continue;
			zfs_locked_range2_t *new = new_lock(held_off,
			    end - held_off, type);
			avl_insert_here(&rl->rl_tree, new, sleep, AVL_AFTER);
			held_off = end;
			cookie->rc_hint2 = new;
		}
		sleep = next;
	}
	ASSERT3U(held_off, ==, cookie->rc_offset + cookie->rc_length);
}

/*
 * Lock a range (offset, length) as either shared (RL_READER) or exclusive
 * (RL_WRITER).  Returns the range lock structure for later unlocking (or
 * reduce range if the entire file is locked as RL_WRITER), or NULL if nonblock
 * is true and the lock could not be acquired immediately.
 */
static zfs_range_cookie_t *
zfs_rangelock_enter_impl(zfs_rangelock_t *rl, uint64_t off, uint64_t len,
    zfs_rangelock_type_t type, boolean_t nonblock)
{
	zfs_range_cookie_impl_t *cookie;
	avl_tree_t *tree = &rl->rl_tree;

	ASSERT(type == RL_READER || type == RL_WRITER);

	cookie = kmem_alloc(sizeof (zfs_range_cookie_impl_t), KM_SLEEP);
	cookie->rc_rangelock = rl;
	cookie->rc_offset = off;
	if (len + off < off)	/* overflow */
		len = UINT64_MAX - off;
	cookie->rc_length = len;
	cookie->rc_type = type;
	cookie->rc_hint1 = cookie->rc_hint2 = NULL;

	// This can apparently happen, so just short circuit it.
	if (len == 0)
		return (cookie);

	mutex_enter(&rl->rl_lock);
	/*
	 * First, check the fast case where there are no other locks.
	 */
	if (avl_numnodes(&rl->rl_tree) == 0) {
		zfs_locked_range2_t *new = new_lock_from_cookie(cookie);
		avl_add(&rl->rl_tree, new);
		mutex_exit(&rl->rl_lock);
		return (cookie);
	}

	zfs_locked_range2_t *collision = find_first_collision(tree, cookie);
	if (collision == NULL) {
		/*
		 * In this case, there is no lock that overlaps with us. We
		 * can just do the fast case and return success.
		 */
		zfs_locked_range2_t *new = new_lock_from_cookie(cookie);
		avl_add(&rl->rl_tree, new);
		mutex_exit(&rl->rl_lock);
		return (cookie);
	}

	// Handle the non-blocking case
	if (nonblock && check_nonblock(tree, collision, off, len, type)) {
		mutex_exit(&rl->rl_lock);
		kmem_free(cookie, sizeof (*cookie));
		return (NULL);
	}

	acquire_ranges(rl, cookie, collision);

	mutex_exit(&rl->rl_lock);
	return (cookie);
}

zfs_range_cookie_t *
zfs_rangelock2_enter(zfs_rangelock_t *rl, uint64_t off, uint64_t len,
    zfs_rangelock_type_t type)
{
	return (zfs_rangelock_enter_impl(rl, off, len, type, B_FALSE));
}

zfs_range_cookie_t *
zfs_rangelock2_tryenter(zfs_rangelock_t *rl, uint64_t off, uint64_t len,
    zfs_rangelock_type_t type)
{
	return (zfs_rangelock_enter_impl(rl, off, len, type, B_TRUE));
}

/*
 * Actually release a lock, and wake up the new owner(s). May free lock.
 */
static void
release_lock(avl_tree_t *tree, zfs_locked_range2_t *lock,
    zfs_range_cookie_impl_t *rc)
{
	if (lock->lr_readers_held == 0) {
		ASSERT3U(rc->rc_type, ==, RL_WRITER);
		/*
		 * Clear the pre-split length so the waiter will know whether
		 * it has to iterate when acquiring.
		 */
		lock->lr_psl = 0;
		if (lock->lr_readers_waiting) {
			cv_broadcast(&lock->lr_read_cv);
			/*
			 *  We transfer the count now so we reliably
			 *  know when all the readers we just woke up
			 *  have released the lock.
			 */
			lock->lr_readers_held = lock->lr_readers_waiting;
			lock->lr_readers_waiting = 0;
		} else if (lock->lr_writers_waiting) {
			cv_signal(&lock->lr_write_cv);
			lock->lr_writers_waiting--;
		} else {
			avl_remove(tree, lock);
			cv_destroy(&lock->lr_read_cv);
			cv_destroy(&lock->lr_write_cv);
			kmem_free(lock, sizeof (*lock));
		}
	} else if (--lock->lr_readers_held == 0) {
		ASSERT3U(rc->rc_type, ==, RL_READER);
		lock->lr_psl = 0;
		// READER final case
		if (lock->lr_writers_waiting) {
			cv_signal(&lock->lr_write_cv);
			lock->lr_writers_waiting--;
		} else {
			ASSERT0(lock->lr_readers_waiting);
			avl_remove(tree, lock);
			cv_destroy(&lock->lr_read_cv);
			cv_destroy(&lock->lr_write_cv);
			kmem_free(lock, sizeof (*lock));
		}
	} else {
		ASSERT3U(rc->rc_type, ==, RL_READER);
		// READER non-final case
	}
}

static void
release_range(avl_tree_t *tree, zfs_range_cookie_impl_t *rc, uint64_t off,
    uint64_t end)
{
	ASSERTF(off == rc->rc_offset || end == rc->rc_offset + rc->rc_length,
	    "%" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 "\n", off, end,
	    rc->rc_offset, rc->rc_offset + rc->rc_length);

	zfs_locked_range2_t *cur_first = rc->rc_hint1;
	zfs_locked_range2_t *cur_last = rc->rc_hint2;

	zfs_locked_range2_t search;
	avl_index_t where;

	// Find the first lock in the range we're releasing
	zfs_locked_range2_t *first_rel = NULL;
	if (off == rc->rc_offset) {
		first_rel = cur_first;
	} else {
		search.lr_offset = off;
		first_rel = avl_find(tree, &search, &where);
		if (first_rel == NULL)
			first_rel = avl_nearest(tree, where, AVL_BEFORE);
	}
	ASSERT3U(first_rel->lr_offset, <=, off);
	ASSERT3U(off, <, first_rel->lr_offset + first_rel->lr_length);

	// Split the first_rel lock if we're starting in the middle of a range
	if (first_rel->lr_offset != off) {
		zfs_locked_range2_t *new = split_lock(tree, first_rel, off,
		    B_TRUE);
		// If the whole thing was one lock, we need to update the second
		// hint to point to the newly added lock
		if (cur_last == first_rel) {
			cur_last = new;
		}
		first_rel = new;
	}

	// Find the last lock in the range we're releasing
	zfs_locked_range2_t *last_rel = NULL;
	if (end == rc->rc_offset + rc->rc_length) {
		last_rel = cur_last;
		/*
		 * Use the hint and iterate to find the actual last once,
		 * since there may have been splits since the hint was
		 * updated. Technically this makes this O(n); if this is
		 * problematic we could short circuit with something like
		 * count < highbit(avl_numnodes(tree))?
		 */
		while (end > last_rel->lr_offset + last_rel->lr_length) {
			last_rel = AVL_NEXT(tree, last_rel);
		}
		ASSERT3U(end, ==, last_rel->lr_offset + last_rel->lr_length);
	} else {
		search.lr_offset = end - 1;
		last_rel = avl_find(tree, &search, &where);
		if (last_rel == NULL)
			last_rel = avl_nearest(tree, where, AVL_BEFORE);
	}
	ASSERT3U(last_rel->lr_offset, <, end);
	ASSERT3U(end, <=, last_rel->lr_offset + last_rel->lr_length);

	// Split the last lock if we're ending in the middle of a range
	if (end < last_rel->lr_offset + last_rel->lr_length) {
		zfs_locked_range2_t *new = split_lock(tree, last_rel, end,
		    B_TRUE);
		if (cur_last == last_rel) {
			cur_last = new;
		}
	}

	zfs_locked_range2_t *new_first = off == rc->rc_offset ?
	    AVL_NEXT(tree, last_rel) : cur_first;
	zfs_locked_range2_t *new_last = end == rc->rc_offset + rc->rc_length ?
	    AVL_PREV(tree, first_rel) : cur_last;

	zfs_locked_range2_t *idx = first_rel;
	zfs_locked_range2_t *next;
	for (;;) {
		next = AVL_NEXT(tree, idx);
		release_lock(tree, idx, rc);
		if (idx == last_rel)
			break;
		idx = next;
	}

	rc->rc_hint1 = new_first;
	rc->rc_hint2 = new_last;
}

/*
 * Unlock range, waking waiters and destroying structures as necessary.
 */
void
zfs_rangelock2_exit(zfs_range_cookie_t *rc)
{
	zfs_range_cookie_impl_t *rci = rc;
	zfs_rangelock_t *rl = rci->rc_rangelock;
	if (rci->rc_length != 0) {
		mutex_enter(&rl->rl_lock);
		release_range(&rl->rl_tree, rci, rci->rc_offset,
		    rci->rc_offset + rci->rc_length);
		mutex_exit(&rl->rl_lock);
	}
	kmem_free(rci, sizeof (*rci));

}

/*
 * Reduce range from whole file to specified range.
 */
void
zfs_rangelock2_reduce(zfs_range_cookie_t *rc, uint64_t off, uint64_t len)
{
	zfs_range_cookie_impl_t *rci = rc;
	zfs_rangelock_t *rl = rci->rc_rangelock;
	uint64_t start = rci->rc_offset;
	uint64_t end = start + rci->rc_length;
	// Check that the new range is a strict subrange
	ASSERT3U(start, <=, off);
	ASSERT3U(off + len, <=, end);
	if (start == off && end == off + len)
		return;

	mutex_enter(&rl->rl_lock);
	// Release from start to off
	if (start != off) {
		release_range(&rl->rl_tree, rci, start, off);
		rci->rc_offset = off;
		rci->rc_length -= (off - start);
	}
	// Release from off + len to end
	if (end != off + len) {
		release_range(&rl->rl_tree, rci, off + len, end);
		rci->rc_length = len;
	}
	mutex_exit(&rl->rl_lock);
}

uint64_t
zfs_range_cookie_offset(zfs_range_cookie_t *rc)
{
	zfs_range_cookie_impl_t *rci = rc;
	return (rci->rc_offset);
}

uint64_t
zfs_range_cookie_length(zfs_range_cookie_t *rc)
{
	zfs_range_cookie_impl_t *rci = rc;
	return (rci->rc_length);
}

#if defined(_KERNEL)
EXPORT_SYMBOL(zfs_rangelock2_init);
EXPORT_SYMBOL(zfs_rangelock2_fini);
EXPORT_SYMBOL(zfs_rangelock2_enter);
EXPORT_SYMBOL(zfs_rangelock2_tryenter);
EXPORT_SYMBOL(zfs_rangelock2_exit);
EXPORT_SYMBOL(zfs_rangelock2_reduce);
#endif
