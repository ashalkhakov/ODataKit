// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// macOS: Core Image's QR code generator.

#import "../DDSystem.h"
#import <CoreImage/CoreImage.h>

NSImage *DDSystemQRCode(NSString *text, CGFloat side)
{
  CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
  [filter setValue:[text dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
  [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
  CIImage *code = filter.outputImage;
  if (!code || code.extent.size.width <= 0) return nil;
  CGFloat scale = floor(side / code.extent.size.width);
  CIImage *scaled = [code imageByApplyingTransform:CGAffineTransformMakeScale(MAX(scale, 1), MAX(scale, 1))];
  NSCIImageRep *rep = [NSCIImageRep imageRepWithCIImage:scaled];
  NSImage *image = [[NSImage alloc] initWithSize:rep.size];
  [image addRepresentation:rep];
  return image;
}

NSString *DDSystemPastedText(void)
{
  return [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
}

void DDSystemCopyText(NSString *text)
{
  NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
  [pasteboard clearContents];
  [pasteboard setString:text forType:NSPasteboardTypeString];
}

NSBezelStyle DDSystemRoundedBezel(void)
{
  return NSBezelStyleRounded;
}

NSString *DDSystemDeviceName(void)
{
  return [NSHost currentHost].localizedName ?: [NSProcessInfo processInfo].hostName;
}
