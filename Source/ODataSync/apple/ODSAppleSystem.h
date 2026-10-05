// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The Apple side of ODSSystem: what the listener and the client present
// a device's identity with.

#pragma once
#import "../ODSSystem.h"
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

@interface ODSSystemIdentity ()
- (instancetype)initWithIdentity:(SecIdentityRef)identity label:(NSString *)label;
@property (nonatomic, readonly, copy) NSString *label;
@property (nonatomic, readonly) SecIdentityRef secIdentity;
@property (nonatomic, readonly) SecCertificateRef secCertificate;
@end

// A certificate's x5t#S256.
FOUNDATION_EXPORT NSString *_Nullable ODSAppleThumbprint(SecCertificateRef _Nullable certificate);

NS_ASSUME_NONNULL_END
