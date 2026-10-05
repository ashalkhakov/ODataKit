// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The Linux side of ODSSystem: what the listener and the client present a
// device's identity with (GnuTLS and libcurl read PEM files).

#pragma once
#import "../ODSSystem.h"

NS_ASSUME_NONNULL_BEGIN

@interface ODSSystemIdentity ()
- (instancetype)initWithCertificate:(NSData *)certificate certificateURL:(NSURL *)certificateURL keyURL:(NSURL *)keyURL;
// The certificate and its private key (the user's alone, 0600), PEM.
@property (nonatomic, readonly, copy) NSURL *certificateURL;
@property (nonatomic, readonly, copy) NSURL *keyURL;
@end

// errno's error, about path.
FOUNDATION_EXPORT NSError *ODSSystemPOSIXError(NSString *what, NSString *path);

NS_ASSUME_NONNULL_END
