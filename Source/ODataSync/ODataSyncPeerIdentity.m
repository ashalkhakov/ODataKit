// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataSyncPeerIdentity.h"
#import "ODSSystem.h"

@implementation ODataSyncPeerIdentity {
  ODSSystemIdentity *_system;
}

+ (NSString *)thumbprintOfCertificateData:(NSData *)certificate
{
  NSString *base64 = [ODSSystemSHA256(certificate) base64EncodedStringWithOptions:0];
  base64 = [[base64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
  return [base64 stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"="]];
}

+ (NSURL *)defaultDirectory
{
  return ODSSystemIdentityDirectory();
}

+ (instancetype)identityNamed:(NSString *)name error:(NSError **)error
{
  return [self identityNamed:name directory:[self defaultDirectory] error:error];
}

+ (instancetype)identityNamed:(NSString *)name directory:(NSURL *)directory error:(NSError **)error
{
  ODSSystemIdentity *system = ODSSystemKeepIdentity([@"ODataSync peer " stringByAppendingString:name], directory, error);
  return system ? [[self alloc] initWithName:name system:system] : nil;
}

- (instancetype)initWithName:(NSString *)name system:(ODSSystemIdentity *)system
{
  self = [super init];
  if (!self) return nil;
  _name = [name copy];
  _system = system;
  _certificateData = [system.certificate copy];
  _thumbprint = [ODataSyncPeerIdentity thumbprintOfCertificateData:_certificateData];
  return self;
}

- (ODSSystemIdentity *)system
{
  return _system;
}

- (BOOL)removeWithError:(NSError **)error
{
  return ODSSystemForgetIdentity(_system, error);
}

@end
