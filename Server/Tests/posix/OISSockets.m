// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// OISSockets.h on BSD sockets.

#import "../OISSockets.h"
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

OISSocket OISSocketToLoopback(NSUInteger port, NSTimeInterval timeout)
{
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return OIS_NO_SOCKET;
  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_port = htons((uint16_t)port);
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
    close(fd);
    return OIS_NO_SOCKET;
  }
  if (timeout > 0) {
    struct timeval wait = { (time_t)timeout, (suseconds_t)((timeout - (time_t)timeout) * 1e6) };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof(wait));
  }
  return fd;
}

long OISSocketRead(OISSocket socket, void *buffer, size_t length)
{
  return (long)read((int)socket, buffer, length);
}

long OISSocketWrite(OISSocket socket, const void *bytes, size_t length)
{
  return (long)write((int)socket, bytes, length);
}

void OISSocketClose(OISSocket socket)
{
  close((int)socket);
}

NSUInteger OISSocketFreeLoopbackPort(void)
{
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  socklen_t length = sizeof(address);
  NSUInteger free = 0;
  if (bind(fd, (struct sockaddr *)&address, sizeof(address)) == 0 && getsockname(fd, (struct sockaddr *)&address, &length) == 0) {
    free = ntohs(address.sin_port);
  }
  close(fd);
  return free;
}
