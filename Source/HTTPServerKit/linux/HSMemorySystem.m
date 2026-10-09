// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// glibc's malloc (HSMemorySystem.h).

#import "../HSMemorySystem.h"
#include <malloc.h>
#include <stdlib.h>

void HSSystemLimitArenas(void)
{
  // glibc gives a thread an arena of its own, up to eight per core, and
  // keeps what is freed in each: a server whose requests run on many
  // dispatch threads grows by what each thread once held. Two are enough
  // for a server's load.
  if (!getenv("MALLOC_ARENA_MAX")) mallopt(M_ARENA_MAX, 2);
}

void HSSystemReturnFreedMemory(void)
{
  malloc_trim(0);
}
