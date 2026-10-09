// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// What a long-running server needs of the system's allocator
// (HSApplication): one implementation for each, in its own directory,
// which the build picks:
//
//   apple/   nothing: the system's allocator hands freed pages back itself
//   linux/   glibc's malloc: fewer arenas, and what they keep freed handed
//            back
//
// Private to HSApplication.

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Before the server's threads start: as few arenas as a server needs (a
// thread otherwise gets one of its own, which keeps what it once held).
// MALLOC_ARENA_MAX, when set, is the operator's, and left as it is.
FOUNDATION_EXPORT void HSSystemLimitArenas(void);
// What was freed handed back to the system (a quiet server that once
// answered a large sync would otherwise look that size for ever).
FOUNDATION_EXPORT void HSSystemReturnFreedMemory(void);

NS_ASSUME_NONNULL_END
