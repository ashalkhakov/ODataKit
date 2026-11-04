// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODWServiceSheet.h"
#import "ODWServices.h"

@interface ODWServiceSheet ()
@property (nonatomic, readwrite, strong) IBOutlet NSWindow *sheet;
@property (nonatomic, readwrite, weak) IBOutlet NSTextField *nameField;
@property (nonatomic, readwrite, weak) IBOutlet NSTextField *rootField;
@property (nonatomic, readwrite, weak) IBOutlet NSButton *projectCheckbox;
@property (nonatomic, readwrite, weak) IBOutlet NSTextField *problemLabel;
@property (nonatomic, weak) IBOutlet NSButton *saveButton;
@end

@implementation ODWServiceSheet {
  NSArray *_nibObjects;
  NSWindow *_parent;
  void (^_done)(ODWService *);
}

- (instancetype)initWithService:(ODWService *)service inProject:(BOOL)hasProject
{
  if (!(self = [super init])) return nil;
  NSArray *objects = nil;
  NSNib *nib = [[NSNib alloc] initWithNibNamed:@"ODWServiceSheet" bundle:[NSBundle bundleForClass:[ODWServiceSheet class]]];
  if (![nib instantiateWithOwner:self topLevelObjects:&objects] || !_sheet) return nil;
  _nibObjects = objects;
  _sheet.title = service ? @"Edit Service" : @"Add Service";
  _saveButton.title = service ? @"Save" : @"Add";
  _nameField.stringValue = service.name ?: @"";
  _rootField.stringValue = service.root.absoluteString ?: @"";
  _projectCheckbox.enabled = hasProject;
  _projectCheckbox.state = hasProject && (service ? service.inProject : YES) ? NSControlStateValueOn : NSControlStateValueOff;
  _problemLabel.stringValue = @"";
  return self;
}

- (void)beginSheetForWindow:(NSWindow *)window done:(void (^)(ODWService *))done
{
  _done = [done copy];
  _parent = window;
  if (window) {
    [window beginSheet:_sheet completionHandler:nil];
  } else {
    [_sheet center];
    [_sheet makeKeyAndOrderFront:nil];
  }
}

- (ODWService *)typedService
{
  NSCharacterSet *space = [NSCharacterSet whitespaceAndNewlineCharacterSet];
  NSString *name = [_nameField.stringValue stringByTrimmingCharactersInSet:space];
  NSString *text = [_rootField.stringValue stringByTrimmingCharactersInSet:space];
  NSURL *root = text.length ? [NSURL URLWithString:text] : nil;
  if (!name.length) {
    _problemLabel.stringValue = @"Name it: the navigator lists it by its name.";
    return nil;
  }
  if (!root.scheme.length || !root.host.length) {
    _problemLabel.stringValue = @"Type the service root's URL: https://host/path/.";
    return nil;
  }
  _problemLabel.stringValue = @"";
  return [ODWServices serviceNamed:name root:root inProject:_projectCheckbox.state == NSControlStateValueOn];
}

- (void)finish:(ODWService *)service
{
  if (_parent) [_parent endSheet:_sheet];
  [_sheet orderOut:nil];
  void (^done)(ODWService *) = _done;
  _done = nil;
  if (done) done(service);
}

- (IBAction)save:(id)sender
{
  ODWService *service = [self typedService];
  if (service) [self finish:service];
}

- (IBAction)cancel:(id)sender
{
  [self finish:nil];
}

@end
