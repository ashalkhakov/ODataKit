// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "DVSession.h"

NSNotificationName const DVSessionDidChangeNotification = @"DVSessionDidChange";
NSNotificationName const DVSessionDidLogNotification = @"DVSessionDidLog";

static NSString * const DVRootKey = @"DVServiceRoot";
static NSString * const DVRuleKey = @"DVRule";
static NSString * const DVOfflineKey = @"DVOffline";
static NSString * const DVSyncsEachChangeKey = @"DVSyncsEachChange";

@implementation DVSession

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _status = @"Set the Workbench's address in Settings.";
  NSString *root = [[NSUserDefaults standardUserDefaults] stringForKey:DVRootKey];
  if (root.length) [self openDeviceAt:[NSURL URLWithString:root] emptied:NO];
  return self;
}

// In Application Support: the device's data stays across launches.
- (NSURL *)storeURL
{
  NSURL *support = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
  NSURL *directory = [support URLByAppendingPathComponent:@"Device" isDirectory:YES];
  [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL];
  return [directory URLByAppendingPathComponent:@"Device.sqlite"];
}

- (void)removeStore
{
  NSString *path = [self storeURL].path;
  for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) {
    [[NSFileManager defaultManager] removeItemAtPath:[path stringByAppendingString:suffix] error:NULL];
  }
}

- (void)openDeviceAt:(NSURL *)root emptied:(BOOL)emptied
{
  NSURL *model = [[NSBundle mainBundle] URLForResource:@"Catalog" withExtension:@"momd"];
  // The old device lets go of the store first; its peers, of the network
  // (and, emptied, of its identity: the new device is another replica).
  [_peers stop];
  if (emptied) [_peers discard];
  _peers = nil;
  _device.didChange = nil;
  _device.didLog = nil;
  _device = nil;
  if (emptied) [self removeStore];
  _device = model ? [[WorkbenchDevice alloc] initWithModelURL:model serviceRoot:root transport:ODataDefaultTransport() storeURL:[self storeURL]] : nil;
  if (!_device && !emptied) {
    // A store an older build made: start again.
    [self removeStore];
    _device = model ? [[WorkbenchDevice alloc] initWithModelURL:model serviceRoot:root transport:ODataDefaultTransport() storeURL:[self storeURL]] : nil;
  }
  _serviceRoot = _device ? [root copy] : nil;
  if (!_device) {
    [self say:@"The device's store does not open."];
    return;
  }
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  _device.rule = (WBSyncRule)[defaults integerForKey:DVRuleKey];
  _device.offline = [defaults boolForKey:DVOfflineKey];
  _device.syncsEachChange = [defaults boolForKey:DVSyncsEachChangeKey];
  __weak DVSession *weak = self;
  _device.didChange = ^(NSString *status) {
    [weak say:status];
  };
  _device.didLog = ^(WorkbenchLogEntry *entry) {
    [[NSNotificationCenter defaultCenter] postNotificationName:DVSessionDidLogNotification object:weak userInfo:@{ @"entry": entry }];
  };
  NSError *error = nil;
  NSURL *directory = [[self storeURL].URLByDeletingLastPathComponent URLByAppendingPathComponent:@"Peers" isDirectory:YES];
  _peers = [[DVPeers alloc] initWithDevice:_device directory:directory error:&error];
  _peers.say = ^(NSString *status) {
    [weak say:status];
  };
  if (!_peers) {
    [self say:[NSString stringWithFormat:@"No peers: the device's identity is not made (%@).", error.localizedDescription]];
    return;
  }
  [self say:emptied ? @"A new device: Sync reads the Workbench's data into it." : @"Sync to meet the Workbench's changes."];
}

- (void)say:(NSString *)status
{
  _status = [status copy];
  [[NSNotificationCenter defaultCenter] postNotificationName:DVSessionDidChangeNotification object:self userInfo:@{ @"status": _status }];
}

- (NSString *)useServiceRoot:(NSString *)text
{
  NSString *typed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (typed.length && ![typed hasSuffix:@"/"]) typed = [typed stringByAppendingString:@"/"];
  NSURL *root = [NSURL URLWithString:typed];
  if (!root.host.length || !([root.scheme isEqualToString:@"http"] || [root.scheme isEqualToString:@"https"])) {
    return @"That is not a service root (http://192.168.1.10:8640/odata/).";
  }
  if ([root isEqual:_serviceRoot]) return nil;
  if (_device.busy) return @"Still syncing.";
  if (_peers.busy) return @"Still pairing, or getting a peer token.";
  [[NSUserDefaults standardUserDefaults] setObject:root.absoluteString forKey:DVRootKey];
  [self openDeviceAt:root emptied:YES];
  return _device ? nil : _status;
}

- (WBSyncRule)rule
{
  return (WBSyncRule)[[NSUserDefaults standardUserDefaults] integerForKey:DVRuleKey];
}

- (void)setRule:(WBSyncRule)rule
{
  [[NSUserDefaults standardUserDefaults] setInteger:rule forKey:DVRuleKey];
  _device.rule = rule;
  [self say:[NSString stringWithFormat:@"Conflicts: %@.", WBSyncRuleTitles()[(NSUInteger)rule].lowercaseString]];
}

- (BOOL)isOffline
{
  return [[NSUserDefaults standardUserDefaults] boolForKey:DVOfflineKey];
}

- (void)setOffline:(BOOL)offline
{
  [[NSUserDefaults standardUserDefaults] setBool:offline forKey:DVOfflineKey];
  _device.offline = offline;
  [self say:offline ? @"Offline: change things on the device; they wait, and go when it is back." : @"Back online: Sync sends what waits."];
}

- (BOOL)syncsEachChange
{
  return [[NSUserDefaults standardUserDefaults] boolForKey:DVSyncsEachChangeKey];
}

- (void)setSyncsEachChange:(BOOL)syncsEachChange
{
  [[NSUserDefaults standardUserDefaults] setBool:syncsEachChange forKey:DVSyncsEachChangeKey];
  _device.syncsEachChange = syncsEachChange;
  [self say:syncsEachChange ? @"Each change is synced at once." : @"Changes wait for Sync (or Upload)."];
}

- (void)resetDevice
{
  if (!_serviceRoot || _device.busy) return;
  if (_peers.busy) {
    [self say:@"Still pairing, or getting a peer token: reset when it is done."];
    return;
  }
  [self openDeviceAt:_serviceRoot emptied:YES];
}

@end
