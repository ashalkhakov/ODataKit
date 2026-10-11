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

// A label: text that is not edited, on the panel's background.
static NSTextField *WBLabel(NSRect frame, NSString *text)
{
  NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
  label.stringValue = text;
  label.editable = NO;
  label.selectable = NO;
  label.bezeled = NO;
  label.drawsBackground = NO;
  return label;
}

static NSButton *WBButton(NSRect frame, NSString *title, id target, SEL action)
{
  NSButton *button = [[NSButton alloc] initWithFrame:frame];
  button.title = title;
  button.bezelStyle = NSRoundedBezelStyle;  // the name both AppKits have
  button.target = target;
  button.action = action;
  return button;
}

@implementation WBSignInPanel {
  void (^_done)(BOOL);
  NSTextField *_message, *_status, *_clientField, *_userField, *_passwordField;
  NSButton *_signInButton, *_openButton, *_copyButton;
  NSURL *_page;
}

- (instancetype)initWithSignIn:(ODataSignIn *)signIn
{
  if (!(self = [super init])) return nil;
  _signIn = signIn;
  [self makePanel];
  return self;
}

- (void)makePanel
{
  BOOL password = _signIn.kind == ODataSignInPassword;
  _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 460, 250) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                         backing:NSBackingStoreBuffered defer:NO];
  _panel.title = [NSString stringWithFormat:@"Sign In to %@", _signIn.serviceRoot.host ?: @"the Service"];
  _panel.releasedWhenClosed = NO;
  NSView *content = _panel.contentView;
  _message = WBLabel(NSMakeRect(20, 186, 420, 48), password ? @"This service asks for a user name and password."
                                                            : [NSString stringWithFormat:@"This service signs in with %@. The Workbench signs in "
                                                                                          @"there as the client below (a public client with the "
                                                                                          @"device flow on).", _signIn.issuer.host ?: @"OpenID Connect"]);
  [content addSubview:_message];
  if (password) {
    [content addSubview:WBLabel(NSMakeRect(20, 150, 90, 20), @"User:")];
    _userField = [[NSTextField alloc] initWithFrame:NSMakeRect(115, 148, 325, 24)];
    [content addSubview:_userField];
    [content addSubview:WBLabel(NSMakeRect(20, 116, 90, 20), @"Password:")];
    _passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(115, 114, 325, 24)];
    [content addSubview:_passwordField];
  } else {
    [content addSubview:WBLabel(NSMakeRect(20, 150, 90, 20), @"Client ID:")];
    _clientField = [[NSTextField alloc] initWithFrame:NSMakeRect(115, 148, 325, 24)];
    _clientField.stringValue = WBClientIDForRoot(_signIn.serviceRoot) ?: @"";
    _clientField.placeholderString = @"the identity provider's client ID";
    [content addSubview:_clientField];
    _codeField = WBLabel(NSMakeRect(20, 104, 420, 34), @"");
    _codeField.font = [NSFont boldSystemFontOfSize:24];
    _codeField.alignment = NSTextAlignmentCenter;
    _codeField.selectable = YES;
    [content addSubview:_codeField];
    _openButton = WBButton(NSMakeRect(20, 64, 140, 32), @"Open Page", self, @selector(openPage:));
    _copyButton = WBButton(NSMakeRect(164, 64, 140, 32), @"Copy Code", self, @selector(copyCode:));
    _openButton.hidden = _copyButton.hidden = YES;
    [content addSubview:_openButton];
    [content addSubview:_copyButton];
  }
  _status = WBLabel(NSMakeRect(20, 40, 420, 20), @"");
  _status.font = [NSFont systemFontOfSize:11];
  [content addSubview:_status];
  _signInButton = WBButton(NSMakeRect(340, 8, 100, 32), @"Sign In", self, @selector(signIn:));
  _signInButton.keyEquivalent = @"\r";
  [content addSubview:_signInButton];
  [content addSubview:WBButton(NSMakeRect(236, 8, 100, 32), @"Cancel", self, @selector(cancel:))];
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
  // points at the host's opener (Scripts/appimage/open).
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
  _openButton.hidden = _copyButton.hidden = NO;
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
  _openButton.hidden = _copyButton.hidden = YES;
  _codeField.stringValue = @"";
  _status.stringValue = error.localizedDescription ?: @"Signing in failed.";
}

@end
