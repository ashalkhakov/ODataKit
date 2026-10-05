// The desktop Device app's self-test: peer sync end to end, with no
// window, against a Workbench that serves its built-in service:
//
//   DeviceDesktop --self-test http://127.0.0.1:8640/odata/
//
// Three devices of its own (instances self-test-A, -B, -C, emptied first):
// A and B sync with the Workbench and get peer tokens; A serves, B finds it
// (Bonjour) and syncs with it, taking A's change; C, with no token, pairs
// with A and syncs. Each step a line, PASS or FAIL; the exit status the
// number failed.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>

int DDRunSelfTest(NSURL *workbench);

// Peers driven from a terminal, no window (between machines, between a
// desktop and an iPhone). Each the device of -DVInstance (default: the
// app's), synced with the Workbench first, with a peer token.
//
//   DeviceDesktop --serve <workbench> [seconds]
//       serves to peers (-DVPeerPort, default 8642), printing its root,
//       its certificate's thumbprint and a pairing offer; for seconds (0,
//       the default: until stopped)
//   DeviceDesktop --sync-with <workbench> <peer root> [<thumbprint> | <offer>]
//       syncs with the peer at that root, by token; given an offer (the
//       JSON --serve prints, or a Pairing Code's text), pairs first
int DDRunServe(NSURL *workbench, NSTimeInterval seconds);
int DDRunSyncWith(NSURL *workbench, NSURL *peer, NSString *_Nullable thumbprintOrOffer);
