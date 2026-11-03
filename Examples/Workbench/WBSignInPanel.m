// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "WBSignInPanel.h"

static NSString * const WBClientIDsKey = @"WBSignInClientIDs";

NSString *WBClientIDForRoot(NSURL *root)
{
  NSDictionary *known = [[NSUserDefaults standardUserDefaults] dictionaryForKey:WBClientIDsKey];
  NSString *clientID = root.absoluteString ? known[root.absoluteString] : nil;
  return [clientID isKindOfClass:[NSString class]] && clientID.length ? clientID : nil;
}

void WBSetClientIDForRoot(NSString *clientID, NSURL *root)
{
  if (!root.absoluteString) return;
  NSMutableDictionary *known = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:WBClientIDsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
  known[root.absoluteString] = clientID;
  [[NSUserDefaults standardUserDefaults] setObject:known forKey:WBClientIDsKey];
}

// WBSignInPanel.xib: the panel, its two groups (a user and password;
// OpenID Connect's client and code), the status and the buttons.
@interface WBSignInPanel ()
@property (nonatomic, readwrite, strong) IBOutlet NSPanel *panel;
@property (nonatomic, readwrite, strong) IBOutlet NSTextField *codeField;
@property (nonatomic, weak) IBOutlet NSTextField *message, *status, *clientField, *userField, *passwordField;
@property (nonatomic, weak) IBOutlet NSView *passwordGroup, *deviceGroup;
@property (nonatomic, weak) IBOutlet NSButton *signInButton, *openButton, *pasteboardButton;
@end

@implementation WBSignInPanel {
  void (^_done)(BOOL);
  NSArray *_nibObjects;
  NSURL *_page;
}

- (instancetype)initWithSignIn:(ODataSignIn *)signIn
{
  if (!(self = [super init])) return nil;
  _signIn = signIn;
  NSArray *objects = nil;
  NSNib *nib = [[NSNib alloc] initWithNibNamed:@"WBSignInPanel" bundle:[NSBundle bundleForClass:[WBSignInPanel class]]];
  if (![nib instantiateWithOwner:self topLevelObjects:&objects] || !_panel) return nil;
  _nibObjects = objects;
  [self preparePanel];
  return self;
}

// The group this sign-in is, and what the panel says of the service and its
// provider.
- (void)preparePanel
{
  BOOL password = _signIn.kind == ODataSignInPassword;
  _panel.title = [NSString stringWithFormat:@"Sign In to %@", _signIn.serviceRoot.host ?: @"the Service"];
  _message.stringValue = password ? @"This service asks for a user name and password."
                                  : [NSString stringWithFormat:@"This service signs in with %@. The Workbench signs in "
                                                               @"there as the client below (a public client with the "
                                                               @"device flow on).", _signIn.issuer.host ?: @"OpenID Connect"];
  [_passwordGroup setHidden:!password];
  [_deviceGroup setHidden:password];
  if (!password) _clientField.stringValue = WBClientIDForRoot(_signIn.serviceRoot) ?: @"";
}

- (void)showBesideWindow:(NSWindow *)window done:(void (^)(BOOL))done
{
  _done = [done copy];
  if (window) {
    NSRect over = window.frame;
    [_panel setFrameOrigin:NSMakePoint(NSMidX(over) - NSWidth(_panel.frame) / 2, NSMidY(over) - NSHeight(_panel.frame) / 2)];
  } else {
    [_panel center];
  }
  [_panel makeKeyAndOrderFront:nil];
}

- (void)finish:(BOOL)signedIn
{
  _signIn.delegate = nil;
  [_signIn cancel];
  [_panel orderOut:nil];
  void (^done)(BOOL) = _done;
  _done = nil;
  if (done) done(signedIn);
}

#pragma mark Actions

- (IBAction)signIn:(id)sender
{
  (void)sender;
  _signIn.delegate = self;
  if (_signIn.kind == ODataSignInPassword) {
    [_signIn signInWithUser:_userField.stringValue password:_passwordField.stringValue];
    return;
  }
  NSString *clientID = [_clientField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (!clientID.length) {
    _status.stringValue = @"Type the identity provider's client ID first.";
    return;
  }
  WBSetClientIDForRoot(clientID, _signIn.serviceRoot);
  _signIn.clientID = clientID;
  _signInButton.enabled = NO;
  _status.stringValue = @"Asking the identity provider for a code …";
  [_signIn begin];
}

- (IBAction)cancel:(id)sender
{
  (void)sender;
  [self finish:NO];
}

- (IBAction)openPage:(id)sender
{
  (void)sender;
  // The browser: on GNUstep through GSUnknownFileTool, which the AppImage
  // points at the host's opener (gnustep-release-actions' appimage/open).
  if (_page && ![[NSWorkspace sharedWorkspace] openURL:_page]) {
    _status.stringValue = [NSString stringWithFormat:@"No browser opened it: open %@ yourself.", _page.absoluteString];
  }
}

- (IBAction)copyCode:(id)sender
{
  (void)sender;
  NSPasteboard *board = [NSPasteboard generalPasteboard];
  [board declareTypes:@[ NSPasteboardTypeString ] owner:nil];
  [board setString:_codeField.stringValue forType:NSPasteboardTypeString];
}

#pragma mark ODataSignInDelegate

- (void)signIn:(ODataSignIn *)signIn showCode:(NSString *)code page:(NSURL *)page completePage:(NSURL *)completePage
{
  _page = completePage ?: page;
  _codeField.stringValue = code;
  _openButton.hidden = _pasteboardButton.hidden = NO;
  _status.stringValue = [NSString stringWithFormat:@"Enter the code at %@, then come back: waiting for you to sign in …", page.absoluteString];
  [self openPage:nil];
}

- (void)signInDidFinish:(ODataSignIn *)signIn
{
  [self finish:YES];
}

- (void)signIn:(ODataSignIn *)signIn didFail:(NSError *)error
{
  _signInButton.enabled = YES;
  _openButton.hidden = _pasteboardButton.hidden = YES;
  _codeField.stringValue = @"";
  _status.stringValue = error.localizedDescription ?: @"Signing in failed.";
}

@end
