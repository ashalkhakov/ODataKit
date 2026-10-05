// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "OLAppDelegate.h"

@interface OLAppDelegate ()
@property (nonatomic, strong) NSWindow *window;
@end

@implementation OLAppDelegate

// Executable name, button title, a line of what it is.
- (NSArray<NSArray<NSString *> *> *)apps
{
  return @[
    @[ @"Workbench", @"Workbench", @"Try out an OData v4 service; serve the built-in one to devices." ],
    @[ @"DeviceDesktop", @"Device", @"An offline device: synced with a Workbench, and with peers nearby." ],
  ];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
  [self installMenus];
  NSArray<NSArray<NSString *> *> *apps = [self apps];
  CGFloat width = 400, rowHeight = 64, pad = 16;
  NSRect frame = NSMakeRect(0, 0, width, pad * 2 + rowHeight * (CGFloat)apps.count);
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                 styleMask:NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
  window.title = @"OData Workbench";
  NSView *content = window.contentView;
  CGFloat y = NSMaxY(frame) - pad - rowHeight;
  for (NSUInteger i = 0; i < apps.count; i++) {
    NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(pad, y + 26, width - pad * 2, 32)];
    button.title = apps[i][1];
    button.bezelStyle = NSRoundedBezelStyle;
    button.tag = (NSInteger)i;
    button.target = self;
    button.action = @selector(launch:);
    [content addSubview:button];
    NSTextField *note = [[NSTextField alloc] initWithFrame:NSMakeRect(pad, y + 4, width - pad * 2, 18)];
    note.stringValue = apps[i][2];
    note.bezeled = NO;
    note.drawsBackground = NO;
    note.editable = NO;
    note.selectable = NO;
    note.font = [NSFont systemFontOfSize:10];
    note.textColor = [NSColor darkGrayColor];
    [content addSubview:note];
    y -= rowHeight;
  }
  [window center];
  [window makeKeyAndOrderFront:nil];
  self.window = window;
}

- (void)installMenus
{
  NSMenu *bar = [[NSMenu alloc] initWithTitle:@""];
  NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"OData Workbench" action:NULL keyEquivalent:@""];
  NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"OData Workbench"];
  [appMenu addItemWithTitle:@"About" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
  appItem.submenu = appMenu;
  [bar addItem:appItem];
  [NSApp setMainMenu:bar];
}

// The app's executable, beside this one (in the image both sit in the same
// Applications directory), else in the GNUstep application roots.
- (nullable NSString *)executableOf:(NSString *)app
{
  NSFileManager *files = [NSFileManager defaultManager];
  NSMutableArray<NSString *> *roots = [NSMutableArray arrayWithObject:[NSBundle mainBundle].bundlePath.stringByDeletingLastPathComponent];
  NSDictionary *environment = [NSProcessInfo processInfo].environment;
  for (NSString *key in @[ @"GNUSTEP_LOCAL_APPS", @"GNUSTEP_SYSTEM_APPS" ]) {
    if ([environment[key] length]) [roots addObject:environment[key]];
  }
  for (NSString *root in roots) {
    NSString *path = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.app/%@", app, app]];
    if ([files isExecutableFileAtPath:path]) return path;
  }
  return nil;
}

- (void)launch:(NSButton *)sender
{
  NSArray<NSArray<NSString *> *> *apps = [self apps];
  if (sender.tag < 0 || (NSUInteger)sender.tag >= apps.count) return;
  NSString *app = apps[(NSUInteger)sender.tag][0];
  NSString *executable = [self executableOf:app];
  if (!executable) {
    [self report:@"Application not found" detail:[NSString stringWithFormat:@"%@ is not beside this launcher.", app]];
    return;
  }
  // Started, not waited for: closing the launcher leaves the app running.
  NSTask *task = [[NSTask alloc] init];
  task.launchPath = executable;
  @try {
    [task launch];
  } @catch (NSException *problem) {
    [self report:@"The application did not start" detail:[NSString stringWithFormat:@"%@: %@", app, problem.reason]];
  }
}

- (void)report:(NSString *)message detail:(NSString *)detail
{
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = message;
  alert.informativeText = detail;
  [alert runModal];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
  return YES;
}

@end
