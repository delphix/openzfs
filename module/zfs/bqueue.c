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
 * Copyright (c) 2014, 2018 by Delphix. All rights reserved.
 */

#include	<sys/bqueue.h>
#include	<sys/zfs_context.h>

static inline bqueue_node_t *
obj2node(bqueue_t *q, void *data)
{
	return ((bqueue_node_t *)((char *)data + q->bq_node_offset));
}

/*
 * Initialize a blocking queue  The maximum capacity of the queue is set to
 * size.  Types that are stored in a bqueue must contain a bqueue_node_t,
 * and node_offset must be its offset from the start of the struct.
 * fill_fraction is a performance tuning value; when the queue is full, any
 * threads attempting to enqueue records will block.  They will block
 * until they're signaled, which will occur when the queue is at least
 * 1/fill_fraction empty.  Similar behavior occurs on dequeue; if the queue
 * is empty, threads block.  They will be signalled when the queue has
 * 1/fill_fraction full, or when bqueue_flush is called.  As a result, you
 * must call bqueue_enqueue_flush() when you enqueue your final record on a
 * thread, in case the dequeueing threads are currently blocked and that
 * enqueue does not cause them to be awoken. Alternatively, this behavior can
 * be disabled (causing signaling to happen immediately) by setting
 * fill_fraction to any value larger than size. Return 0 on success, or -1
 * on failure.
 *
 * NOTE: the framework does not provide protection for concurrent access
 * to the enquing and dequing lists. Consumers of the framework need to
 * ensure the necessary locking is used if multiple threads are required
 * to enqueue or dequeue concurrently (Consumers may enqueue and dequeue
 * (and vice-versa) concurrently).
 */
int
bqueue_init(bqueue_t *q, uint_t fill_fraction, size_t size, size_t node_offset)
{
	if (fill_fraction == 0) {
		return (-1);
	}
	list_create(&q->bq_list, node_offset + sizeof (bqueue_node_t),
	    node_offset + offsetof(bqueue_node_t, bqn_node));
	list_create(&q->bq_deqing_list, node_offset + sizeof (bqueue_node_t),
	    node_offset + offsetof(bqueue_node_t, bqn_node));
	list_create(&q->bq_enqing_list, node_offset + sizeof (bqueue_node_t),
	    node_offset + offsetof(bqueue_node_t, bqn_node));
	cv_init(&q->bq_add_cv, NULL, CV_DEFAULT, NULL);
	cv_init(&q->bq_pop_cv, NULL, CV_DEFAULT, NULL);
	mutex_init(&q->bq_lock, NULL, MUTEX_DEFAULT, NULL);
	q->bq_node_offset = node_offset;
	q->bq_size = 0;
	q->bq_deqing_size = 0;
	q->bq_enqing_size = 0;
	q->bq_maxsize = size;
	q->bq_fill_fraction = fill_fraction;
	return (0);
}

/*
 * Destroy a blocking queue.  This function asserts that there are no
 * elements in the queue, and no one is blocked on the condition
 * variables.
 */
void
bqueue_destroy(bqueue_t *q)
{
	mutex_enter(&q->bq_lock);
	ASSERT0(q->bq_size);
	ASSERT0(q->bq_deqing_size);
	ASSERT0(q->bq_enqing_size);
	cv_destroy(&q->bq_add_cv);
	cv_destroy(&q->bq_pop_cv);
	list_destroy(&q->bq_list);
	list_destroy(&q->bq_deqing_list);
	list_destroy(&q->bq_enqing_list);
	mutex_exit(&q->bq_lock);
	mutex_destroy(&q->bq_lock);
}

static void
bqueue_enqueue_impl(bqueue_t *q, void *data, size_t item_size, boolean_t flush)
{
	ASSERT3U(item_size, >, 0);
	ASSERT3U(item_size, <=, q->bq_maxsize);

	obj2node(q, data)->bqn_size = item_size;
	q->bq_enqing_size += item_size;
	list_insert_tail(&q->bq_enqing_list, data);

	if (flush ||
	    q->bq_enqing_size >= q->bq_maxsize / q->bq_fill_fraction) {
		mutex_enter(&q->bq_lock);
		while (q->bq_size > q->bq_maxsize) {
			cv_wait_sig(&q->bq_add_cv, &q->bq_lock);
		}
		q->bq_size += q->bq_enqing_size;
		list_move_tail(&q->bq_list, &q->bq_enqing_list);
		q->bq_enqing_size = 0;
		cv_broadcast(&q->bq_pop_cv);
		mutex_exit(&q->bq_lock);
	}
}

/*
 * Add data to q, consuming size units of capacity.  If there is insufficient
 * capacity to consume size units, block until capacity exists.  Asserts size is
 * > 0.
 */
void
bqueue_enqueue(bqueue_t *q, void *data, size_t item_size)
{
	bqueue_enqueue_impl(q, data, item_size, B_FALSE);
}

/*
 * Enqueue an entry, and then flush the queue.  This forces the popping threads
 * to wake up, even if we're below the fill fraction.  We have this in a single
 * function, rather than having a separate call, because it prevents race
 * conditions between the enqueuing thread and the dequeueing thread, where the
 * enqueueing thread will wake up the dequeueing thread, that thread will
 * destroy the condvar before the enqueuing thread is done.
 */
void
bqueue_enqueue_flush(bqueue_t *q, void *data, size_t item_size)
{
	bqueue_enqueue_impl(q, data, item_size, B_TRUE);
}

/*
 * Take the first element off of q.  If there are no elements on the queue, wait
 * until one is put there.  Return the removed element.
 */
void *
bqueue_dequeue(bqueue_t *q)
{
	void *ret = list_remove_head(&q->bq_deqing_list);
	if (ret == NULL) {
		mutex_enter(&q->bq_lock);
		while (q->bq_size == 0) {
			cv_wait_sig(&q->bq_pop_cv, &q->bq_lock);
		}
		ASSERT0(q->bq_deqing_size);
		ASSERT(list_is_empty(&q->bq_deqing_list));
		list_move_tail(&q->bq_deqing_list, &q->bq_list);
		q->bq_deqing_size = q->bq_size;
		q->bq_size = 0;
		cv_broadcast(&q->bq_add_cv);
		mutex_exit(&q->bq_lock);
		ret = list_remove_head(&q->bq_deqing_list);
	}
	q->bq_deqing_size -= obj2node(q, ret)->bqn_size;
	return (ret);
}
