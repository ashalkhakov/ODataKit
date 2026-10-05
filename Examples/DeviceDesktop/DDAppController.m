// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "DDAppController.h"
#import "DDPeersWindow.h"
#import "DDSystem.h"
#import "DVSession.h"
#import "WBSync.h"

@implementation DDAppController {
  DVSession *_session;
  WBSyncWindow *_deviceWindow;
  DDPeersWindow *_peersWindow;
  NSWindow *_addressWindow;
  NSTextField *_addressField;
  NSTextField *_addressStatus;
}

#pragma mark Starting

- (void)start
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSString *instance = [defaults stringForKey:@"DVInstance"];
  _session = [[DVSession alloc] initWithInstance:instance];
  _session.deviceName = instance.length ? [NSString stringWithFormat:@"%@ (%@)", DDSystemDeviceName(), instance] : DDSystemDeviceName();
  NSInteger port = [defaults integerForKey:@"DVPeerPort"];
  if (port > 0 && port < 65536) _session.peerPort = (NSUInteger)port;
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center addObserver:self selector:@selector(sessionChanged:) name:DVSessionDidChangeNotification object:_session];
  [center addObserver:self selector:@selector(sessionLogged:) name:DVSessionDidLogNotification object:_session];
  [self makeMenus];
  _peersWindow = [[DDPeersWindow alloc] initWithSession:_session];
  [self showDevice];
  if (_session.device) {
    // Opened: the Workbench's changes met, what waits sent.
    if (!_session.device.offline) [_session.device run:WBSyncActionSync];
  } else {
    [self askForAddress:nil];
  }
}

- (NSString *)title:(NSString *)what
{
  NSString *instance = _session.instance;
  return instance ? [NSString stringWithFormat:@"%@ (%@)", what, instance] : what;
}

// The device's window, over the session's device (a new one: shown anew).
- (void)showDevice
{
  WorkbenchDevice *device = _session.device;
  if (!device) {
    [_deviceWindow.window orderOut:nil];
    return;
  }
  if (!_deviceWindow) {
    _deviceWindow = [[WBSyncWindow alloc] initWithDevice:device engine:nil];
    __weak DDAppController *weak = self;
    _deviceWindow.resetsDevice = ^{
      [weak resetDevice:nil];
    };
    _deviceWindow.didChangeSetting = ^{
      [weak settingChanged];
    };
  } else if (_deviceWindow.device != device) {
    _deviceWindow.device = device;
  }
  _deviceWindow.window.title = [self title:[@"OIS Device: " stringByAppendingString:_session.serviceRoot.absoluteString ?: @""]];
  [_deviceWindow show];
}

- (void)sessionChanged:(NSNotification *)notification
{
  if (_deviceWindow && _deviceWindow.device != _session.device) [self showDevice];
  [_deviceWindow changed:notification.userInfo[@"status"] ?: @""];
}

- (void)sessionLogged:(NSNotification *)notification
{
  [_deviceWindow logged:notification.userInfo[@"entry"]];
}

// The device window's switches, kept across launches (the session's).
- (void)settingChanged
{
  WorkbenchDevice *device = _session.device;
  if (_session.rule != device.rule) _session.rule = device.rule;
  if (_session.offline != device.offline) _session.offline = device.offline;
  if (_session.syncsEachChange != device.syncsEachChange) _session.syncsEachChange = device.syncsEachChange;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
  return NO;
}

#pragma mark Menus

- (NSMenuItem *)item:(NSString *)title action:(SEL)action key:(NSString *)key
{
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
  item.target = self;
  return item;
}

- (void)makeMenus
{
  NSMenu *bar = [[NSMenu alloc] initWithTitle:@"OIS Device"];
  NSMenu *app = [[NSMenu alloc] initWithTitle:@"OIS Device"];
  NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit OIS Device" action:@selector(terminate:) keyEquivalent:@"q"];
  [app addItem:quit];
  NSMenu *device = [[NSMenu alloc] initWithTitle:@"Device"];
  [device addItem:[self item:@"Workbench Address…" action:@selector(askForAddress:) key:@"l"]];
  [device addItem:[self item:@"Sync" action:@selector(sync:) key:@"r"]];
  [device addItem:[NSMenuItem separatorItem]];
  [device addItem:[self item:@"Reset Device…" action:@selector(resetDevice:) key:@""]];
  NSMenu *window = [[NSMenu alloc] initWithTitle:@"Window"];
  [window addItem:[self item:@"Device" action:@selector(showDeviceWindow:) key:@"1"]];
  [window addItem:[self item:@"Peers" action:@selector(showPeers:) key:@"2"]];
  for (NSMenu *menu in @[ app, device, window ]) {
    NSMenuItem *holder = [[NSMenuItem alloc] initWithTitle:menu.title action:NULL keyEquivalent:@""];
    holder.submenu = menu;
    [bar addItem:holder];
  }
  [NSApp setMainMenu:bar];
}

- (IBAction)showDeviceWindow:(id)sender
{
  if (_session.device) [self showDevice];
  else [self askForAddress:nil];
}

- (IBAction)showPeers:(id)sender
{
  [_peersWindow show];
}

- (IBAction)sync:(id)sender
{
  [_session.device run:WBSyncActionSync];
}

- (IBAction)resetDevice:(id)sender
{
  if (!_session.device) return;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Reset the device?";
  alert.informativeText = @"Its data, what waits to be sent, its peer token and its pairings are removed: a new device, which Sync fills again.";
  [alert addButtonWithTitle:@"Reset"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] != NSAlertFirstButtonReturn) return;
  [_session resetDevice];
  [self showDevice];
  [_peersWindow reload];
}

#pragma mark The Workbench's address

- (void)makeAddressWindow
{
  _addressWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(300, 400, 520, 150)
                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                 backing:NSBackingStoreBuffered defer:YES];
  _addressWindow.title = [self title:@"The Workbench's Address"];
  _addressWindow.releasedWhenClosed = NO;
  NSView *content = _addressWindow.contentView;
  NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 108, 488, 20)];
  label.stringValue = @"On the Mac or PC, in the Workbench: Sync > Serve on the Network shows it.";
  label.editable = NO;
  label.bordered = NO;
  label.drawsBackground = NO;
  _addressField = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 74, 488, 24)];
  _addressField.stringValue = _session.serviceRoot.absoluteString ?: @"http://";
  _addressStatus = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 46, 488, 20)];
  _addressStatus.editable = NO;
  _addressStatus.bordered = NO;
  _addressStatus.drawsBackground = NO;
  _addressStatus.stringValue = @"A new address is a new device: what it holds is read again.";
  NSButton *use = [[NSButton alloc] initWithFrame:NSMakeRect(404, 10, 100, 28)];
  use.title = @"Use";
  use.bezelStyle = DDSystemRoundedBezel();
  use.keyEquivalent = @"\r";
  use.target = self;
  use.action = @selector(useAddress:);
  NSButton *cancel = [[NSButton alloc] initWithFrame:NSMakeRect(296, 10, 100, 28)];
  cancel.title = @"Cancel";
  cancel.bezelStyle = DDSystemRoundedBezel();
  cancel.target = _addressWindow;
  cancel.action = @selector(performClose:);
  for (NSView *view in @[ label, _addressField, _addressStatus, use, cancel ]) [content addSubview:view];
}

- (IBAction)askForAddress:(id)sender
{
  if (!_addressWindow) [self makeAddressWindow];
  _addressField.stringValue = _session.serviceRoot.absoluteString ?: @"http://";
  [_addressWindow makeKeyAndOrderFront:nil];
  [_addressWindow makeFirstResponder:_addressField];
}

- (IBAction)useAddress:(id)sender
{
  NSString *why = [_session useServiceRoot:_addressField.stringValue];
  if (why) {
    _addressStatus.stringValue = why;
    return;
  }
  [_addressWindow orderOut:nil];
  [self showDevice];
  [_peersWindow reload];
  if (_session.device && !_session.device.offline) [_session.device run:WBSyncActionSync];
}

@end
