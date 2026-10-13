// ODataIncrementalStore — Core Data import.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Apple:   <CoreData/CoreData.h>
// GNUstep: FreeCoreData (https://github.com/ashalkhakov/FreeCoreData)
//          installs the same umbrella after `make install`.

#pragma once

#import "OISRuntime.h"

#if __has_include(<CoreData/CoreData.h>)
#import <CoreData/CoreData.h>
#else
#error "OIS requires Core Data: Apple CoreData.framework, or FreeCoreData on GNUstep (https://github.com/ashalkhakov/FreeCoreData)."
#endif

#ifndef NSUUIDAttributeType
#define NSUUIDAttributeType ((NSAttributeType)2400)
#endif

#ifndef NSCountResultType
#define NSCountResultType ((NSFetchRequestResultType)0x04)
#endif

#ifndef NSManagedObjectConstraintMergeError
#define NSManagedObjectConstraintMergeError 1570
#endif

// The errors one failure collected (a save's, NSValidationMultipleErrorsError's).
// Apple's Core Data, in a program built for macOS 12 or later, files them
// under "NSDetailedErrors", not under NSDetailedErrorsKey's own value
// ("NSDetailedErrorsKey"), where it did before and FreeCoreData does: both
// are looked in.
static inline NSArray<NSError *> *OISDetailedErrors(NSError *error)
{
  id each = error.userInfo[NSDetailedErrorsKey] ?: error.userInfo[@"NSDetailedErrors"];
  return [each isKindOfClass:[NSArray class]] ? each : nil;
}
