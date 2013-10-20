//
//  DVTTextCompletionSession+FuzzyAutocomplete.m
//  FuzzyAutocomplete
//
//  Created by Jack Chen on 19/10/2013.
//  Copyright (c) 2013 chendo interactive. All rights reserved.
//

#import "DVTTextCompletionSession+FuzzyAutocomplete.h"
#import "IDEIndexCompletionItem.h"
#import "IDEOpenQuicklyPattern.h"
#import "SCTiming.h"
#import <objc/runtime.h>
#import <JRSwizzle.h>

@implementation DVTTextCompletionSession (FuzzyAutocomplete)

+ (void)load
{
    [self jr_swizzleMethod:@selector(_setFilteringPrefix:forceFilter:) withMethod:@selector(_fa_setFilteringPrefix:forceFilter:) error:nil];
}

static char lastResultSetKey;
static char lastPrefixKey;

// Sets the current filtering prefix
- (void)_fa_setFilteringPrefix:(NSString *)prefix forceFilter:(BOOL)forceFilter
{
    // We need to call the original method otherwise the autocomplete won't show up
    // TODO: Figure out what we need to call to make the window show
    
    timeBlockAndLog(@"Original filter", ^id{
        [self _fa_setFilteringPrefix:prefix forceFilter:forceFilter];
        return nil;
    });
    
    // We only want to use fuzzy matching when we have 2 or more characters to work with
    if (prefix.length < 2) {
        return;
    }

    NSString *lastPrefix = objc_getAssociatedObject(self, &lastPrefixKey);
    NSArray *searchSet;

    // Use the last result set to filter down if it exists
    if (lastPrefix && [prefix rangeOfString:lastPrefix].location == 0) {
        searchSet = objc_getAssociatedObject(self, &lastResultSetKey);
    }
    else {
        searchSet = self.allCompletions;
    }
    
    objc_setAssociatedObject(self, &lastPrefixKey, prefix, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    double totalTime = timeVoidBlock(^{
        NSMutableString *predicateString = [NSMutableString string];
        [prefix enumerateSubstringsInRange:NSMakeRange(0, prefix.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
            [predicateString appendFormat:@"%@*", substring];
        }];
        
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"name like[c] %@", predicateString];
        
        NSArray *filtered = timeBlockAndLog(@"Filtering", ^id{
            return [searchSet filteredArrayUsingPredicate:predicate];
        });
        
        DLog(@"Filter: %lu to %lu", searchSet.count, (unsigned long)filtered.count);

        NSArray *sorted = timeBlockAndLog(@"Best match time", ^id{
            return [self orderCompletionsByScore:searchSet withQuery:prefix];
        });

        self.filteredCompletionsAlpha = filtered;
        objc_setAssociatedObject(self, &lastResultSetKey, filtered, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (filtered.count > 0) {
            timeBlockAndLog(@"IndexOf", ^id{
                self.selectedCompletionIndex = [filtered indexOfObject:sorted[0]];
                return nil;
            });
        }
    });
    DLog(@"Total time: %f", totalTime);
    
}

- (NSArray *)orderCompletionsByScore:(NSArray *)completions withQuery:(NSString *)query
{
    IDEOpenQuicklyPattern *pattern = [IDEOpenQuicklyPattern patternWithInput:query];
    NSMutableArray *completionsWithScore = [NSMutableArray arrayWithCapacity:completions.count];
    
    timeVoidBlockAndLog(@"Scoring", ^{
        [completions enumerateObjectsUsingBlock:^(IDEIndexCompletionItem *item, NSUInteger idx, BOOL *stop) {
            [completionsWithScore addObject:@{
                                              @"item": item,
                                              @"score": @([pattern scoreCandidate:item.name])}];
        }];
    });
    
    NSSortDescriptor *sortByScore = [NSSortDescriptor sortDescriptorWithKey:@"score" ascending:NO];

    timeVoidBlockAndLog(@"Sorting", ^{
        [completionsWithScore sortUsingDescriptors:@[sortByScore]];
    });
    
    return [completionsWithScore valueForKeyPath:@"@unionOfObjects.item"];
}

@end

