// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The Windows C runtime's heap (HSMemorySystem.h).

#import "../HSMemorySystem.h"
#include <malloc.h>

void HSSystemLimitArenas(void)
{
  // One heap for the process, with no arenas per thread: nothing to limit.
}

void HSSystemReturnFreedMemory(void)
{
  _heapmin();
}
