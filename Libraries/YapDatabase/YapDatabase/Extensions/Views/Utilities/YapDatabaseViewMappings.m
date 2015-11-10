#import "YapDatabaseViewMappingsPrivate.h"
#import "YapDatabaseViewRangeOptionsPrivate.h"

#import "YapAbstractDatabaseConnection.h"
#import "YapAbstractDatabaseTransaction.h"

#import "YapDatabaseView.h"
#import "YapCollectionsDatabaseViewTransaction.h"

#import "YapDatabaseLogging.h"

#if ! __has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

/**
 * Define log level for this file: OFF, ERROR, WARN, INFO, VERBOSE
 * See YapDatabaseLogging.h for more information.
**/
#if DEBUG
  static const int ydbLogLevel = YDB_LOG_LEVEL_WARN;
#else
  static const int ydbLogLevel = YDB_LOG_LEVEL_WARN;
#endif


@implementation YapDatabaseViewMappings
{
	// Immutable init parameters
	NSArray *allGroups;
	NSString *registeredViewName;
	
	// Mappings and cached counts
	NSMutableArray *visibleGroups;
	NSMutableDictionary *counts;
	
	// Configuration
	NSMutableSet *dynamicSections;
	NSMutableSet *reverse;
	NSMutableDictionary *rangeOptions;
	NSMutableDictionary *dependencies;
	
	// Snapshot (used for error detection)
	uint64_t snapshotOfLastUpdate;
}

@synthesize allGroups = allGroups;
@synthesize view = registeredViewName;

@synthesize snapshotOfLastUpdate = snapshotOfLastUpdate;

- (id)initWithGroups:(NSArray *)inGroups
                view:(NSString *)inRegisteredViewName
{
	if ((self = [super init]))
	{
		allGroups = [[NSArray alloc] initWithArray:inGroups copyItems:YES];
		registeredViewName = [inRegisteredViewName copy];
		
		id sharedKeySet = [NSDictionary sharedKeySetForKeys:allGroups];
		
		visibleGroups = [[NSMutableArray alloc] initWithCapacity:[allGroups count]];
		counts = [NSMutableDictionary dictionaryWithSharedKeySet:sharedKeySet];
		
		dynamicSections = [[NSMutableSet alloc] initWithCapacity:[allGroups count]];
		reverse         = [[NSMutableSet alloc] initWithCapacity:[allGroups count]];
		rangeOptions = [NSMutableDictionary dictionaryWithSharedKeySet:sharedKeySet];
		dependencies = [NSMutableDictionary dictionaryWithSharedKeySet:sharedKeySet];
		
		snapshotOfLastUpdate = UINT64_MAX;
	}
	return self;
}

- (id)copyWithZone:(NSZone *)zone
{
	YapDatabaseViewMappings *copy = [[YapDatabaseViewMappings alloc] init];
	copy->allGroups = allGroups;
	copy->registeredViewName = registeredViewName;
	
	copy->visibleGroups = [visibleGroups mutableCopy];
	copy->counts = [counts mutableCopy];
	
	copy->dynamicSections = [dynamicSections mutableCopy];
	copy->reverse = [reverse mutableCopy];
	copy->rangeOptions = [rangeOptions mutableCopy];
	copy->dependencies = [dependencies mutableCopy];
	
	copy->snapshotOfLastUpdate = snapshotOfLastUpdate;
	
	return copy;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Configuration
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (BOOL)isDynamicSectionForAllGroups
{
	return ([dynamicSections count] == [allGroups count]);
}

- (void)setIsDynamicSectionForAllGroups:(BOOL)isDynamic
{
	if (isDynamic)
		[dynamicSections addObjectsFromArray:allGroups];
	else
		[dynamicSections removeAllObjects];
}

- (BOOL)isDynamicSectionForGroup:(NSString *)group
{
	return [dynamicSections containsObject:group];
}

- (void)setIsDynamicSection:(BOOL)isDynamic forGroup:(NSString *)group
{
	if (![allGroups containsObject:group]) {
		YDBLogWarn(@"%@ - mappings doesn't contain group(%@), only: %@", THIS_METHOD, group, allGroups);
		return;
	}
	
	if (isDynamic)
		[dynamicSections addObject:group];
	else
		[dynamicSections removeObject:group];
}

- (void)setRangeOptions:(YapDatabaseViewRangeOptions *)rangeOpts forGroup:(NSString *)group
{
	if (rangeOpts == nil) {
		[self removeRangeOptionsForGroup:group];
		return;
	}
	
	if (![allGroups containsObject:group]) {
		YDBLogWarn(@"%@ - mappings doesn't contain group(%@), only: %@", THIS_METHOD, group, allGroups);
		return;
	}
	
	// Store private immutable copy
	if ([reverse containsObject:group])
		rangeOpts = [rangeOpts copyAndReverse];
	else
		rangeOpts = [rangeOpts copy];
	
	if (snapshotOfLastUpdate == UINT64_MAX)
	{
		// We don't have the counts yet, so we can't set rangeOpts.length yet.
		
		[rangeOptions setObject:rangeOpts forKey:group];
	}
	else
	{
		// Normal setter logic
		
		[self updateRangeOptions:rangeOpts forGroup:group];
		[self updateVisibilityForGroup:group];
	}
}

- (YapDatabaseViewRangeOptions *)rangeOptionsForGroup:(NSString *)group
{
	YapDatabaseViewRangeOptions *rangeOpts = [rangeOptions objectForKey:group];
	
	// Return copy. Our internal version must remain immutable.
	
	if ([reverse containsObject:group])
		return [rangeOpts copyAndReverse];
	else
		return [rangeOpts copy];
}

- (void)removeRangeOptionsForGroup:(NSString *)group
{
	[rangeOptions removeObjectForKey:group];
}

- (void)setCellDrawingDependencyForNeighboringCellWithOffset:(NSInteger)offset forGroup:(NSString *)group
{
	[self setCellDrawingDependencyOffsets:[NSSet setWithObject:@(offset)] forGroup:group];
}

- (void)setCellDrawingDependencyOffsets:(NSSet *)offsets forGroup:(NSString *)group
{
	if (![allGroups containsObject:group]) {
		YDBLogWarn(@"%@ - mappings doesn't contain group(%@), only: %@", THIS_METHOD, group, allGroups);
		return;
	}

	NSMutableSet *validOffsets = [NSMutableSet setWithCapacity:[offsets count]];
	BOOL needsReverse = [reverse containsObject:group];
	
	for (id obj in offsets)
	{
		if ([obj isKindOfClass:[NSNumber class]])
		{
			NSInteger offset = [obj integerValue];
			if (offset != 0)
			{
				if (needsReverse)
					[validOffsets addObject:@(offset * -1)];
				else
					[validOffsets addObject:obj];
			}
		}
		else
		{
			YDBLogWarn(@"%@ - Non-NSNumber passed in offsets: %@", THIS_METHOD, obj);
		}
	}

	[dependencies setObject:[validOffsets copy] forKey:group];
}

- (NSSet *)cellDrawingDependencyOffsetsForGroup:(NSString *)group
{
	NSSet *offsets = [dependencies objectForKey:group];
	
	if ([reverse containsObject:group])
	{
		NSMutableSet *reverseOffsets = [NSMutableSet setWithCapacity:[offsets count]];
		for (NSNumber *obj in offsets)
		{
			NSUInteger offset = [obj integerValue];
			[reverseOffsets addObject:@(offset * -1)];
		}
		
		return [reverseOffsets copy];
	}
	else
	{
		return offsets;
	}
}

- (BOOL)isReversedForGroup:(NSString *)group
{
	return [reverse containsObject:group];
}

- (void)setIsReversed:(BOOL)isReversed forGroup:(NSString *)group
{
	if (![allGroups containsObject:group]) {
		YDBLogWarn(@"%@ - mappings doesn't contain group(%@), only: %@", THIS_METHOD, group, allGroups);
		return;
	}
	
	if (isReversed)
		[reverse addObject:group];
	else
		[reverse removeObject:group];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Initialization & Updates
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)updateWithTransaction:(YapAbstractDatabaseTransaction *)transaction
{
	for (NSString *group in allGroups)
	{
		NSUInteger count = [[transaction ext:registeredViewName] numberOfKeysInGroup:group];
		
		[counts setObject:@(count) forKey:group];
	}
	
	BOOL firstUpdate = (snapshotOfLastUpdate == UINT64_MAX);
	snapshotOfLastUpdate = transaction.abstractConnection.snapshot;
	
	if (firstUpdate)
		[self initializeRangeOptsLength];
	
	[self updateVisibility];
}

/**
 * This method is internal.
 * It is only for use by the unit tests in TestViewChangeLogic.
**/
- (void)updateWithCounts:(NSDictionary *)newCounts
{
	for (NSString *group in allGroups)
	{
		NSUInteger count = [[newCounts objectForKey:group] unsignedIntegerValue];
		
		[counts setObject:@(count) forKey:group];
	}
	
	BOOL firstUpdate = (snapshotOfLastUpdate == UINT64_MAX);
	snapshotOfLastUpdate = 0;
	
	if (firstUpdate)
		[self initializeRangeOptsLength];
	
	[self updateVisibility];
}

- (void)initializeRangeOptsLength
{
	NSAssert(snapshotOfLastUpdate != UINT64_MAX, @"The counts are needed to set rangeOpts.length");
	
	for (NSString *group in [rangeOptions allKeys])
	{
		YapDatabaseViewRangeOptions *rangeOpts = [rangeOptions objectForKey:group];
		
		// Go through the internal setter again so all the logic is in the same place.
		[self updateRangeOptions:rangeOpts forGroup:group];
	}
}

- (void)updateRangeOptions:(YapDatabaseViewRangeOptions *)rangeOpts forGroup:(NSString *)group
{
	// Set a valid rangeOpts.length using the known group count
	
	NSUInteger count = [[counts objectForKey:group] unsignedIntegerValue];
	
	NSUInteger desiredLength = rangeOpts.length;
	NSUInteger offset = rangeOpts.offset;
	
	NSUInteger maxLength = (offset >= count) ? 0 : count - offset;
	NSUInteger length = MIN(desiredLength, maxLength);
	
	// Store private immutable copy
	rangeOpts = [rangeOpts copyWithNewLength:length];
	[rangeOptions setObject:rangeOpts forKey:group];
}

/**
 * This method is used by YapDatabaseViewChange.
 *
 * After processing changeset(s), the length and/or offset may change.
 * The new length and/or offsets are properly calculated,
 * and then this method is used to avoid duplicating the calculations.
**/
- (void)updateRangeOptionsForGroup:(NSString *)group withNewLength:(NSUInteger)newLength newOffset:(NSUInteger)newOffset
{
	YapDatabaseViewRangeOptions *rangeOpts = [rangeOptions objectForKey:group];
	rangeOpts = [rangeOpts copyWithNewLength:newLength newOffset:newOffset];
	
	[rangeOptions setObject:rangeOpts forKey:group];
}

- (void)updateVisibility
{
	[visibleGroups removeAllObjects];
	
	for (NSString *group in allGroups)
	{
		NSUInteger count;
		
		YapDatabaseViewRangeOptions *rangeOpts = [rangeOptions objectForKey:group];
		if (rangeOpts)
			count = rangeOpts.length;
		else
			count = [[counts objectForKey:group] unsignedIntegerValue];
		
		if (count > 0 || ![dynamicSections containsObject:group])
			[visibleGroups addObject:group];
	}
}

- (void)updateVisibilityForGroup:(NSString *)group
{
	NSUInteger count;
	
	YapDatabaseViewRangeOptions *rangeOpts = [rangeOptions objectForKey:group];
	if (rangeOpts)
		count = rangeOpts.length;
	else
		count = [[counts objectForKey:group] unsignedIntegerValue];
	
	if (count > 0 || ![dynamicSections containsObject:group])
		[visibleGroups addObject:group];
	else
		[visibleGroups removeObject:group];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Internal
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSMutableDictionary *)counts
{
	return [counts mutableCopy];
}

- (NSUInteger)fullCountForGroup:(NSString *)group
{
	return [[counts objectForKey:group] unsignedIntegerValue];
}

- (NSUInteger)visibleCountForGroup:(NSString *)group
{
	return [self numberOfItemsInGroup:group];
}

- (NSDictionary *)rangeOptions
{
	return [rangeOptions copy];
}

- (NSDictionary *)dependencies
{
	return [dependencies copy];
}

- (NSSet *)reverse
{
	return [reverse copy];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Mappings
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSUInteger)numberOfSections
{
	return [visibleGroups count];
}

- (NSUInteger)numberOfItemsInSection:(NSUInteger)section
{
	return [self numberOfItemsInGroup:[self groupForSection:section]];
}

- (NSUInteger)numberOfItemsInGroup:(NSString *)group
{
	if (group == nil) return 0;
	if (snapshotOfLastUpdate == UINT64_MAX) return 0;
	
	YapDatabaseViewRangeOptions *rangeOpts = [rangeOptions objectForKey:group];
	if (rangeOpts)
	{
		return rangeOpts.length;
	}
	else
	{
		return [[counts objectForKey:group] unsignedIntegerValue];
	}
}

- (NSString *)groupForSection:(NSUInteger)section
{
	if (section < [visibleGroups count])
		return [visibleGroups objectAtIndex:section];
	else
		return nil;
}

- (NSUInteger)sectionForGroup:(NSString *)group
{
	NSUInteger section = 0;
	for (NSString *visibleGroup in visibleGroups)
	{
		if ([visibleGroup isEqualToString:group])
		{
			return section;
		}
		section++;
	}
	
	return NSNotFound;
}

- (NSArray *)visibleGroups
{
	return [visibleGroups copy];
}

- (BOOL)getGroup:(NSString **)groupPtr index:(NSUInteger *)indexPtr forIndexPath:(NSIndexPath *)indexPath
{
  #if TARGET_OS_IPHONE
	NSUInteger section = indexPath.section;
	NSUInteger row = indexPath.row;
  #else
	NSUInteger section = [indexPath indexAtPosition:0];
	NSUInteger row = [indexPath indexAtPosition:1];
  #endif
	
	NSString *group = [self groupForSection:section];
	if (group == nil)
	{
		if (groupPtr) *groupPtr = nil;
		if (indexPtr) *indexPtr = NSNotFound;
		
		return NO;
	}
	
	NSUInteger index = [self indexForRow:row inGroup:group];
	
	if (groupPtr) *groupPtr = group;
	if (indexPtr) *indexPtr = index;
	
	return (index != NSNotFound);
}

- (NSUInteger)indexForRow:(NSUInteger)row inSection:(NSUInteger)section
{
	return [self indexForRow:row inGroup:[self groupForSection:section]];
}

- (NSUInteger)indexForRow:(NSUInteger)row inGroup:(NSString *)group
{
	if (group == nil) return NSNotFound;
	
	YapDatabaseViewRangeOptions *rangeOpts = [rangeOptions objectForKey:group];
	if (rangeOpts)
	{
		if (rangeOpts.pin == YapDatabaseViewBeginning)
		{
			// Offset is from beginning (index zero)
			
			return (rangeOpts.offset + row);
		}
		else // if (rangeOpts.pin == YapDatabaseViewEnd)
		{
			// Offset is from end (index last)
			
			NSUInteger count = [self fullCountForGroup:group];
			NSUInteger reverseOffset = rangeOpts.offset + rangeOpts.length;
			
			if (reverseOffset <= count)
			{
				return ((count - reverseOffset) + row);
			}
			else
			{
				return NSNotFound;
			}
		}
	}
	else
	{
		return row;
	}
}

- (YapDatabaseViewRangePosition)rangePositionForGroup:(NSString *)group;
{
	if (group == nil)
	{
		return (YapDatabaseViewRangePosition){
			.offsetFromBeginning = 0,
			.offsetFromEnd = 0,
			.length = 0
		};
	}
	
	NSUInteger groupCount = [[counts objectForKey:group] unsignedIntegerValue];
	
	YapDatabaseViewRangeOptions *rangeOpts = [rangeOptions objectForKey:group];
	YapDatabaseViewRangePosition rangePosition;
	
	if (rangeOpts)
	{
		NSUInteger rangeOffset = rangeOpts.offset;
		NSUInteger rangeLength = rangeOpts.length;
		
		if (rangeOpts.pin == YapDatabaseViewBeginning)
		{
			// Offset is from beginning (index zero)
			
			NSUInteger reverseOffset = rangeOffset + rangeLength;
			
			if (reverseOffset <= groupCount)
			{
				// Valid range
				
				rangePosition = (YapDatabaseViewRangePosition){
					.offsetFromBeginning = rangeOffset,
					.offsetFromEnd = groupCount - reverseOffset,
					.length = rangeLength
				};
			}
			else
			{
				// Range fell off the backside
				
				rangePosition = (YapDatabaseViewRangePosition){
					.offsetFromBeginning = rangeOffset,
					.offsetFromEnd = 0,
					.length = 0
				};
			}
		}
		else
		{
			// Offset is from end (index last)
			
			NSUInteger reverseOffset = rangeOffset + rangeLength;
			
			if (reverseOffset <= groupCount)
			{
				// Valid range
				
				rangePosition = (YapDatabaseViewRangePosition){
					.offsetFromBeginning = groupCount - reverseOffset,
					.offsetFromEnd = rangeOffset,
					.length = rangeLength
				};
			}
			else
			{
				// Range fell off the backside
				
				rangePosition = (YapDatabaseViewRangePosition){
					.offsetFromBeginning = 0,
					.offsetFromEnd = rangeOffset,
					.length = 0,
				};
			}
		}
	}
	else
	{
		rangePosition = (YapDatabaseViewRangePosition){
			.offsetFromBeginning = 0,
			.offsetFromEnd = 0,
			.length = groupCount
		};
	}
	
	if ([reverse containsObject:group])
	{
		NSUInteger swap = rangePosition.offsetFromEnd;
		rangePosition.offsetFromEnd = rangePosition.offsetFromBeginning;
		rangePosition.offsetFromBeginning = swap;
	}
	
	return rangePosition;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Logging
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSString *)description
{
	NSMutableString *description = [NSMutableString string];
	[description appendFormat:@"<YapDatabaseViewMappings[%p]: view(%@)\n", self, registeredViewName];
	
	NSUInteger i = 0;
	NSString *visibleGroup = ([visibleGroups count] > 0) ? [visibleGroups objectAtIndex:0] : nil;
	
	for (NSString *group in allGroups)
	{
		if ([group isEqualToString:visibleGroup])
		{
			[description appendFormat:@"  section(%lu) count(%@) group(%@)\n",
			                              (unsigned long)i, [counts objectForKey:group], group];
			
			i++;
			visibleGroup = ([visibleGroups count] > i) ? [visibleGroups objectAtIndex:i] : nil;
		}
		else
		{
			[description appendFormat:@"  section(-) count(%@) group(%@)\n",
			                              [counts objectForKey:group], group];
		}
	}
	
	[description appendString:@">"];
	
	return description;
}

@end
