#import "YapDatabaseConnection.h"
#import "YapDatabasePrivate.h"

#import "YapAbstractDatabasePrivate.h"
#import "YapAbstractDatabaseExtensionPrivate.h"

#import "YapCache.h"
#import "YapNull.h"
#import "YapSet.h"

#import "YapDatabaseString.h"
#import "YapDatabaseLogging.h"

#if ! __has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

/**
 * Define log level for this file: OFF, ERROR, WARN, INFO, VERBOSE
 * See YapDatabaseLogging.h for more information.
**/
#if DEBUG
  static const int ydbLogLevel = YDB_LOG_LEVEL_INFO;
#else
  static const int ydbLogLevel = YDB_LOG_LEVEL_WARN;
#endif

/**
 * A connection provides a point of access to the database.
 *
 * You first create and configure a YapDatabase instance.
 * Then you can spawn one or more connections to the database file.
 *
 * Multiple connections can simultaneously read from the database.
 * Multiple connections can simultaneously read from the database while another connection is modifying the database.
 * For example, the main thread could be reading from the database via connection A,
 * while a background thread is writing to the database via connection B.
 *
 * However, only a single connection may be writing to the database at any one time.
 *
 * A connection instance is thread-safe, and operates by serializing access to itself.
 * Thus you can share a single connection between multiple threads.
 * But for conncurrent access between multiple threads you must use multiple connections.
**/
@implementation YapDatabaseConnection {
@private
	
	sqlite3_stmt *getCountStatement;
	sqlite3_stmt *getCountForRowidStatement;
	sqlite3_stmt *getRowidForKeyStatement;
	sqlite3_stmt *getKeyForRowidStatement;
	sqlite3_stmt *getDataForRowidStatement;
	sqlite3_stmt *getMetadataForRowidStatement;
	sqlite3_stmt *getAllForRowidStatement;
	sqlite3_stmt *getDataForKeyStatement;
	sqlite3_stmt *getMetadataForKeyStatement;
	sqlite3_stmt *getAllForKeyStatement;
	sqlite3_stmt *insertForRowidStatement;
	sqlite3_stmt *updateAllForRowidStatement;
	sqlite3_stmt *updateMetadataForRowidStatement;
	sqlite3_stmt *removeForRowidStatement;
	sqlite3_stmt *removeAllStatement;
	sqlite3_stmt *enumerateKeysStatement;
	sqlite3_stmt *enumerateKeysAndMetadataStatement;
	sqlite3_stmt *enumerateKeysAndObjectsStatement;
	sqlite3_stmt *enumerateRowsStatement;
	
/* Defined in YapDatabasePrivate.h:

@public
	NSMutableDictionary *objectChanges;
	NSMutableDictionary *metadataChanges;
	NSMutableSet *removeKeys;
	BOOL allKeysRemoved;

*/
/* Defined in YapAbstractDatabasePrivate.h:

@protected
	dispatch_queue_t connectionQueue;
	void *IsOnConnectionQueueKey;
	
	YapAbstractDatabase *database;
	
@public
	sqlite3 *db;
	
	YapCache *objectCache;
	YapCache *metadataCache;
	
	NSUInteger objectCacheLimit;          // Read-only by transaction. Use as consideration of whether to add to cache.
	NSUInteger metadataCacheLimit;        // Read-only by transaction. Use as consideration of whether to add to cache.
	
	BOOL needsMarkSqlLevelSharedReadLock; // Read-only by transaction. Use as consideration of whether to invoke method.
 
*/
}

@synthesize database = database;

- (id)initWithDatabase:(YapAbstractDatabase *)inDatabase
{
	if ((self = [super initWithDatabase:inDatabase]))
	{
		database = (YapDatabase *)abstractDatabase;
	}
	return self;
}

- (void)dealloc
{
	sqlite_finalize_null(&getCountStatement);
	sqlite_finalize_null(&getCountForRowidStatement);
	sqlite_finalize_null(&getRowidForKeyStatement);
	sqlite_finalize_null(&getKeyForRowidStatement);
	sqlite_finalize_null(&getDataForRowidStatement);
	sqlite_finalize_null(&getMetadataForRowidStatement);
	sqlite_finalize_null(&getAllForRowidStatement);
	sqlite_finalize_null(&getDataForKeyStatement);
	sqlite_finalize_null(&getMetadataForKeyStatement);
	sqlite_finalize_null(&getAllForKeyStatement);
	sqlite_finalize_null(&insertForRowidStatement);
	sqlite_finalize_null(&updateAllForRowidStatement);
	sqlite_finalize_null(&updateMetadataForRowidStatement);
	sqlite_finalize_null(&removeForRowidStatement);
	sqlite_finalize_null(&removeAllStatement);
	sqlite_finalize_null(&enumerateKeysStatement);
	sqlite_finalize_null(&enumerateKeysAndMetadataStatement);
	sqlite_finalize_null(&enumerateKeysAndObjectsStatement);
	sqlite_finalize_null(&enumerateRowsStatement);
}

/**
 * Override hook from YapAbstractDatabaseConnection.
**/
- (void)_flushMemoryWithLevel:(int)level
{
	[super _flushMemoryWithLevel:level];
	
	if (level >= YapDatabaseConnectionFlushMemoryLevelModerate)
	{
		sqlite_finalize_null(&getCountStatement);
		sqlite_finalize_null(&getCountForRowidStatement);
		sqlite_finalize_null(&getDataForRowidStatement);
		sqlite_finalize_null(&getMetadataForRowidStatement);
		sqlite_finalize_null(&getAllForRowidStatement);
		sqlite_finalize_null(&getMetadataForKeyStatement);
		sqlite_finalize_null(&getAllForKeyStatement);
		sqlite_finalize_null(&updateMetadataForRowidStatement);
		sqlite_finalize_null(&removeForRowidStatement);
		sqlite_finalize_null(&removeAllStatement);
		sqlite_finalize_null(&enumerateKeysStatement);
		sqlite_finalize_null(&enumerateKeysAndMetadataStatement);
		sqlite_finalize_null(&enumerateKeysAndObjectsStatement);
		sqlite_finalize_null(&enumerateRowsStatement);
	}
	
	if (level >= YapDatabaseConnectionFlushMemoryLevelFull)
	{
		sqlite_finalize_null(&getRowidForKeyStatement);
		sqlite_finalize_null(&getKeyForRowidStatement);
		sqlite_finalize_null(&getDataForKeyStatement);
		sqlite_finalize_null(&insertForRowidStatement);
		sqlite_finalize_null(&updateAllForRowidStatement);
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Statements
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (sqlite3_stmt *)getCountStatement
{
	if (getCountStatement == NULL)
	{
		char *stmt = "SELECT COUNT(*) AS NumberOfRows FROM \"database2\";";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &getCountStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}
	}
	
	return getCountStatement;
}

- (sqlite3_stmt *)getCountForRowidStatement
{
	if (getCountForRowidStatement == NULL)
	{
		char *stmt = "SELECT COUNT(*) AS NumberOfRows FROM \"database2\" WHERE \"rowid\" = ?;";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &getCountForRowidStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}
	}
	
	return getCountForRowidStatement;
}

- (sqlite3_stmt *)getRowidForKeyStatement
{
	if (getRowidForKeyStatement == NULL)
	{
		char *stmt = "SELECT \"rowid\" FROM \"database2\" WHERE \"key\" = ?;";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &getRowidForKeyStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}
	}
	
	return getRowidForKeyStatement;
}

- (sqlite3_stmt *)getKeyForRowidStatement
{
	if (getKeyForRowidStatement == NULL)
	{
		char *stmt = "SELECT \"key\" FROM \"database2\" WHERE \"rowid\" = ?;";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &getKeyForRowidStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}
	}
	
	return getKeyForRowidStatement;
}

- (sqlite3_stmt *)getDataForRowidStatement
{
	if (getDataForRowidStatement == NULL)
	{
		char *stmt = "SELECT \"key\", \"data\" FROM \"database2\" WHERE \"rowid\" = ?;";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &getDataForRowidStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}
	}
	
	return getDataForRowidStatement;
}

- (sqlite3_stmt *)getMetadataForRowidStatement
{
	if (getMetadataForRowidStatement == NULL)
	{
		char *stmt = "SELECT \"key\", \"metadata\" FROM \"database2\" WHERE \"rowid\" = ?;";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &getMetadataForRowidStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}
	}
	
	return getMetadataForRowidStatement;
}

- (sqlite3_stmt *)getAllForRowidStatement
{
	if (getAllForRowidStatement == NULL)
	{
		char *stmt = "SELECT \"key\", \"data\", \"metadata\" FROM \"database2\" WHERE \"rowid\" = ?;";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &getAllForRowidStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}
	}
	
	return getAllForRowidStatement;
}

- (sqlite3_stmt *)getDataForKeyStatement
{
	if (getDataForKeyStatement == NULL)
	{
		char *stmt = "SELECT \"data\" FROM \"database2\" WHERE \"key\" = ?;";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &getDataForKeyStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}
	}
	
	return getDataForKeyStatement;
}

- (sqlite3_stmt *)getMetadataForKeyStatement
{
	if (getMetadataForKeyStatement == NULL)
	{
		char *stmt = "SELECT \"metadata\" FROM \"database2\" WHERE \"key\" = ?;";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &getMetadataForKeyStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}
	}
	
	return getMetadataForKeyStatement;
}

- (sqlite3_stmt *)getAllForKeyStatement
{
	if (getAllForKeyStatement == NULL)
	{
		char *stmt = "SELECT \"data\", \"metadata\" FROM \"database2\" WHERE \"key\" = ?;";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &getAllForKeyStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}
	}
	
	return getAllForKeyStatement;
}

- (sqlite3_stmt *)insertForRowidStatement
{
	if (insertForRowidStatement == NULL)
	{
		char *stmt = "INSERT INTO \"database2\" (\"key\", \"data\", \"metadata\") VALUES (?, ?, ?);";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &insertForRowidStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}
	}
	
	return insertForRowidStatement;
}

- (sqlite3_stmt *)updateAllForRowidStatement
{
	if (updateAllForRowidStatement == NULL)
	{
		char *stmt = "UPDATE \"database2\" SET \"data\" = ?, \"metadata\" = ? WHERE \"rowid\" = ?;";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &updateAllForRowidStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}
	}
	
	return updateAllForRowidStatement;
}

- (sqlite3_stmt *)updateMetadataForRowidStatement
{
	if (updateMetadataForRowidStatement == NULL)
	{
		char *stmt = "UPDATE \"database2\" SET \"metadata\" = ? WHERE \"rowid\" = ?;";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &updateMetadataForRowidStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}
	}
	
	return updateMetadataForRowidStatement;
}

- (sqlite3_stmt *)removeForRowidStatement
{
	if (removeForRowidStatement == NULL)
	{
		char *stmt = "DELETE FROM \"database2\" WHERE \"rowid\" = ?;";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &removeForRowidStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}
	}
	
	return removeForRowidStatement;
}

- (sqlite3_stmt *)removeAllStatement
{
	if (removeAllStatement == NULL)
	{
		char *stmt = "DELETE FROM \"database2\"";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &removeAllStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}
	}
	
	return removeAllStatement;
}

- (sqlite3_stmt *)enumerateKeysStatement
{
	if (enumerateKeysStatement == NULL)
	{
		char *stmt = "SELECT \"rowid\", \"key\" FROM \"database2\";";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &enumerateKeysStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}

	}
	
	return enumerateKeysStatement;
}

- (sqlite3_stmt *)enumerateKeysAndMetadataStatement
{
	if (enumerateKeysAndMetadataStatement == NULL)
	{
		char *stmt = "SELECT \"rowid\", \"key\", \"metadata\" FROM \"database2\";";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &enumerateKeysAndMetadataStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}
	}
	
	return enumerateKeysAndMetadataStatement;
}

- (sqlite3_stmt *)enumerateKeysAndObjectsStatement
{
	if (enumerateKeysAndObjectsStatement == NULL)
	{
		char *stmt = "SELECT \"rowid\", \"key\", \"data\" FROM \"database2\";";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &enumerateKeysAndObjectsStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}
	}
	
	return enumerateKeysAndObjectsStatement;
}

- (sqlite3_stmt *)enumerateRowsStatement
{
	if (enumerateRowsStatement == NULL)
	{
		char *stmt = "SELECT \"rowid\", \"key\", \"data\", \"metadata\" FROM \"database2\";";
		
		int status = sqlite3_prepare_v2(db, stmt, (int)strlen(stmt)+1, &enumerateRowsStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", NSStringFromSelector(_cmd), status, sqlite3_errmsg(db));
		}
	}
	
	return enumerateRowsStatement;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Access
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Read-only access to the database.
 * 
 * The given block can run concurrently with sibling connections,
 * regardless of whether the sibling connections are executing read-only or read-write transactions.
 *
 * The only time this method ever blocks is if another thread is currently using this connection instance
 * to execute a readBlock or readWriteBlock. Recall that you may create multiple connections for concurrent access.
 *
 * This method is synchronous.
**/
- (void)readWithBlock:(void (^)(YapDatabaseReadTransaction *))block
{
	[super _readWithBlock:block];
}

/**
 * Read-write access to the database.
 *
 * Only a single read-write block can execute among all sibling connections.
 * Thus this method may block if another sibling connection is currently executing a read-write block.
 *
 * This method is synchronous.
**/
- (void)readWriteWithBlock:(void (^)(YapDatabaseReadWriteTransaction *transaction))block
{
	[super _readWriteWithBlock:block];
}

/**
 * Read-only access to the database.
 *
 * The given block can run concurrently with sibling connections,
 * regardless of whether the sibling connections are executing read-only or read-write transactions.
 *
 * This method is asynchronous.
**/
- (void)asyncReadWithBlock:(void (^)(YapDatabaseReadTransaction *transaction))block
{
	[super _asyncReadWithBlock:block completionBlock:NULL completionQueue:NULL];
}

/**
 * Read-only access to the database.
 *
 * The given block can run concurrently with sibling connections,
 * regardless of whether the sibling connections are executing read-only or read-write transactions.
 *
 * This method is asynchronous.
**/
- (void)asyncReadWithBlock:(void (^)(YapDatabaseReadTransaction *transaction))block
           completionBlock:(dispatch_block_t)completionBlock
{
	[super _asyncReadWithBlock:block completionBlock:completionBlock completionQueue:NULL];
}

/**
 * Read-only access to the database.
 *
 * The given block can run concurrently with sibling connections,
 * regardless of whether the sibling connections are executing read-only or read-write transactions.
 *
 * This method is asynchronous.
**/
- (void)asyncReadWithBlock:(void (^)(YapDatabaseReadTransaction *transaction))block
           completionBlock:(dispatch_block_t)completionBlock
           completionQueue:(dispatch_queue_t)completionQueue
{
	[super _asyncReadWithBlock:block completionBlock:completionBlock completionQueue:completionQueue];
}

/**
 * Read-write access to the database.
 *
 * Only a single read-write block can execute among all sibling connections.
 * Thus the execution of the block may be delayted if another sibling connection
 * is currently executing a read-write block.
 *
 * This method is asynchronous.
**/
- (void)asyncReadWriteWithBlock:(void (^)(YapDatabaseReadWriteTransaction *transaction))block
{
	[super _asyncReadWriteWithBlock:block completionBlock:NULL completionQueue:NULL];
}

/**
 * Read-write access to the database.
 *
 * Only a single read-write block can execute among all sibling connections.
 * Thus the execution of the block may be delayted if another sibling connection
 * is currently executing a read-write block.
 *
 * This method is asynchronous.
 *
 * An optional completion block may be used.
 **/
- (void)asyncReadWriteWithBlock:(void (^)(YapDatabaseReadWriteTransaction *transaction))block
                completionBlock:(dispatch_block_t)completionBlock
{
	[super _asyncReadWriteWithBlock:block completionBlock:completionBlock completionQueue:NULL];
}

/**
 * Read-write access to the database.
 *
 * Only a single read-write block can execute among all sibling connections.
 * Thus the execution of the block may be delayted if another sibling connection
 * is currently executing a read-write block.
 *
 * This method is asynchronous.
 * 
 * An optional completion block may be used.
 * Additionally the dispatch_queue to invoke the completion block may also be specified.
 * If NULL, dispatch_get_main_queue() is automatically used.
**/
- (void)asyncReadWriteWithBlock:(void (^)(YapDatabaseReadWriteTransaction *transaction))block
                completionBlock:(dispatch_block_t)completionBlock
                completionQueue:(dispatch_queue_t)completionQueue
{
	[super _asyncReadWriteWithBlock:block completionBlock:completionBlock completionQueue:completionQueue];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark States
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Required method.
 * Returns the proper type of transaction for this connection class.
**/
- (YapAbstractDatabaseTransaction *)newReadTransaction
{
	return [[YapDatabaseReadTransaction alloc] initWithConnection:self isReadWriteTransaction:NO];
}

/**
 * Required method.
 * Returns the proper type of transaction for this connection class.
**/
- (YapAbstractDatabaseTransaction *)newReadWriteTransaction
{
	return [[YapDatabaseReadWriteTransaction alloc] initWithConnection:self isReadWriteTransaction:YES];
}

/**
 * We override this method to setup our changeset variables.
**/
- (void)preReadWriteTransaction:(YapAbstractDatabaseTransaction *)transaction
{
	[super preReadWriteTransaction:transaction];
	
	if (objectChanges == nil)
		objectChanges = [[NSMutableDictionary alloc] init];
	if (metadataChanges == nil)
		metadataChanges = [[NSMutableDictionary alloc] init];
	if (removedKeys == nil)
		removedKeys = [[NSMutableSet alloc] init];
	
	allKeysRemoved = NO;
}

/**
 * We override this method to reset our changeset variables.
**/
- (void)postReadWriteTransaction:(YapAbstractDatabaseTransaction *)transaction
{
	[super postReadWriteTransaction:transaction];
	
	if ([objectChanges count] > 0)
		objectChanges = nil;
	if ([metadataChanges count] > 0)
		metadataChanges = nil;
	if ([removedKeys count] > 0)
		removedKeys = nil;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Changsets
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * The creation of changeset dictionaries happens constantly.
 * So, to optimize a bit, we use sharedKeySet's (part of NSDictionary).
 *
 * Subclasses of YapAbstractDatabase should override this method and add any keys they might use to this set.
 *
 * See ivar 'sharedKeySetForInternalChangeset'
 **/
- (NSArray *)internalChangesetKeys
{
	NSArray *subclassKeys = @[ YapDatabaseObjectChangesKey,
	                           YapDatabaseMetadataChangesKey,
	                           YapDatabaseRemovedKeysKey,
	                           YapDatabaseAllKeysRemovedKey ];
	
	return [[super internalChangesetKeys] arrayByAddingObjectsFromArray:subclassKeys];
}

/**
 * The creation of changeset dictionaries happens constantly.
 * So, to optimize a bit, we use sharedKeySet's (part of NSDictionary).
 *
 * Subclasses of YapAbstractDatabase should override this method and add any keys they might use to this set.
 *
 * See ivar 'sharedKeySetForExternalChangeset'
**/
- (NSArray *)externalChangesetKeys
{
	NSArray *subclassKeys = @[ YapDatabaseObjectChangesKey,
	                           YapDatabaseMetadataChangesKey,
	                           YapDatabaseRemovedKeysKey,
	                           YapDatabaseAllKeysRemovedKey ];
	
	return [[super externalChangesetKeys] arrayByAddingObjectsFromArray:subclassKeys];
}

/**
 * Required override method from YapAbstractDatabaseConnection.
 *
 * This method is invoked from within the postReadWriteTransaction operation.
 * This method is invoked before anything has been committed.
 *
 * If changes have been made, it should return a changeset dictionary.
 * If no changes have been made, it should return nil.
 * 
 * @see processChangeset
**/
- (void)getInternalChangeset:(NSMutableDictionary **)internalChangesetPtr
           externalChangeset:(NSMutableDictionary **)externalChangesetPtr
{
	NSMutableDictionary *internalChangeset = nil;
	NSMutableDictionary *externalChangeset = nil;
	
	[super getInternalChangeset:&internalChangeset externalChangeset:&externalChangeset];
	
	// Reserved keys:
	//
	// - extensions
	// - extensionNames
	// - snapshot
	
	if ([objectChanges count] > 0 || [metadataChanges count] > 0 || [removedKeys count] > 0 || allKeysRemoved)
	{
		if (internalChangeset == nil)
			internalChangeset = [NSMutableDictionary dictionaryWithSharedKeySet:sharedKeySetForInternalChangeset];
		
		if (externalChangeset == nil)
			externalChangeset = [NSMutableDictionary dictionaryWithSharedKeySet:sharedKeySetForExternalChangeset];
		
		if ([objectChanges count] > 0)
		{
			[internalChangeset setObject:objectChanges forKey:YapDatabaseObjectChangesKey];
			
			YapSet *immutableObjectChanges = [[YapSet alloc] initWithDictionary:objectChanges];
			[externalChangeset setObject:immutableObjectChanges forKey:YapDatabaseObjectChangesKey];
		}
		
		if ([metadataChanges count] > 0)
		{
			[internalChangeset setObject:metadataChanges forKey:YapDatabaseMetadataChangesKey];
			
			YapSet *immutableMetadataChanges = [[YapSet alloc] initWithDictionary:metadataChanges];
			[externalChangeset setObject:immutableMetadataChanges forKey:YapDatabaseMetadataChangesKey];
		}
		
		if ([removedKeys count] > 0)
		{
			[internalChangeset setObject:removedKeys forKey:YapDatabaseRemovedKeysKey];
			
			YapSet *immutableRemovedKeys = [[YapSet alloc] initWithSet:removedKeys];
			[externalChangeset setObject:immutableRemovedKeys forKey:YapDatabaseRemovedKeysKey];
		}
		
		if (allKeysRemoved)
		{
			[internalChangeset setObject:@(YES) forKey:YapDatabaseAllKeysRemovedKey];
			[externalChangeset setObject:@(YES) forKey:YapDatabaseAllKeysRemovedKey];
		}
	}
	
	*internalChangesetPtr = internalChangeset;
	*externalChangesetPtr = externalChangeset;
}

/**
 * Required override method from YapAbstractDatabaseConnection.
 *
 * This method is invoked with the changeset from a sibling connection.
 * The connection should update any in-memory components (such as the cache) to properly reflect the changeset.
 * 
 * @see changeset
**/
- (void)processChangeset:(NSDictionary *)changeset
{
	[super processChangeset:changeset];
	
	// Extract changset information
	
	NSDictionary *changeset_objectChanges = [changeset objectForKey:YapDatabaseObjectChangesKey];
	NSDictionary *changeset_metadataChanges = [changeset objectForKey:YapDatabaseMetadataChangesKey];
	
	NSSet *changeset_removedKeys = [changeset objectForKey:YapDatabaseRemovedKeysKey];
	
	BOOL changeset_allKeysRemoved = [[changeset objectForKey:YapDatabaseAllKeysRemovedKey] boolValue];
	
	BOOL hasObjectChanges   = [changeset_objectChanges count] > 0;
	BOOL hasMetadataChanges = [changeset_metadataChanges count] > 0;
	BOOL hasRemovedKeys     = [changeset_removedKeys count] > 0;
	
	// Update objectCache
	
	if (changeset_allKeysRemoved && !hasObjectChanges)
	{
		// Shortcut: Everything was removed from the database
		
		[objectCache removeAllObjects];
	}
	else if (hasObjectChanges && !hasRemovedKeys && !changeset_allKeysRemoved)
	{
		// Shortcut: Nothing was removed from the database.
		// So we can simply enumerate over the changes and update the cache inline as needed.
		
		[changeset_objectChanges enumerateKeysAndObjectsUsingBlock:^(id key, id object, BOOL *stop) {
			
			if ([objectCache containsKey:key])
				[objectCache setObject:object forKey:key];
		}];
	}
	else if (hasObjectChanges || hasRemovedKeys)
	{
		NSUInteger updateCapacity = MIN([objectCache count], [changeset_objectChanges count]);
		NSUInteger removeCapacity = MIN([objectCache count], [changeset_removedKeys count]);
		
		NSMutableArray *keysToUpdate = [NSMutableArray arrayWithCapacity:updateCapacity];
		NSMutableArray *keysToRemove = [NSMutableArray arrayWithCapacity:removeCapacity];
		
		[objectCache enumerateKeysWithBlock:^(id key, BOOL *stop) {
			
			// Order matters.
			// Consider the following database change:
			//
			// [transaction removeAllObjects];
			// [transaction setObject:obj forKey:key];
			
			if ([changeset_objectChanges objectForKey:key]) {
				[keysToUpdate addObject:key];
			}
			else if ([changeset_removedKeys containsObject:key] || changeset_allKeysRemoved) {
				[keysToRemove addObject:key];
			}
		}];
	
		[objectCache removeObjectsForKeys:keysToRemove];
		
		id yapnull = [YapNull null];
		
		for (id key in keysToUpdate)
		{
			id newObject = [changeset_objectChanges objectForKey:key];
			
			if (newObject == yapnull) // setPrimitiveDataForKey was used on key
				[objectCache removeObjectForKey:key];
			else
				[objectCache setObject:newObject forKey:key];
		}
	}
	
	// Update metadataCache
	
	if (changeset_allKeysRemoved && !hasMetadataChanges)
	{
		// Shortcut: Everything was removed from the database
		
		[metadataCache removeAllObjects];
	}
	else if (hasMetadataChanges && !hasRemovedKeys && !changeset_allKeysRemoved)
	{
		// Shortcut: Nothing was removed from the database.
		// So we can simply enumerate over the changes and update the cache inline as needed.
		
		[changeset_metadataChanges enumerateKeysAndObjectsUsingBlock:^(id key, id object, BOOL *stop) {
			
			if ([metadataCache containsKey:key])
				[metadataCache setObject:object forKey:key];
		}];
	}
	else if (hasMetadataChanges || hasRemovedKeys)
	{
		NSUInteger updateCapacity = MIN([metadataCache count], [changeset_metadataChanges count]);
		NSUInteger removeCapacity = MIN([metadataCache count], [changeset_removedKeys count]);
		
		NSMutableArray *keysToUpdate = [NSMutableArray arrayWithCapacity:updateCapacity];
		NSMutableArray *keysToRemove = [NSMutableArray arrayWithCapacity:removeCapacity];
		
		[metadataCache enumerateKeysWithBlock:^(id key, BOOL *stop) {
			
			// Order matters.
			// Consider the following database change:
			//
			// [transaction removeAllObjects];
			// [transaction setObject:obj forKey:key];
			
			if ([changeset_metadataChanges objectForKey:key]) {
				[keysToUpdate addObject:key];
			}
			else if ([changeset_removedKeys containsObject:key] || changeset_allKeysRemoved) {
				[keysToRemove addObject:key];
			}
		}];
		
		[metadataCache removeObjectsForKeys:keysToRemove];
		
		for (id key in keysToUpdate)
		{
			id newObject = [changeset_metadataChanges objectForKey:key];
			
			[metadataCache setObject:newObject forKey:key];
		}
	}
}

- (BOOL)hasChangeForKey:(NSString *)key
        inNotifications:(NSArray *)notifications
 includingObjectChanges:(BOOL)includeObjectChanges
        metadataChanges:(BOOL)includeMetadataChanges
{
	for (NSNotification *notification in notifications)
	{
		if (![notification isKindOfClass:[NSNotification class]])
		{
			YDBLogWarn(@"%@ - notifications parameter contains non-NSNotification object", THIS_METHOD);
			continue;
		}
		
		NSDictionary *changeset = notification.userInfo;
		
		if (includeObjectChanges)
		{
			YapSet *changeset_objectChanges = [changeset objectForKey:YapDatabaseObjectChangesKey];
			if ([changeset_objectChanges containsObject:key])
				return YES;
		}
		
		if (includeMetadataChanges)
		{
			YapSet *changeset_metadataChanges = [changeset objectForKey:YapDatabaseMetadataChangesKey];
			if ([changeset_metadataChanges containsObject:key])
				return YES;
		}
		
		YapSet *changeset_removedKeys = [changeset objectForKey:YapDatabaseRemovedKeysKey];
		if ([changeset_removedKeys containsObject:key])
			return YES;
		
		BOOL changeset_allKeysRemoved = [[changeset objectForKey:YapDatabaseAllKeysRemovedKey] boolValue];
		if (changeset_allKeysRemoved)
			return YES;
	}
	
	return NO;
}

- (BOOL)hasChangeForKey:(NSString *)key inNotifications:(NSArray *)notifications
{
	return [self hasChangeForKey:key inNotifications:notifications includingObjectChanges:YES metadataChanges:YES];
}

- (BOOL)hasObjectChangeForKey:(NSString *)key inNotifications:(NSArray *)notifications
{
	return [self hasChangeForKey:key inNotifications:notifications includingObjectChanges:YES metadataChanges:NO];
}

- (BOOL)hasMetadataChangeForKey:(NSString *)key inNotifications:(NSArray *)notifications
{
	return [self hasChangeForKey:key inNotifications:notifications includingObjectChanges:NO metadataChanges:YES];
}

- (BOOL)hasChangeForAnyKeys:(NSSet *)keys
            inNotifications:(NSArray *)notifications
     includingObjectChanges:(BOOL)includeObjectChanges
            metadataChanges:(BOOL)includeMetadataChanges
{
	for (NSNotification *notification in notifications)
	{
		if (![notification isKindOfClass:[NSNotification class]])
		{
			YDBLogWarn(@"%@ - notifications parameter contains non-NSNotification object", THIS_METHOD);
			continue;
		}
		
		NSDictionary *changeset = notification.userInfo;
		
		if (includeObjectChanges)
		{
			YapSet *changeset_objectChanges = [changeset objectForKey:YapDatabaseObjectChangesKey];
			if ([changeset_objectChanges intersectsSet:keys])
				return YES;
		}
		
		if (includeMetadataChanges)
		{
			YapSet *changeset_metadataChanges = [changeset objectForKey:YapDatabaseMetadataChangesKey];
			if ([changeset_metadataChanges intersectsSet:keys])
				return YES;
		}
		
		YapSet *changeset_removedKeys = [changeset objectForKey:YapDatabaseRemovedKeysKey];
		if ([changeset_removedKeys intersectsSet:keys])
			return YES;
		
		BOOL changeset_allKeysRemoved = [[changeset objectForKey:YapDatabaseAllKeysRemovedKey] boolValue];
		if (changeset_allKeysRemoved)
			return YES;
	}
	
	return NO;
}

- (BOOL)hasChangeForAnyKeys:(NSSet *)keys inNotifications:(NSArray *)notifications
{
	return [self hasChangeForAnyKeys:keys inNotifications:notifications includingObjectChanges:YES metadataChanges:YES];
}

- (BOOL)hasObjectChangeForAnyKeys:(NSSet *)keys inNotifications:(NSArray *)notifications
{
	return [self hasChangeForAnyKeys:keys inNotifications:notifications includingObjectChanges:YES metadataChanges:NO];
}

- (BOOL)hasMetadataChangeForAnyKeys:(NSSet *)keys inNotifications:(NSArray *)notifications
{
	return [self hasChangeForAnyKeys:keys inNotifications:notifications includingObjectChanges:NO metadataChanges:YES];
}

@end
