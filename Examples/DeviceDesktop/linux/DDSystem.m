// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// GNUstep: libqrencode's QR codes, drawn into a bitmap.

#import "../DDSystem.h"
#include <qrencode.h>

NSImage *DDSystemQRCode(NSString *text, CGFloat side)
{
  QRcode *code = QRcode_encodeString(text.UTF8String, 0, QR_ECLEVEL_M, QR_MODE_8, 1);
  if (!code) return nil;
  // A quiet zone of four modules around it, as readers want.
  int modules = code->width + 8;
  int scale = MAX(1, (int)(side / modules));
  int pixels = modules * scale;
  NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:pixels pixelsHigh:pixels
                                                               bitsPerSample:8 samplesPerPixel:1 hasAlpha:NO isPlanar:NO
                                                              colorSpaceName:NSCalibratedWhiteColorSpace bytesPerRow:pixels
                                                                bitsPerPixel:8];
  unsigned char *bytes = rep.bitmapData;
  memset(bytes, 0xff, (size_t)pixels * (size_t)pixels);
  for (int y = 0; y < code->width; y++) {
    for (int x = 0; x < code->width; x++) {
      if (!(code->data[y * code->width + x] & 1)) continue;
      for (int dy = 0; dy < scale; dy++) {
        memset(bytes + (size_t)((y + 4) * scale + dy) * (size_t)pixels + (size_t)((x + 4) * scale), 0, (size_t)scale);
      }
    }
  }
  QRcode_free(code);
  NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(pixels, pixels)];
  [image addRepresentation:rep];
  return image;
}

NSString *DDSystemPastedText(void)
{
  return [[NSPasteboard generalPasteboard] stringForType:NSStringPboardType];
}

void DDSystemCopyText(NSString *text)
{
  NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
  [pasteboard declareTypes:@[ NSStringPboardType ] owner:nil];
  [pasteboard setString:text forType:NSStringPboardType];
}

NSBezelStyle DDSystemRoundedBezel(void)
{
  return NSRoundedBezelStyle;
}

NSString *DDSystemDeviceName(void)
{
  return [NSProcessInfo processInfo].hostName;
}
