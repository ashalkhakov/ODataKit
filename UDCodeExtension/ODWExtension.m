// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODWExtension.h"
#import "ODWServices.h"
#import "ODWNavigatorViewController.h"
#import "ODWBottomViewController.h"
#import "ODWBuilderViewController.h"
#import <UDCodeKit/UDCodeDocument.h>
#import <UDCodeKit/UDLanguageMode.h>

@implementation ODWExtension {
  // Each window's services, and their navigators.
  NSMapTable<id, ODWServices *> *_windows;
  NSMapTable<ODWServices *, ODWNavigatorViewController *> *_navigators;
  // Each query document's builder (its tab's).
  NSMapTable<UDCodeDocument *, ODWBuilderViewController *> *_builders;
}

- (void)extensionDidLoad:(NSBundle *)bundle
{
  (void)bundle;
  _windows = [NSMapTable weakToStrongObjectsMapTable];
  _navigators = [NSMapTable weakToStrongObjectsMapTable];
}

- (void)extensionWillUnload:(NSBundle *)bundle
{
  (void)bundle;
  _windows = nil;
  _navigators = nil;
}

// .odata documents are text (no grammar of their own): their mode is
// LanguageInfo.plist's.
- (const void *)languageFuncForIdentifier:(NSString *)identifier
{
  (void)identifier;
  return NULL;
}

- (ODWServices *)servicesOf:(id<UDWorkbench>)workbench
{
  if (!_windows) _windows = [NSMapTable weakToStrongObjectsMapTable];
  if (!_navigators) _navigators = [NSMapTable weakToStrongObjectsMapTable];
  ODWServices *services = [_windows objectForKey:workbench];
  if (!services) {
    services = [[ODWServices alloc] initWithWorkbench:workbench];
    services.extension = self;
    services.bottomPane = [[ODWBottomViewController alloc] initWithServices:services];
    [_windows setObject:services forKey:workbench];
  }
  return services;
}

- (ODWNavigatorViewController *)navigatorOf:(id<UDWorkbench>)workbench
{
  ODWServices *services = [self servicesOf:workbench];
  ODWNavigatorViewController *navigator = [_navigators objectForKey:services];
  if (!navigator) {
    navigator = [[ODWNavigatorViewController alloc] initWithServices:services];
    [_navigators setObject:navigator forKey:services];
  }
  return navigator;
}

- (NSViewController *)navigatorViewControllerForWorkbench:(id<UDWorkbench>)workbench
{
  return [self navigatorOf:workbench];
}

// The navigator's segment: a service's globe; the bottom area's: a request
// and its answer, an arrow each way.
- (NSImage *)navigatorImage
{
  NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
  [image lockFocus];
  [[NSColor colorWithCalibratedWhite:0.3 alpha:1] setStroke];
  NSBezierPath *globe = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(2, 2, 12, 12)];
  [globe appendBezierPathWithOvalInRect:NSMakeRect(5.5, 2, 5, 12)];
  [globe moveToPoint:NSMakePoint(2, 8)];
  [globe lineToPoint:NSMakePoint(14, 8)];
  globe.lineWidth = 1.1;
  [globe stroke];
  [image unlockFocus];
  [image setTemplate:YES];
  return image;
}

- (NSImage *)bottomAreaImage
{
  NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
  [image lockFocus];
  [[NSColor colorWithCalibratedWhite:0.3 alpha:1] setStroke];
  NSBezierPath *arrows = [NSBezierPath bezierPath];
  arrows.lineWidth = 1.2;
  arrows.lineCapStyle = NSLineCapStyleRound;
  arrows.lineJoinStyle = NSLineJoinStyleRound;
  // → above, ← below
  [arrows moveToPoint:NSMakePoint(2, 11)];
  [arrows lineToPoint:NSMakePoint(13, 11)];
  [arrows moveToPoint:NSMakePoint(10, 13.5)];
  [arrows lineToPoint:NSMakePoint(13, 11)];
  [arrows lineToPoint:NSMakePoint(10, 8.5)];
  [arrows moveToPoint:NSMakePoint(14, 5)];
  [arrows lineToPoint:NSMakePoint(3, 5)];
  [arrows moveToPoint:NSMakePoint(6, 7.5)];
  [arrows lineToPoint:NSMakePoint(3, 5)];
  [arrows lineToPoint:NSMakePoint(6, 2.5)];
  [arrows stroke];
  [image unlockFocus];
  [image setTemplate:YES];
  return image;
}

// An .odataq document's own editor: the query builder (its text the
// query's JSON, still shown as text by View > Open as Text).
- (NSViewController *)workbench:(id<UDWorkbench>)workbench editorForDocument:(UDCodeDocument *)document
{
  if (![document.languageMode.identifier isEqualToString:@"odataq"]) return nil;
  ODWBuilderViewController *builder = [[ODWBuilderViewController alloc] initWithServices:[self servicesOf:workbench] document:document];
  if (!_builders) _builders = [NSMapTable weakToWeakObjectsMapTable];
  [_builders setObject:builder forKey:document];
  return builder;
}

// UDCode's Editor > Run (⌘↩) and Run All (⇧⌘↩): an .odata document's
// request at the caret, or all of them, sent to its service; a query
// document's GET, its builder's.
- (BOOL)workbench:(id<UDWorkbench>)workbench canRunDocument:(UDCodeDocument *)document
{
  return [ODWServices isRequestDocument:document] || [_builders objectForKey:document] != nil;
}

- (void)workbench:(id<UDWorkbench>)workbench runDocument:(UDCodeDocument *)document selection:(NSRange)selection all:(BOOL)all
{
  ODWBuilderViewController *builder = [_builders objectForKey:document];
  if (builder) [builder runFetch:nil];
  else [[self servicesOf:workbench] sendRequestsOfDocument:document selection:selection all:all];
}

@end
