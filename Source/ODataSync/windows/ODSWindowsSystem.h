// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The Windows side of ODSSystem: syncing with a server, which needs
// hashes, random bytes, private files and secrets; not yet with devices
// nearby, whose pieces (an identity, the listener and client, discovery)
// say so through the same interfaces.

#pragma once
#import "../ODSSystem.h"

NS_ASSUME_NONNULL_BEGIN

// Why a peer piece is not there: devices nearby are not synced with on
// Windows yet.
FOUNDATION_EXPORT NSError *ODSSystemPeersUnavailable(void);

NS_ASSUME_NONNULL_END
