// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// OISSockets.h on Winsock: started once; recv, send and closesocket on a
// socket (not read, write and close, which are a file's); a receive
// timeout in milliseconds.

#import "../OISSockets.h"
#include <winsock2.h>
#include <ws2tcpip.h>

static void OISSocketsStart(void)
{
  static BOOL started = NO;
  if (started) return;
  WSADATA data;
  WSAStartup(MAKEWORD(2, 2), &data);
  started = YES;
}

OISSocket OISSocketToLoopback(NSUInteger port, NSTimeInterval timeout)
{
  OISSocketsStart();
  SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (s == INVALID_SOCKET) return OIS_NO_SOCKET;
  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_port = htons((u_short)port);
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(s, (struct sockaddr *)&address, sizeof(address)) != 0) {
    closesocket(s);
    return OIS_NO_SOCKET;
  }
  if (timeout > 0) {
    DWORD wait = (DWORD)(timeout * 1000);
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&wait, sizeof(wait));
  }
  return (OISSocket)s;
}

long OISSocketRead(OISSocket socket, void *buffer, size_t length)
{
  return recv((SOCKET)socket, buffer, (int)MIN(length, (size_t)INT_MAX), 0);
}

long OISSocketWrite(OISSocket socket, const void *bytes, size_t length)
{
  return send((SOCKET)socket, bytes, (int)MIN(length, (size_t)INT_MAX), 0);
}

void OISSocketClose(OISSocket socket)
{
  closesocket((SOCKET)socket);
}

NSUInteger OISSocketFreeLoopbackPort(void)
{
  OISSocketsStart();
  SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  int length = sizeof(address);
  NSUInteger free = 0;
  if (bind(s, (struct sockaddr *)&address, sizeof(address)) == 0 && getsockname(s, (struct sockaddr *)&address, &length) == 0) {
    free = ntohs(address.sin_port);
  }
  closesocket(s);
  return free;
}
