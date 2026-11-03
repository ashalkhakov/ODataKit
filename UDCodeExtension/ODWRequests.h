// An .odata document's requests, written as VS Code's REST Client writes
// them (.http): each a request line (METHOD URL, the method GET when left
// out; the URL the service root's when it is relative, with query lines
// after it that begin with ? or &), its headers (Name: value), a blank line
// and its body; requests apart by a line beginning ###; lines beginning #
// or // are comments.
//
//   GET Products?$filter=UnitPrice gt 20
//     &$expand=Category&$top=10
//
//   ###
//   PATCH Products(1)
//   Content-Type: application/json
//
//   { "UnitPrice": 19.5 }
//
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ODWRequest : NSObject
// GET when the line names none.
@property (nonatomic, readonly, copy) NSString *method;
// As written, its query lines joined to it.
@property (nonatomic, readonly, copy) NSString *target;
// In the order written; a name written twice, the last.
@property (nonatomic, readonly, copy) NSArray<NSArray<NSString *> *> *headers;
@property (nonatomic, readonly, copy, nullable) NSString *body;
// Where it is in the text: from its first line (a separator's, or the
// request line's when it has none) to the end of its body.
@property (nonatomic, readonly) NSRange range;
// Its request line, from 1.
@property (nonatomic, readonly) NSUInteger line;
// The name its separator gives it (### Cheap products), else its method
// and target.
@property (nonatomic, readonly, copy) NSString *title;

// The request, its URL resolved against the service root (a relative one;
// an absolute one as it is), spaces in its query encoded; nil, and why,
// when its URL is no URL.
- (nullable NSURLRequest *)URLRequestWithServiceRoot:(NSURL *)root error:(NSString *_Nullable *_Nullable)error;
@end

// The text's requests, first to last; a part with no request line (only
// comments, or nothing) is none.
FOUNDATION_EXPORT NSArray<ODWRequest *> *ODWRequestsOfText(NSString *text);
// The request a caret (or the start of a selection) is in; else the last
// one before it; nil when the text has none.
FOUNDATION_EXPORT ODWRequest *_Nullable ODWRequestAt(NSString *text, NSUInteger location);

NS_ASSUME_NONNULL_END
