// ois-serve — a Core Data store served over OData.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
//   ois-serve -Config service.plist
//   ois-serve -Model Catalog.momd -StoreType SQLite -StoreURL file:///var/lib/catalog.sqlite \
//             -ServiceRoot https://api.example.com/odata/ -Port 8080
//
// Settings come from the property list -Config names, and any of them can
// be given on the command line instead, which wins:
//
//   Model         the compiled model (.momd, .mom; on GNUstep an
//                 .xcdatamodeld too)
//   StoreType     SQLite, InMemory, XML, Binary (Apple only), or a store type a linked
//                 or loaded backend registers (CDPostgreSQLStore, ...)
//   StoreURL      the store's URL; a plain path is a file
//   StoreOptions  a dictionary, handed to the coordinator as it is
//   ServiceRoot   the public URL of the service, which its links begin with
//                 (default http://127.0.0.1:<Port>/odata/)
//   Port          default 8080
//   Localhost     YES (the default): listen on loopback only, for a proxy
//                 on the same machine
//   MaxPageSize   server-driven paging, 0 for none
//   MaxVersion    4.01 (default) or 4.0
//   Namespace, Container   the names $metadata gives the schema
//   TrustedUserHeader   who is asking, from this header the proxy sets once
//                 it has signed them in with the identity provider
//                 (X-Forwarded-User from oauth2-proxy, Remote-User from
//                 Authelia); a request without it is answered 401. Unset
//                 (the default): no one is asked. See HSAuthentication.h
//   TrustedClaimHeaders   a dictionary, claim name to header (default:
//                 email, preferred_username, groups from X-Forwarded-*)
//   ProxySecretHeader, ProxySecretEnvironment   a header the proxy adds,
//                 and the environment variable holding the secret it
//                 carries: a request without it did not come through the
//                 proxy
//   JWTIssuer, JWTAudience   instead of a proxy: who is asking, from the
//                 access token the client sends (Authorization: Bearer), a
//                 JWT from this issuer (as its iss has it) for this
//                 audience, checked with the keys the issuer's discovery
//                 document names
//   JWTKeysURL    the issuer's JWK Set, when discovery is not to be used
//   IntrospectionEndpoint, IntrospectionClientID,
//   IntrospectionSecretEnvironment   or: any access token, checked by
//                 asking the provider (RFC 7662) as this client, its secret
//                 in the environment variable named
//   RequiredScopes  scopes every token needs (JWT or introspection)
//   AllowAnonymous  YES: a request that names no one is answered too, as
//                 no one's
//   HealthPath    GET here answers whether it is up (default /health;
//                 empty for none)
//   AccessLog     YES (the default): a line per request on standard error
//   Bundles       paths of bundles to load; a principal class that
//                 conforms to ODataServiceConfiguring is sent
//                 +configureService: before the first request, to register
//                 handlers and set serviceOperations; one that is an
//                 HSApplication subclass is the application, and
//                 can add routes and pipeline stages too; an operation the
//                 service cannot declare stops it from starting
//   Permissions   a permissions file: who may see and change which rows
//                 (docs/permissions.md); check one with odatakit-permissions
//   PrintMetadata YES: write $metadata to standard output and exit
//
// It serves until SIGINT or SIGTERM, logs to standard error, and exits 0
// on a clean stop, 1 on a configuration it cannot use.
//
// All of it is HSMain (HTTPServerKit's HSApplication.h) with
// ODataServerApplication (ODataService's ODataServer.h): an application
// with routes and stages of its own calls that from its own main, with its
// ODataServerApplication subclass.

#import <ODataService/ODataServer.h>

int main(int argc, const char *argv[])
{
  return HSMain(argc, argv, [ODataServerApplication class]);
}
