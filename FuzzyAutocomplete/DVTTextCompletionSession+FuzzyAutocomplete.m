//
//  DVTTextCompletionSession+FuzzyAutocomplete.m
//  FuzzyAutocomplete
//
//  Created by Jack Chen on 19/10/2013.
//  Copyright (c) 2013 Sproutcube. All rights reserved.
//

#import "DVTTextCompletionSession+FuzzyAutocomplete.h"
#import "DVTTextCompletionInlinePreviewController.h"
#import "DVTTextCompletionListWindowController.h"
#import "IDEIndexCompletionItem.h"
#import "IDEOpenQuicklyPattern.h"
#import "SCTiming.h"
#import "JRSwizzle.h"
#import <objc/runtime.h>

#define MINIMUM_SCORE_THRESHOLD         (3)
#define REMOVAL_SCORE                   (2)
#define XCODE_PRIORITY_FACTOR_WEIGHTING (0.2)

static char filteredCompletionCacheKey;

@implementation DVTTextCompletionSession (FuzzyAutocomplete)

+ (void)load
{
	[self swizzleMethodWithErrorLogging:@selector(_setFilteringPrefix:forceFilter:)withMethod:@selector(_fa_setFilteringPrefix:forceFilter:)];
	[self swizzleMethodWithErrorLogging:@selector(setAllCompletions:)withMethod:@selector(_fa_setAllCompletions:)];
	[self swizzleMethodWithErrorLogging:@selector(insertCurrentCompletion)withMethod:@selector(_fa_insertCurrentCompletion)];
	[self swizzleMethodWithErrorLogging:@selector(insertUsefulPrefix)withMethod:@selector(_fa_insertUsefulPrefix)];
}

+ (void)swizzleMethodWithErrorLogging:(SEL)originalMethod withMethod:(SEL)secondMethod
{
	NSError *error;
	[self jr_swizzleMethod:originalMethod withMethod:secondMethod error:&error];
	if (error) {
		ALog(@"Error while swizzling %@: %@", NSStringFromSelector(originalMethod), error);
	}
}

static char lastResultSetKey;
static char lastPrefixKey;
static char insertingCompletionKey;

- (BOOL)_fa_insertUsefulPrefix
{
	return [self insertCurrentCompletion];
}

- (BOOL)_fa_insertCurrentCompletion
{
	[self setInsertingCurrentCompletion:YES];
	return [self _fa_insertCurrentCompletion];
}

- (void)setInsertingCurrentCompletion:(BOOL)value
{
	objc_setAssociatedObject(self, &insertingCompletionKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)_fa_setFilteringPrefix:(NSString *)prefix forceFilter:(BOOL)forceFilter
{
	// Let the original handler deal with the zero and one letter cases
    
	if (prefix.length <= 1) {
		[self _fa_setFilteringPrefix:prefix forceFilter:forceFilter];
		return;
	}
    
	@try {
        
		NSNumber *insertingCompletion = objc_getAssociatedObject(self, &insertingCompletionKey);
        
		// Due to how the KVO is set up, inserting a completion actually triggers another filter event so we nullify it here
		if (insertingCompletion && insertingCompletion.boolValue) {
			[self setInsertingCurrentCompletion:NO];
			return;
		}
        
		NSString *lastPrefix = objc_getAssociatedObject(self, &lastPrefixKey);
		NSArray *searchSet;
        
		// Use the last result set to filter down if it exists
		if (lastPrefix && [prefix rangeOfString:lastPrefix].location == 0) {
			searchSet = objc_getAssociatedObject(self, &lastResultSetKey);
		}
        
		if (searchSet == nil) {
			searchSet = [self filteredCompletionsBeginningWithCharacter:[prefix substringToIndex:1]];
		}
        
		IDEIndexCompletionItem *originalMatch;
        
		__block IDEIndexCompletionItem *bestMatch;
        
		if (self.selectedCompletionIndex < self.filteredCompletionsAlpha.count) {
			originalMatch = self.filteredCompletionsAlpha[self.selectedCompletionIndex];
		}
        
		NSMutableArray *filteredArray = [NSMutableArray array];
        
		IDEOpenQuicklyPattern *pattern = [IDEOpenQuicklyPattern patternWithInput:prefix];
        
		__block double highScore = 0.0f;
        
		[searchSet enumerateObjectsUsingBlock: ^(IDEIndexCompletionItem *item, NSUInteger idx, BOOL *stop) {
            
            double itemPriority = MAX(item.priority, 1);
            double invertedPriority = 1 + (1.0f / itemPriority);
            double priorityFactor = (MAX([self _priorityFactorForItem:item], 1) - 1) * XCODE_PRIORITY_FACTOR_WEIGHTING + 1;
            double score = [pattern scoreCandidate:item.name] * invertedPriority * priorityFactor;
            
            if ([item.name.lowercaseString isEqualToString:prefix.lowercaseString]) score *= 10;
            
            // Items to not remove, but to not prefer either
            //                if ([item.name rangeOfString:@"Nil"].location == NSNotFound) {
            //                    score /= 0.5;
            //                    score = MAX(score, 1);
            //                }
            
            if (score > MINIMUM_SCORE_THRESHOLD) {
                [filteredArray addObject:item];
            }
            
            if (score > highScore) {
                bestMatch = item;
                highScore = score;
            }
            
        }];
        
		self.filteredCompletionsAlpha = filteredArray;
        
		objc_setAssociatedObject(self, &lastPrefixKey, prefix, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		objc_setAssociatedObject(self, &lastResultSetKey, filteredArray, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
		if (filteredArray.count > 0 && bestMatch) {
			self.selectedCompletionIndex = [filteredArray indexOfObject:bestMatch];
		} else {
			self.selectedCompletionIndex = NSNotFound;
		}
        
		// IDEIndexCompletionItem doesn't implement isEqual
        
		DVTTextCompletionInlinePreviewController *inlinePreview = [self _inlinePreviewController];
		if ([originalMatch.name isEqual:bestMatch.name] == NO) {
			// Hide the inline preview if the fuzzy query is different to normal matching
			[inlinePreview hideInlinePreviewWithReason:0];
		}
        
		// This forces the completion list to resize the columns
		DVTTextCompletionListWindowController *listController = [self _listWindowController];
		[listController _updateCurrentDisplayState];
        
	}
	@catch (NSException *exception) {
		ALog(@"An exception occurred within FuzzyAutocomplete: %@", exception);
	}
}

- (void)_fa_setAllCompletions:(NSArray *)allCompletions
{
	[self _fa_setAllCompletions:allCompletions];
    
	NSCache *filterCache = objc_getAssociatedObject(self, &filteredCompletionCacheKey);
	if (filterCache) {
		[filterCache removeAllObjects];
	}
}

// We need to cache the first letter sets because if a user types fast enough,
// they don't trigger the standard autocomplete first letter set that we need
// for good performance.

- (NSArray *)filteredCompletionsBeginningWithCharacter:(NSString *)character
{
	NSCache *filteredCompletionCache = objc_getAssociatedObject(self, &filteredCompletionCacheKey);
    
	if (filteredCompletionCache == nil) {
		filteredCompletionCache = [[NSCache alloc] init];
		objc_setAssociatedObject(self, &filteredCompletionCacheKey, filteredCompletionCache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
    
	NSArray *completionsForCharacter = [filteredCompletionCache objectForKey:character];
    
	if (completionsForCharacter == nil) {
        
		completionsForCharacter = [[self.allCompletions filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name beginswith[c] %@ AND (notRecommended = 0)", character]] mutableCopy];
        
		if ([character isEqualToString:@"m"]) {
			completionsForCharacter = [[completionsForCharacter filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"NOT (name contains[cd] %@)", @"mach"]] mutableCopy];
		}
        
		NSMutableArray *arrayWithMatchingSuggestionsRemoved = [NSMutableArray array];
		NSArray *arrayRemoveCompletionSuggestionsMatching = @[@"Nil"];
        
		for (IDEIndexCompletionItem *item in completionsForCharacter) {
			if ([arrayRemoveCompletionSuggestionsMatching containsObject:item.name] == NO) {
				[arrayWithMatchingSuggestionsRemoved addObject:item];
			}
		}
        
		completionsForCharacter = [NSArray arrayWithArray:arrayWithMatchingSuggestionsRemoved];
        
		[filteredCompletionCache setObject:completionsForCharacter forKey:character];
        
	}
    
	return completionsForCharacter;
}

// Used for debugging
- (NSArray *)orderCompletionsByScore:(NSArray *)completions withQuery:(NSString *)query
{
	IDEOpenQuicklyPattern *pattern = [IDEOpenQuicklyPattern patternWithInput:query];
	NSMutableArray *completionsWithScore = [NSMutableArray arrayWithCapacity:completions.count];
    
	[completions enumerateObjectsUsingBlock: ^(IDEIndexCompletionItem *item, NSUInteger idx, BOOL *stop) {
        [completionsWithScore addObject:@{
                                          @"item": item,
                                          @"score": @([pattern scoreCandidate:item.name])
                                          }];
    }];
    
	NSSortDescriptor *sortByScore = [NSSortDescriptor sortDescriptorWithKey:@"score" ascending:NO];
    
    [completionsWithScore sortUsingDescriptors:@[sortByScore]];
    
	return [completionsWithScore valueForKeyPath:@"@unionOfObjects.item"];
}

@end

