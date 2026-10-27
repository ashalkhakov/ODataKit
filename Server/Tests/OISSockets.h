// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The loopback sockets ois-serve-check talks to the server with: one
// implementation for each system, in its own directory, which the build
// picks:
//
//   posix/    BSD sockets (Linux, macOS)
//   windows/  Winsock

#pragma once
#import <Foundation/Foundation.h>

typedef intptr_t OISSocket;
#define OIS_NO_SOCKET ((OISSocket)-1)

// A connection to the server on 127.0.0.1:port; a read that waits longer
// than timeout seconds fails (0: never). OIS_NO_SOCKET when none.
OISSocket OISSocketToLoopback(NSUInteger port, NSTimeInterval timeout);
// As read and write: the bytes moved, 0 at the end, less on an error.
long OISSocketRead(OISSocket socket, void *buffer, size_t length);
long OISSocketWrite(OISSocket socket, const void *bytes, size_t length);
void OISSocketClose(OISSocket socket);
// A loopback port nothing listens on now.
NSUInteger OISSocketFreeLoopbackPort(void);
