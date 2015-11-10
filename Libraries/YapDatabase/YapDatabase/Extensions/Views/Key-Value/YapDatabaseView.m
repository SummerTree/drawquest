#import "YapDatabaseView.h"
#import "YapDatabaseViewPrivate.h"

#import "YapAbstractDatabasePrivate.h"
#import "YapAbstractDatabaseExtensionPrivate.h"

#import "YapDatabase.h"
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


@implementation YapDatabaseView

+ (void)dropTablesForRegisteredName:(NSString *)registeredName
                    withTransaction:(YapAbstractDatabaseTransaction *)transaction
{
	sqlite3 *db = transaction->abstractConnection->db;
	
	NSString *mapTableName = [self mapTableNameForRegisteredName:registeredName];
	NSString *pageTableName = [self pageTableNameForRegisteredName:registeredName];
	
	NSString *dropMapTable = [NSString stringWithFormat:@"DROP TABLE IF EXISTS \"%@\";", mapTableName];
	NSString *dropPageTable = [NSString stringWithFormat:@"DROP TABLE IF EXISTS \"%@\";", pageTableName];
	
	int status;
	
	status = sqlite3_exec(db, [dropMapTable UTF8String], NULL, NULL, NULL);
	if (status != SQLITE_OK)
	{
		YDBLogError(@"%@ - Failed dropping map table (%@): %d %s",
		            THIS_METHOD, mapTableName, status, sqlite3_errmsg(db));
	}
	
	status = sqlite3_exec(db, [dropPageTable UTF8String], NULL, NULL, NULL);
	if (status != SQLITE_OK)
	{
		YDBLogError(@"%@ - Failed dropping page table (%@): %d %s",
		            THIS_METHOD, pageTableName, status, sqlite3_errmsg(db));
	}
}

+ (NSString *)mapTableNameForRegisteredName:(NSString *)registeredName
{
	return [NSString stringWithFormat:@"view_%@_map", registeredName];
}

+ (NSString *)pageTableNameForRegisteredName:(NSString *)registeredName
{
	return [NSString stringWithFormat:@"view_%@_page", registeredName];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Instance
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@synthesize groupingBlock = groupingBlock;
@synthesize sortingBlock = sortingBlock;

@synthesize groupingBlockType = groupingBlockType;
@synthesize sortingBlockType = sortingBlockType;

@synthesize version = version;

- (id)initWithGroupingBlock:(YapDatabaseViewGroupingBlock)inGroupingBlock
          groupingBlockType:(YapDatabaseViewBlockType)inGroupingBlockType
               sortingBlock:(YapDatabaseViewSortingBlock)inSortingBlock
           sortingBlockType:(YapDatabaseViewBlockType)inSortingBlockType
{
	return [self initWithGroupingBlock:inGroupingBlock
	                 groupingBlockType:inGroupingBlockType
	                      sortingBlock:inSortingBlock
	                  sortingBlockType:inSortingBlockType
	                           version:0];
}

- (id)initWithGroupingBlock:(YapDatabaseViewGroupingBlock)inGroupingBlock
          groupingBlockType:(YapDatabaseViewBlockType)inGroupingBlockType
               sortingBlock:(YapDatabaseViewSortingBlock)inSortingBlock
           sortingBlockType:(YapDatabaseViewBlockType)inSortingBlockType
                    version:(int)inVersion
{
	NSAssert(inGroupingBlock != NULL, @"Invalid groupingBlock");
	NSAssert(inSortingBlock != NULL, @"Invalid sortingBlock");
	
	NSAssert(inGroupingBlockType == YapDatabaseViewBlockTypeWithKey ||
	         inGroupingBlockType == YapDatabaseViewBlockTypeWithObject ||
	         inGroupingBlockType == YapDatabaseViewBlockTypeWithMetadata ||
	         inGroupingBlockType == YapDatabaseViewBlockTypeWithRow,
	         @"Invalid groupingBlockType");
	
	NSAssert(inSortingBlockType == YapDatabaseViewBlockTypeWithKey ||
	         inSortingBlockType == YapDatabaseViewBlockTypeWithObject ||
	         inSortingBlockType == YapDatabaseViewBlockTypeWithMetadata ||
	         inSortingBlockType == YapDatabaseViewBlockTypeWithRow,
	         @"Invalid sortingBlockType");
	
	if ((self = [super init]))
	{
		groupingBlock = inGroupingBlock;
		groupingBlockType = inGroupingBlockType;
		
		sortingBlock = inSortingBlock;
		sortingBlockType = inSortingBlockType;
		
		version = inVersion;
	}
	return self;
}

/**
 * Subclasses must implement this method.
 * This method is called during the view registration process to enusre the extension supports the database type.
 *
 * Return YES if the class/instance supports the particular type of database (YapDatabase vs YapCollectionsDatabase).
**/
- (BOOL)supportsDatabase:(YapAbstractDatabase *)database
{
	if ([database isKindOfClass:[YapDatabase class]])
	{
		return YES;
	}
	else
	{
		YDBLogError(@"YapDatabaseView only supports YapDatabase, not YapCollectionsDatabase");
		return NO;
	}
}

- (YapAbstractDatabaseExtensionConnection *)newConnection:(YapAbstractDatabaseConnection *)databaseConnection
{
	return [[YapDatabaseViewConnection alloc] initWithView:self
	                                    databaseConnection:(YapDatabaseConnection *)databaseConnection];
}

- (NSString *)mapTableName
{
	return [[self class] mapTableNameForRegisteredName:self.registeredName];
}

- (NSString *)pageTableName
{
	return [[self class] pageTableNameForRegisteredName:self.registeredName];
}

@end
