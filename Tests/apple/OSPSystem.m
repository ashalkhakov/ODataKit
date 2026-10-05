// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "OSPSystem.h"
#import "ODSAppleSystem.h"

@interface OSPClient () <NSURLSessionDelegate>
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation OSPClient
- (instancetype)initWithIdentity:(ODataSyncPeerIdentity *)identity
{
  self = [super init];
  _identity = identity;
  _session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration] delegate:self delegateQueue:nil];
  return self;
}

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler
{
  NSString *method = challenge.protectionSpace.authenticationMethod;
  if ([method isEqualToString:NSURLAuthenticationMethodServerTrust]) {
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    CFArrayRef chain = SecTrustCopyCertificateChain(trust);
    SecCertificateRef leaf = chain && CFArrayGetCount(chain) ? (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0) : NULL;
    self.serverThumbprint = ODSAppleThumbprint(leaf);
    if (chain) CFRelease(chain);
    completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
  } else if ([method isEqualToString:NSURLAuthenticationMethodClientCertificate] && self.identity) {
    completionHandler(NSURLSessionAuthChallengeUseCredential,
                      [NSURLCredential credentialWithIdentity:self.identity.system.secIdentity certificates:nil persistence:NSURLCredentialPersistenceNone]);
  } else {
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
  }
}

// GET, waited for: the status and the JSON (or the error).
- (NSInteger)get:(NSURL *)url json:(id *)json error:(NSError **)error
{
  __block NSInteger status = 0;
  __block id body = nil;
  __block NSError *failure = nil;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  [[self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
    status = [(NSHTTPURLResponse *)response statusCode];
    body = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    failure = taskError;
    dispatch_semaphore_signal(done);
  }] resume];
  dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
  if (json) *json = body;
  if (error) *error = failure;
  return status;
}

- (void)close
{
  [self.session invalidateAndCancel];
}
@end

NSString *OSPCheckIdentity(ODataSyncPeerIdentity *identity)
{
  SecCertificateRef certificate = identity.system.secCertificate;
  // Well formed and signed by its own key: trusted as its own anchor.
  SecTrustRef trust = NULL;
  SecPolicyRef policy = SecPolicyCreateBasicX509();
  if (SecTrustCreateWithCertificates(certificate, policy, &trust) != errSecSuccess) {
    CFRelease(policy);
    return @"no trust can be made of the certificate";
  }
  SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)@[ (__bridge id)certificate ]);
  CFErrorRef trustError = NULL;
  BOOL trusted = SecTrustEvaluateWithError(trust, &trustError);
  CFRelease(trust);
  CFRelease(policy);
  if (!trusted) return [NSString stringWithFormat:@"not its own anchor: %@", (__bridge_transfer NSError *)trustError];

  // Its key signs, and the certificate's public key checks it.
  SecKeyRef key = NULL;
  if (SecIdentityCopyPrivateKey(identity.system.secIdentity, &key) != errSecSuccess) return @"no private key";
  NSData *message = [@"peer" dataUsingEncoding:NSUTF8StringEncoding];
  NSData *signature = (__bridge_transfer NSData *)SecKeyCreateSignature(key, kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                                                                        (__bridge CFDataRef)message, NULL);
  SecKeyRef publicKey = SecCertificateCopyKey(certificate);
  BOOL checks = signature && SecKeyVerifySignature(publicKey, kSecKeyAlgorithmECDSASignatureMessageX962SHA256, (__bridge CFDataRef)message,
                                                   (__bridge CFDataRef)signature, NULL);
  CFRelease(publicKey);
  CFRelease(key);
  // (Private: the keychain's to keep so.)
  return checks ? nil : @"the key's signature does not check with the certificate";
}

BOOL OSPDiscoveryAvailable(void)
{
  return YES;
}
