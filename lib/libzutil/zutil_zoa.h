/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").
 * You may not use this file except in compliance with the License.
 *
 * You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
 * or http://www.opensolaris.org/os/licensing.
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
 * Copyright (c) 2021 by Delphix. All rights reserved.
 */
#ifndef _LIBZUTIL_ZUTIL_ZOA_H_
#define	_LIBZUTIL_ZUTIL_ZOA_H_

/*
 * This specifies that this code supports all 1.X.Y and 2.X.Y versions of the
 * agent communication protocol. This should be updated as new capabilities
 * are added and supported or required.
 */
#define	AGENT_PUBLIC_PROTOCOL_VERSION ">=1.0.0, <3.0.0"

typedef enum zoa_socket {
	ZFS_PUBLIC_SOCKET,
	ZFS_ROOT_SOCKET,
} zoa_socket_t;

nvlist_t *zoa_send_recv_msg(libpc_handle_t *hdl, nvlist_t *msg,
    const char *version_req_str, zoa_socket_t zoa_sock, nvlist_t **version);
int zoa_connect_agent(libpc_handle_t *hdl, zoa_socket_t zoa_sock,
    const char *version_req_str, nvlist_t **version);

#endif /* _LIBZUTIL_ZUTIL_ZOA_H_ */
