# Peer sync on devices

Devices sync with each other the way they sync with the service: one
serves its store as an OData API (`ODataSyncPeerServer`), the other adds
it as a remote. This page is about doing that between phones and tablets
on a local network: finding a peer, knowing who it is, and keeping what
goes between them private. The sync itself, its version vectors and its
conflicts, is [offline sync](offline-sync.md)'s, section 7.

## 1. What is wanted

- A device serves its synced store to peers, from inside the app (iOS
  and macOS), and syncs with peers it finds on the same network.
- Only devices that should may sync: ones the service vouches for, or ones
  a person paired by hand.
- Nothing readable or replayable goes over the air: every connection is
  encrypted, and both ends know whom they talk to.
- No certificate authority, and no setup beyond signing in (or pairing).

Not wanted here: syncing across the internet (devices reach the service
for that), or peers that are not ODataSync devices.

## 2. The pieces

```
  device A                                         device B
  ┌───────────────────────────┐                    ┌───────────────────────────┐
  │ ODataSyncEngine            │                    │ ODataSyncEngine            │
  │  └ remote: peer B ────────────── TLS ──────────────▶ ODataSyncPeerListener │
  │      (ODataSyncPeerTransport:│  (mutual, pinned  │   TLS, client certs       │
  │       client certificate,   │   or token-bound) │   │ loopback             │
  │       server checked)       │                    │   ▼                       │
  │ ODataSyncPeerIdentity       │                    │ ODataSyncPeerServer       │
  │  (key pair, certificate)    │                    │   HTTPServerKit + OData   │
  │ ODataSyncPeerBrowser ◀──── Bonjour _odatasync._tcp ──── advertised by B     │
  └───────────────────────────┘                    └───────────────────────────┘
```

- **Identity** (`ODataSyncPeerIdentity`): each device has a key pair
  (P-256) and a self-signed certificate of it, made once and kept: in the
  keychain on Apple platforms, in two PEM files on GNUstep (the key's
  readable by the user alone). Its **thumbprint**, the SHA-256 of the certificate
  (base64url, RFC 8705's `x5t#S256`), is the device's name on the network.
- **Listener** (`ODataSyncPeerListener`): a TLS listener
  (Network.framework on Apple, GnuTLS on GNUstep) that asks every client for its certificate, and
  relays each connection, decrypted, to the peer server on loopback. It
  tells the server which certificate each relayed connection came with.
- **Server**: `ODataSyncPeerServer` as it is, on HTTPServerKit, listening
  on loopback only, with an authenticator that knows the connection's
  certificate.
- **Discovery** (`ODataSyncPeerBrowser`, `ODataSyncPeerAdvertiser`):
  Bonjour (`dns_sd`: Apple's, or Avahi's compatibility library on Linux),
  service type `_odatasync._tcp`, its TXT record the
  replica ID, the path, and the thumbprint. What it says is a hint: trust
  comes from TLS and what follows.
- **Transport** (`ODataSyncPeerTransport`): a remote's way to a peer:
  TLS with this device's certificate, and the peer's checked (below).
  URLSession on Apple; libcurl on GNUstep, which can pin only a public
  key, so it sees the peer's certificate first on a request that carries
  nothing secret (`GET $peer`), then pins that certificate's key.

## 3. Trust

A connection is trusted once each side knows the other's certificate
belongs to a device it may sync with. Two ways to know:

### 3.1 Tokens the service issues

While online, a signed-in device asks the service for a **peer token**: a
short-lived JWT the service signs (ES256), saying

| claim | |
|---|---|
| `iss` | the service |
| `sub` | the user |
| `aud` | `odatasync-peer` |
| `odatasync_replica` | the device's replica ID |
| `scope` | the principal's scopes (or what the issuer's `scopesForPrincipal` gives) |
| `cnf` | `{"x5t#S256": thumbprint}`: the token is bound to the device's certificate (RFC 8705, RFC 7800) |
| `exp`, `iat` | a day, say |

and the service's public keys (a JWK Set), which it keeps. A token bound
to a certificate is worth nothing without the key: one overheard (there is
nothing to overhear, over TLS) or copied cannot be used from another
device.

When device B connects to A:

1. TLS: B presents its certificate; A presents its own. Neither is checked
   against a CA.
2. B sends its token (`Authorization: Bearer`). A checks it with the
   service's keys (HTTPServerKit's `HSJWTAuthenticator`, keys given, never
   fetched: A may be offline), and that its `cnf` thumbprint is the
   certificate of this connection. B is then the token's user and
   replica, with its scopes.
3. B checks A the same way: before sending anything else, it asks A for
   A's token (`GET <root>$peer`), checks it with the same keys, that its
   thumbprint is the certificate A's TLS presented, and that its replica
   is the one in A's service root (`…/sync/<replica>/`). From then on, B's
   connections to A accept only that certificate (and only the one A
   advertised, when B was given it: `expectedThumbprint`).
4. Before each request after, B checks again that A is still trusted (its
   token not expired, its pairing not forgotten).

By default a device takes tokens of its own user's devices only (the
token's `sub` is its own token's): `acceptsOtherSubjects` on the trust
takes any user's of the same service. Both devices must belong to the same
service (the same keys).

The replica a token names is the device's to say, and a peer takes what
that device sends as coming from that replica. The issuer refuses (409) a
replica another user already asked a token for; an app that records which
user each replica is gives `allowsReplica` instead.

Revocation is by expiry: a device the service stops vouching for cannot
get a new token, and its last one runs out.

What a peer may read and write is what the peer server serves: the
synced entities, down ones read only. A token's scopes are enforced only
where the model declares permissions for them (as on the service).

### 3.2 Pairing

For devices with no service in common, or none at hand: a person pairs
them once.

1. A shows a QR code (or the same as text): its host, port, replica ID,
   thumbprint, and a one-time code (128 bits, good for two minutes).
2. B reads it, connects by TLS (`GET <root>$peer`, nothing secret sent),
   and checks that A's certificate has the thumbprint the code gave (so B
   knows it reached A, not whoever answered).
3. B posts the one-time code to A (`POST <root>$pair`) over that
   connection. A checks it, and records B's thumbprint (from TLS) and
   replica ID as paired. B records A's.
4. From then on, each accepts the other's certificate by its thumbprint
   alone: mutual TLS, pinned both ways.

A pairing is forgotten by either side alone
(`-forgetPairingWithThumbprint:error:`); a paired device syncs as the
subject the offer named, with the offer's scopes.

A used or expired code is answered 410, not 403: URLSession reports a 403
on a connection that presented a client certificate as -1206 ("requires a
client certificate"), which would hide the reason.

### 3.3 Both

A listener takes either: a token bound to the connection's certificate,
or a certificate it paired with. The authenticator tries the pairing
first (no token needed), then the token.

## 4. Using it

The service issues the tokens: give its `ODataSyncService` an issuer
with a signing key (keep the key; `HSGenerateSigningKey` makes one), and
sign devices in (its service's authenticator: no principal, no token).

```objc
NSDictionary *key = HSGenerateSigningKey(&error);
sync.peerTokens = [[ODataSyncPeerTokenIssuer alloc] initWithIssuer:serviceRoot.absoluteString signingKey:key];
// The action is PeerToken(Replica, Thumbprint); with serviceOperations of
// your own, adopt ODataSyncPeerTokenActions and forward to sync.
```

A device makes its identity and trust, and takes a token while online:

```objc
ODataSyncPeerIdentity *identity = [ODataSyncPeerIdentity identityNamed:engine.replicaID error:&error];
ODataSyncPeerTrust *trust = [[ODataSyncPeerTrust alloc] initWithIdentity:identity pairingsURL:pairingsFile];
NSDictionary *answer = [engine peerTokenFromRemote:serviceRemote thumbprint:identity.thumbprint error:&error];
[trust takePeerTokenAnswer:answer error:&error];   // keep answer: it serves offline until it expires
```

On GNUstep, `+identityNamed:error:` keeps the identity's files under
`+defaultDirectory` (Application Support/<the process>/ODataSync Peers);
`+identityNamed:directory:error:` keeps them where the app says.

It serves its store, and says so nearby:

```objc
ODataSyncPeerServer *server = [[ODataSyncPeerServer alloc] initWithEngine:engine trust:trust host:lanAddress port:8642];
[server start:&error];
ODataSyncPeerAdvertiser *advertiser = [[ODataSyncPeerAdvertiser alloc] initWithServer:server name:nil];
[advertiser start:&error];
```

Another finds it (`ODataSyncPeerBrowser`, its delegate told of each
`ODataSyncPeerAnnouncement`) and syncs with it:

```objc
ODataSyncRemote *peer = [ODataSyncRemote peerWithServiceRoot:announcement.serviceRoot];
ODataSyncPeerTransport *transport = [[ODataSyncPeerTransport alloc] initWithServiceRoot:peer.serviceRoot trust:trust];
transport.expectedThumbprint = announcement.thumbprint;   // the certificate it advertised, no other
peer.transport = transport;
[engine syncWithRemote:peer error:&error];   // or addRemote:, to sync with it every time
```

Pairing instead: the serving device's `-pairingOfferForSubject:scopes:`
(its JSON in a QR code), and on the other, `+[ODataSyncPeerTransport
transportPairingWithOffer:trust:replica:name:subject:scopes:error:]`,
which returns a transport that already knows the peer.

An iOS app that browses names the service type in its Info.plist
(`NSBonjourServices`: `_odatasync._tcp`) and says why it uses the local
network (`NSLocalNetworkUsageDescription`).

## 5. Where it runs

- **iOS** builds HTTPServerKit, ODataService, and all of ODataSync.
- **HTTPServerKit** signs JWS (ES256) as well as checking it:
  `HSGenerateSigningKey`, `HSPublicKey`, `HSSignJWT`. It uses the Security
  framework on Apple and gnutls on GNUstep.
- **ODataSyncService** issues peer tokens (`peerTokens`, the `PeerToken`
  action) on every platform.
- **ODataSync**: the identity, listener, trust, transport and discovery
  run on Apple platforms and on GNUstep (Linux):

  | | Apple | GNUstep |
  |---|---|---|
  | identity | keychain (Security) | PEM files (GnuTLS), `+identityNamed:directory:error:` |
  | listener | Network.framework | GnuTLS over sockets, a thread a connection |
  | transport | URLSession | libcurl (GnuTLS), the peer's key pinned |
  | discovery | `dns_sd` | Avahi's `dns_sd` compatibility library |

  Each column is a directory of ODataSync's, `apple/` and `linux/`, behind
  a private interface (`ODSSystem.h`); the build picks one, and the rest
  of the code does not ask which system it is on. HTTPServerKit's JWS
  signatures are split the same way (`HSSignatureSystem.h`).

  On Linux, discovery takes `avahi-daemon` running, and the system D-Bus
  it talks to (a desktop has both; a container starts them). The library
  warns, once, that a program uses it: set `AVAHI_COMPAT_NOWARN=1` to
  quiet it. A peer's host is looked up as an IPv4 address through Avahi,
  so no nss-mdns is needed. Packages: `libavahi-compat-libdnssd-dev` to
  build, `libavahi-compat-libdnssd1` and `avahi-daemon` to run.
- **The Device apps**, on iOS (a Peers tab) and on the desktop, macOS and
  Linux (a Peers window):
  - a token from the Workbench;
  - Serve to Peers, on port 8642;
  - the devices found nearby (a tap, or a double-click, syncs);
  - a pairing code, shown as a QR code, or scanned (iOS) or pasted;
  - the devices paired.

  See [the iOS app](../Examples/Device/README.md) and [the desktop
  app](../Examples/DeviceDesktop/README.md). The desktop app's self-test
  (`DeviceDesktop --self-test <Workbench root>`) runs peer sync end to end,
  on macOS and Linux, in CI; its `--serve` and `--sync-with` drive peers
  from a terminal, between machines.

## 6. Limits

- A peer serves while its app runs. iOS suspends the app's listener in
  the background.
- On GNUstep, discovery finds peers by IPv4 address only.
- A 403 from a peer, such as one for scopes, may surface on the client as
  -1206 (see 3.2).
- The listener relays to a server on loopback. The connection's certificate
  is known to the server by the relayed connection's local address, so
  only the peer server's own pipeline (HSAuthenticationStage) sees it.
- Revocation is by expiry, not by a list.
- `GET $peer` gives the device's token to any client that connects with a
  certificate: bound to the device's certificate it is of no use to
  another, but it tells the user, the replica and the scopes.
- The Linux listener relays at most 64 connections at once; a connection
  idle for five minutes is closed.
