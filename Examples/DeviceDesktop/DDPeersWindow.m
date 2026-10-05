// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "DDPeersWindow.h"
#import "DDSystem.h"

static NSString *DDShortDate(NSDate *date)
{
  return [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
}

@implementation DDPeersWindow {
  NSTextField *_tokenField;
  NSButton *_tokenButton;
  NSButton *_serveButton;
  NSTextField *_rootField;
  NSButton *_offerButton;
  NSImageView *_codeView;
  NSTextView *_offerView;
  NSTextField *_expiresField;
  NSButton *_copyButton;
  NSTextField *_pairField;
  NSButton *_pairButton;
  NSTableView *_nearbyTable;
  NSTableView *_pairedTable;
  NSButton *_syncButton;
  NSButton *_forgetButton;
  NSTextField *_statusField;
  NSString *_offer;
  NSDate *_offerExpires;
  NSTimer *_tick;
}

- (instancetype)initWithSession:(DVSession *)session
{
  self = [super init];
  if (!self) return nil;
  _session = session;
  [self makeWindow];
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center addObserver:self selector:@selector(peersChanged:) name:DVPeersDidChangeNotification object:nil];
  [center addObserver:self selector:@selector(sessionChanged:) name:DVSessionDidChangeNotification object:session];
  return self;
}

- (void)dealloc
{
  [_tick invalidate];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (DVPeers *)peers
{
  return _session.peers;
}

#pragma mark The window

- (NSTextField *)labelWithFrame:(NSRect)frame text:(NSString *)text
{
  NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
  label.stringValue = text;
  label.editable = NO;
  label.selectable = NO;
  label.bordered = NO;
  label.drawsBackground = NO;
  return label;
}

- (NSButton *)buttonWithFrame:(NSRect)frame title:(NSString *)title action:(SEL)action
{
  NSButton *button = [[NSButton alloc] initWithFrame:frame];
  button.title = title;
  button.bezelStyle = DDSystemRoundedBezel();
  button.target = self;
  button.action = action;
  return button;
}

- (NSTableView *)tableWithColumns:(NSArray<NSArray *> *)columns frame:(NSRect)frame
{
  NSTableView *table = [[NSTableView alloc] initWithFrame:frame];
  for (NSArray *spec in columns) {
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
    [column.headerCell setStringValue:spec[1]];
    column.width = [spec[2] doubleValue];
    column.editable = NO;
    [table addTableColumn:column];
  }
  table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
  table.dataSource = self;
  table.delegate = self;
  table.allowsEmptySelection = YES;
  return table;
}

- (NSScrollView *)scrollViewFor:(NSView *)document frame:(NSRect)frame
{
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:frame];
  scroll.hasVerticalScroller = YES;
  scroll.autohidesScrollers = YES;
  scroll.borderType = NSBezelBorder;
  scroll.documentView = document;
  return scroll;
}

// Laid out by frames, top down (GNUstep's AppKit and Apple's alike).
- (void)makeWindow
{
  CGFloat width = 760, height = 640;
  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(220, 140, width, height)
                                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                                                  NSWindowStyleMaskMiniaturizable
                                          backing:NSBackingStoreBuffered defer:YES];
  _window.title = @"Peers";
  _window.releasedWhenClosed = NO;
  _window.minSize = NSMakeSize(640, 560);
  NSView *content = _window.contentView;
  CGFloat y = height - 36;

  // This device: its token, serving.
  NSTextField *token = [self labelWithFrame:NSMakeRect(12, y + 4, 90, 20) text:@"Peer token:"];
  _tokenField = [self labelWithFrame:NSMakeRect(104, y + 4, width - 290, 20) text:@""];
  _tokenButton = [self buttonWithFrame:NSMakeRect(width - 176, y, 164, 28) title:@"Get a Peer Token" action:@selector(fetchToken:)];
  _tokenButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
  for (NSView *view in @[ token, _tokenField ]) view.autoresizingMask = NSViewMinYMargin;
  _tokenField.autoresizingMask = NSViewMinYMargin | NSViewWidthSizable;
  y -= 34;
  _serveButton = [[NSButton alloc] initWithFrame:NSMakeRect(12, y + 4, 140, 22)];
  [_serveButton setButtonType:NSSwitchButton];
  _serveButton.title = @"Serve to peers";
  _serveButton.target = self;
  _serveButton.action = @selector(serveChanged:);
  _rootField = [self labelWithFrame:NSMakeRect(156, y + 4, width - 340, 20) text:@""];
  _rootField.selectable = YES;
  _offerButton = [self buttonWithFrame:NSMakeRect(width - 176, y, 164, 28) title:@"Show Pairing Code" action:@selector(showOffer:)];
  _offerButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
  _serveButton.autoresizingMask = NSViewMinYMargin;
  _rootField.autoresizingMask = NSViewMinYMargin | NSViewWidthSizable;
  for (NSView *view in @[ token, _tokenField, _tokenButton, _serveButton, _rootField, _offerButton ]) [content addSubview:view];

  // The pairing code shown: QR, text, how long it is good for.
  y -= 172;
  _codeView = [[NSImageView alloc] initWithFrame:NSMakeRect(12, y, 160, 160)];
  _codeView.imageScaling = NSImageScaleProportionallyUpOrDown;
  _codeView.autoresizingMask = NSViewMinYMargin;
  _offerView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, width - 300, 120)];
  _offerView.editable = NO;
  _offerView.font = [NSFont userFixedPitchFontOfSize:10];
  NSScrollView *offerScroll = [self scrollViewFor:_offerView frame:NSMakeRect(184, y + 40, width - 196, 120)];
  offerScroll.autoresizingMask = NSViewMinYMargin | NSViewWidthSizable;
  _expiresField = [self labelWithFrame:NSMakeRect(184, y + 10, 260, 20) text:@"No pairing code: Show Pairing Code."];
  _expiresField.autoresizingMask = NSViewMinYMargin;
  _copyButton = [self buttonWithFrame:NSMakeRect(width - 112, y + 4, 100, 28) title:@"Copy" action:@selector(copyOffer:)];
  _copyButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
  for (NSView *view in @[ _codeView, offerScroll, _expiresField, _copyButton ]) [content addSubview:view];

  // Pairing with another's code, pasted.
  y -= 40;
  NSTextField *pair = [self labelWithFrame:NSMakeRect(12, y + 4, 150, 20) text:@"Another's pairing code:"];
  _pairField = [[NSTextField alloc] initWithFrame:NSMakeRect(166, y + 2, width - 360, 24)];
  _pairField.placeholderString = @"{\"code\":…, \"host\":…}";
  NSButton *paste = [self buttonWithFrame:NSMakeRect(width - 186, y, 80, 28) title:@"Paste" action:@selector(paste:)];
  _pairButton = [self buttonWithFrame:NSMakeRect(width - 100, y, 88, 28) title:@"Pair" action:@selector(pair:)];
  pair.autoresizingMask = NSViewMinYMargin;
  _pairField.autoresizingMask = NSViewMinYMargin | NSViewWidthSizable;
  paste.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
  _pairButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
  for (NSView *view in @[ pair, _pairField, paste, _pairButton ]) [content addSubview:view];

  // The devices found nearby, and paired: side by side, the rest of it.
  CGFloat listTop = y - 10, listBottom = 72, half = (width - 36) / 2;
  NSTextField *nearby = [self labelWithFrame:NSMakeRect(12, listTop - 20, half, 20) text:@"Nearby"];
  NSTextField *paired = [self labelWithFrame:NSMakeRect(24 + half, listTop - 20, half, 20) text:@"Paired"];
  nearby.autoresizingMask = NSViewMinYMargin;
  paired.autoresizingMask = NSViewMinYMargin | NSViewMinXMargin;
  _nearbyTable = [self tableWithColumns:@[ @[ @"name", @"Name", @150 ], @[ @"host", @"Address", @110 ], @[ @"paired", @"Paired", @50 ] ]
                                  frame:NSMakeRect(0, 0, half, listTop - 24 - listBottom)];
  _nearbyTable.doubleAction = @selector(syncWithSelected:);
  _nearbyTable.target = self;
  _pairedTable = [self tableWithColumns:@[ @[ @"name", @"Name", @150 ], @[ @"date", @"Since", @150 ] ]
                                  frame:NSMakeRect(0, 0, half, listTop - 24 - listBottom)];
  NSScrollView *nearbyScroll = [self scrollViewFor:_nearbyTable frame:NSMakeRect(12, listBottom, half, listTop - 24 - listBottom)];
  NSScrollView *pairedScroll = [self scrollViewFor:_pairedTable frame:NSMakeRect(24 + half, listBottom, half, listTop - 24 - listBottom)];
  nearbyScroll.autoresizingMask = NSViewHeightSizable | NSViewWidthSizable | NSViewMaxXMargin;
  pairedScroll.autoresizingMask = NSViewHeightSizable | NSViewWidthSizable | NSViewMinXMargin;
  _syncButton = [self buttonWithFrame:NSMakeRect(12, 36, 160, 28) title:@"Sync with Selected" action:@selector(syncWithSelected:)];
  _forgetButton = [self buttonWithFrame:NSMakeRect(24 + half, 36, 100, 28) title:@"Forget" action:@selector(forgetSelected:)];
  _syncButton.autoresizingMask = NSViewMaxYMargin;
  _forgetButton.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
  _statusField = [self labelWithFrame:NSMakeRect(12, 8, width - 24, 20) text:@""];
  _statusField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
  for (NSView *view in @[ nearby, paired, nearbyScroll, pairedScroll, _syncButton, _forgetButton, _statusField ]) [content addSubview:view];
  [self reload];
}

- (void)show
{
  [self.peers startBrowsing];
  [self reload];
  [_window makeKeyAndOrderFront:nil];
}

#pragma mark Reading

- (void)peersChanged:(NSNotification *)notification
{
  if (notification.object == self.peers) [self reload];
}

- (void)sessionChanged:(NSNotification *)notification
{
  _statusField.stringValue = notification.userInfo[@"status"] ?: @"";
  // A new device (reset, another address): another replica, no offer.
  if (!self.peers) [self forgetOffer];
  [self reload];
}

- (void)reload
{
  DVPeers *peers = self.peers;
  BOOL has = peers != nil;
  if (!has) {
    _tokenField.stringValue = _session.device ? @"No peers: the device's identity is not made." : @"No device: set the Workbench's address first.";
  } else if (peers.fetchingToken) {
    _tokenField.stringValue = @"Asking the Workbench…";
  } else {
    _tokenField.stringValue = peers.hasToken ? [@"One, until " stringByAppendingString:DDShortDate(peers.tokenExpires ?: [NSDate distantFuture])]
                                             : @"None: devices with one from the same Workbench sync with each other.";
  }
  _tokenButton.enabled = has && !peers.fetchingToken;
  _serveButton.enabled = has;
  _serveButton.state = peers.serving ? NSOnState : NSOffState;
  _rootField.stringValue = peers.serviceRoot.absoluteString ?: (has ? [NSString stringWithFormat:@"Port %lu, advertised nearby", (unsigned long)peers.port] : @"");
  _offerButton.enabled = peers.serving;
  _pairButton.enabled = has;
  _copyButton.enabled = _offer != nil;
  [_nearbyTable reloadData];
  [_pairedTable reloadData];
  _syncButton.enabled = has && peers.found.count;
  _forgetButton.enabled = has && peers.pairings.count;
  if (!_statusField.stringValue.length) _statusField.stringValue = _session.status;
}

#pragma mark Actions

- (IBAction)fetchToken:(id)sender
{
  [self.peers fetchToken];
}

- (IBAction)serveChanged:(id)sender
{
  DVPeers *peers = self.peers;
  if (_serveButton.state != NSOnState) {
    [peers stopServing];
    [self forgetOffer];
    return;
  }
  NSError *error = nil;
  if (![peers startServing:&error]) {
    _serveButton.state = NSOffState;
    _statusField.stringValue = [@"Not serving to peers: " stringByAppendingString:error.localizedDescription ?: @"no reason given."];
  }
}

- (IBAction)showOffer:(id)sender
{
  _offer = [self.peers newPairingOffer];
  _offerExpires = _offer ? [NSDate dateWithTimeIntervalSinceNow:120] : nil;
  _offerView.string = _offer ?: @"";
  _codeView.image = _offer ? DDSystemQRCode(_offer, 320) : nil;
  [_tick invalidate];
  _tick = _offer ? [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick:) userInfo:nil repeats:YES] : nil;
  [self tick:nil];
  [self reload];
}

- (void)tick:(NSTimer *)timer
{
  NSTimeInterval left = _offerExpires.timeIntervalSinceNow;
  if (!_offer) {
    _expiresField.stringValue = @"No pairing code: Show Pairing Code.";
  } else if (left <= 0) {
    _expiresField.stringValue = @"Expired: Show Pairing Code again.";
    [_tick invalidate];
    _tick = nil;
  } else {
    _expiresField.stringValue = [NSString stringWithFormat:@"Good once, for %d:%02d", (int)left / 60, (int)left % 60];
  }
}

- (void)forgetOffer
{
  [_tick invalidate];
  _tick = nil;
  _offer = nil;
  _offerExpires = nil;
  _offerView.string = @"";
  _codeView.image = nil;
  [self tick:nil];
}

- (IBAction)copyOffer:(id)sender
{
  if (_offer) DDSystemCopyText(_offer);
}

- (IBAction)paste:(id)sender
{
  NSString *text = DDSystemPastedText();
  if (text.length) _pairField.stringValue = text;
}

- (IBAction)pair:(id)sender
{
  NSString *text = _pairField.stringValue;
  if (!text.length) {
    _statusField.stringValue = @"Paste the other device's pairing code first (its Peers, Show Pairing Code, Copy).";
    return;
  }
  __weak DDPeersWindow *weak = self;
  [self.peers pairWithOffer:text completion:^(NSError *error) {
    DDPeersWindow *strong = weak;
    if (!strong) return;
    if (!error) strong->_pairField.stringValue = @"";
  }];
}

- (IBAction)syncWithSelected:(id)sender
{
  NSArray *found = self.peers.found;
  NSInteger row = _nearbyTable.selectedRow;
  if (row < 0 && found.count == 1) row = 0;
  if (row < 0 || (NSUInteger)row >= found.count) {
    _statusField.stringValue = @"Select a device under Nearby to sync with it.";
    return;
  }
  [self.peers syncWithPeer:found[(NSUInteger)row]];
}

- (IBAction)forgetSelected:(id)sender
{
  NSArray *pairings = self.peers.pairings;
  NSInteger row = _pairedTable.selectedRow;
  if (row < 0 || (NSUInteger)row >= pairings.count) {
    _statusField.stringValue = @"Select a paired device to forget it.";
    return;
  }
  NSError *error = nil;
  if (![self.peers forgetPairing:pairings[(NSUInteger)row] error:&error]) {
    _statusField.stringValue = [@"Not forgotten: " stringByAppendingString:error.localizedDescription ?: @"no reason given."];
  }
}

#pragma mark Tables

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
  DVPeers *peers = self.peers;
  return (NSInteger)(tableView == _nearbyTable ? peers.found.count : peers.pairings.count);
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  DVPeers *peers = self.peers;
  NSString *identifier = column.identifier;
  if (tableView == _nearbyTable) {
    if ((NSUInteger)row >= peers.found.count) return nil;
    ODataSyncPeerAnnouncement *peer = peers.found[(NSUInteger)row];
    if ([identifier isEqualToString:@"name"]) return peer.name;
    if ([identifier isEqualToString:@"host"]) return peer.host;
    return [peers pairingOfPeer:peer] ? @"yes" : @"";
  }
  if ((NSUInteger)row >= peers.pairings.count) return nil;
  ODataSyncPeerPairing *pairing = peers.pairings[(NSUInteger)row];
  if ([identifier isEqualToString:@"name"]) return pairing.name ?: pairing.replica;
  return DDShortDate(pairing.date);
}

@end
