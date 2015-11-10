#import <Foundation/Foundation.h>

#import "YapAbstractDatabase.h"
#import "YapAbstractDatabaseConnection.h"
#import "YapAbstractDatabaseTransaction.h"

#import "YapDatabaseConnectionState.h"
#import "YapCache.h"

#import "sqlite3.h"

/**
 * Helper method to conditionally invoke sqlite3_finalize on a statement, and then set the ivar to NULL.
**/
NS_INLINE void sqlite_finalize_null(sqlite3_stmt **stmtPtr)
{
	if (*stmtPtr) {
		sqlite3_finalize(*stmtPtr);
		*stmtPtr = NULL;
	}
}

extern NSString *const YapDatabaseRegisteredExtensionsKey;
extern NSString *const YapDatabaseNotificationKey;

@interface YapAbstractDatabase () {
@private
	
	NSMutableArray *changesets;
	uint64_t snapshot;
	
	dispatch_queue_t checkpointQueue;
	
	NSDictionary *registeredExtensions;
	YapAbstractDatabaseConnection *registrationConnection;
	
@protected
	
	sqlite3 *db; // Used for setup & checkpoints
	
@public
	
	void *IsOnSnapshotQueueKey;       // Only to be used by YapAbstractDatabaseConnection
	void *IsOnWriteQueueKey;          // Only to be used by YapAbstractDatabaseConnection
	
	dispatch_queue_t snapshotQueue;   // Only to be used by YapAbstractDatabaseConnection
	dispatch_queue_t writeQueue;      // Only to be used by YapAbstractDatabaseConnection
	
	NSMutableArray *connectionStates; // Only to be used by YapAbstractDatabaseConnection
	
	NSArray *previouslyRegisteredExtensionNames; // Only to be used by YapAbstractDatabaseConnection
}

/**
 * Required override hook.
 * Don't forget to invoke [super createTables].
**/
- (BOOL)createTables;

/**
 * Required override hook.
 * Subclasses must implement this method and return the proper class to use for the cache.
**/
- (Class)cacheKeyClass;

/**
 * General utility methods.
**/
- (BOOL)tableExists:(NSString *)tableName using:(sqlite3 *)aDb;
- (NSArray *)columnNamesForTable:(NSString *)tableName using:(sqlite3 *)aDb;

/**
 * Optional override hook.
 * Don't forget to invoke [super prepare].
 * 
 * This method is run asynchronously on the snapshotQueue.
**/
- (void)prepare;

/**
 * Use the addConnection method from within newConnection.
 *
 * And when a connection is deallocated,
 * it should remove itself from the list of connections by calling removeConnection.
**/
- (void)addConnection:(YapAbstractDatabaseConnection *)connection;
- (void)removeConnection:(YapAbstractDatabaseConnection *)connection;

/**
 * This method is only accessible from within the snapshotQueue.
 * 
 * The snapshot represents when the database was last modified by a read-write transaction.
 * This information isn persisted to the 'yap' database, and is separately held in memory.
 * It serves multiple purposes.
 * 
 * First is assists in validation of a connection's cache.
 * When a connection begins a new transaction, it may have items sitting in the cache.
 * However the connection doesn't know if the items are still valid because another connection may have made changes.
 * 
 * The snapshot also assists in correcting for a race condition.
 * It order to minimize blocking we allow read-write transactions to commit outside the context
 * of the snapshotQueue. This is because the commit may be a time consuming operation, and we
 * don't want to block read-only transactions during this period. The race condition occurs if a read-only
 * transactions starts in the midst of a read-write commit, and the read-only transaction gets
 * a "yap-level" snapshot that's out of sync with the "sql-level" snapshot. This is easily correctable if caught.
 * Thus we maintain the snapshot in memory, and fetchable via a select query.
 * One represents the "yap-level" snapshot, and the other represents the "sql-level" snapshot.
 *
 * The snapshot is simply a 64-bit integer.
 * It is reset when the YapDatabase instance is initialized,
 * and incremented by each read-write transaction (if changes are actually made).
**/
- (uint64_t)snapshot;

/**
 * This method is only accessible from within the snapshotQueue.
 * 
 * Prior to starting the sqlite commit, the connection must report its changeset to the database.
 * The database will store the changeset, and provide it to other connections if needed (due to a race condition).
 * 
 * The following MUST be in the dictionary:
 *
 * - snapshot : NSNumber with the changeset's snapshot
**/
- (void)notePendingChanges:(NSDictionary *)changeset fromConnection:(YapAbstractDatabaseConnection *)connection;

/**
 * This method is only accessible from within the snapshotQueue.
 * 
 * This method is used if a transaction finds itself in a race condition.
 * That is, the transaction started before it was able to process changesets from sibling connections.
 * 
 * It should fetch the changesets needed and then process them via [connection noteCommittedChanges:].
**/
- (NSArray *)pendingAndCommittedChangesSince:(uint64_t)connectionSnapshot until:(uint64_t)maxSnapshot;

/**
 * This method is only accessible from within the snapshotQueue.
 * 
 * Upon completion of a readwrite transaction, the connection must report its changeset to the database.
 * The database will then forward the changeset to all other connections.
 * 
 * The following MUST be in the dictionary:
 * 
 * - snapshot : NSNumber with the changeset's snapshot
**/
- (void)noteCommittedChanges:(NSDictionary *)changeset fromConnection:(YapAbstractDatabaseConnection *)connection;

/**
 * This method should be called whenever the maximum checkpointable snapshot is incremented.
 * That is, the state of every connection is known to the system.
 * And a snaphot cannot be checkpointed until every connection is at or past that snapshot.
 * Thus, we can know the point at which a snapshot becomes checkpointable,
 * and we can thus optimize the checkpoint invocations such that
 * each invocation is able to checkpoint one or more commits.
**/
- (void)asyncCheckpoint:(uint64_t)maxCheckpointableSnapshot;

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@interface YapAbstractDatabaseConnection () {
@private
	sqlite3_stmt *beginTransactionStatement;
	sqlite3_stmt *commitTransactionStatement;
	sqlite3_stmt *rollbackTransactionStatement;
	
	sqlite3_stmt *yapGetDataForKeyStatement;   // Against "yap" database, for internal use
	sqlite3_stmt *yapSetDataForKeyStatement;   // Against "yap" database, for internal use
	sqlite3_stmt *yapRemoveExtensionStatement; // Against "yap" database, for internal use
	
	uint64_t snapshot;
	
	YapAbstractDatabaseTransaction *longLivedReadTransaction;
	BOOL throwExceptionsForImplicitlyEndingLongLivedReadTransaction;
	NSMutableArray *pendingChangesets;
	NSMutableArray *processedChangesets;
	
	NSDictionary *registeredExtensions;
	BOOL registeredExtensionsChanged;
	
	NSMutableDictionary *extensions;
	BOOL extensionsReady;
	id sharedKeySetForExtensions;
	
@protected
	dispatch_queue_t connectionQueue;
	void *IsOnConnectionQueueKey;
	
	id sharedKeySetForInternalChangeset;
	id sharedKeySetForExternalChangeset;
	
@public
	__strong YapAbstractDatabase *abstractDatabase;
	
	sqlite3 *db;
	
	YapCache *objectCache;
	YapCache *metadataCache;
	
	NSUInteger objectCacheLimit;          // Read-only by transaction. Use as consideration of whether to add to cache.
	NSUInteger metadataCacheLimit;        // Read-only by transaction. Use as consideration of whether to add to cache.
	
	BOOL needsMarkSqlLevelSharedReadLock; // Read-only by transaction. Use as consideration of whether to invoke method.
}

- (id)initWithDatabase:(YapAbstractDatabase *)database;

@property (nonatomic, readonly) dispatch_queue_t connectionQueue;

- (void)prepare;

- (NSDictionary *)extensions;

- (BOOL)registerExtension:(YapAbstractDatabaseExtension *)extension withName:(NSString *)extensionName;
- (void)unregisterExtension:(NSString *)extensionName;

- (sqlite3_stmt *)beginTransactionStatement;
- (sqlite3_stmt *)commitTransactionStatement;
- (sqlite3_stmt *)rollbackTransactionStatement;

- (sqlite3_stmt *)yapGetDataForKeyStatement;   // Against "yap" database, for internal use
- (sqlite3_stmt *)yapSetDataForKeyStatement;   // Against "yap" database, for internal use
- (sqlite3_stmt *)yapRemoveExtensionStatement; // Against "yap" database, for internal use

- (void)_flushMemoryWithLevel:(int)level;

- (void)_readWithBlock:(void (^)(id))block;
- (void)_readWriteWithBlock:(void (^)(id))block;

- (void)_asyncReadWithBlock:(void (^)(id))block
            completionBlock:(dispatch_block_t)completionBlock
            completionQueue:(dispatch_queue_t)completionQueue;

- (void)_asyncReadWriteWithBlock:(void (^)(id))block
                 completionBlock:(dispatch_block_t)completionBlock
                 completionQueue:(dispatch_queue_t)completionQueue;

- (YapAbstractDatabaseTransaction *)newReadTransaction;
- (YapAbstractDatabaseTransaction *)newReadWriteTransaction;

- (void)preReadTransaction:(YapAbstractDatabaseTransaction *)transaction;
- (void)postReadTransaction:(YapAbstractDatabaseTransaction *)transaction;

- (void)preReadWriteTransaction:(YapAbstractDatabaseTransaction *)transaction;
- (void)postReadWriteTransaction:(YapAbstractDatabaseTransaction *)transaction;

- (void)markSqlLevelSharedReadLockAcquired;

- (void)postRollbackCleanup;

- (NSArray *)internalChangesetKeys;
- (NSArray *)externalChangesetKeys;
- (void)getInternalChangeset:(NSMutableDictionary **)internalPtr externalChangeset:(NSMutableDictionary **)externalPtr;
- (void)processChangeset:(NSDictionary *)changeset;

- (void)noteCommittedChanges:(NSDictionary *)changeset;

- (void)maybeResetLongLivedReadTransaction;

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@interface YapAbstractDatabaseTransaction () {
@private
	
	NSMutableDictionary *extensions;
	BOOL extensionsReady;
	
@protected
	
	BOOL isMutated; // Used for "mutation during enumeration" protection
	
@public
	__unsafe_unretained YapAbstractDatabaseConnection *abstractConnection;
	
	BOOL isReadWriteTransaction;
	BOOL rollback;
	id customObjectForNotification;
}

- (id)initWithConnection:(YapAbstractDatabaseConnection *)connection isReadWriteTransaction:(BOOL)flag;

- (void)beginTransaction;
- (void)preCommitReadWriteTransaction;
- (void)commitTransaction;
- (void)rollbackTransaction;

- (NSDictionary *)extensions;

- (void)addRegisteredExtensionTransaction:(YapAbstractDatabaseExtensionTransaction *)extTransaction;
- (void)removeRegisteredExtensionTransaction:(NSString *)extName;

- (int)intValueForKey:(NSString *)key extension:(NSString *)extensionName;
- (void)setIntValue:(int)value forKey:(NSString *)key extension:(NSString *)extensionName;

- (double)doubleValueForKey:(NSString *)key extension:(NSString *)extensionName;
- (void)setDoubleValue:(double)value forKey:(NSString *)key extension:(NSString *)extensionName;

- (NSString *)stringValueForKey:(NSString *)key extension:(NSString *)extensionName;
- (void)setStringValue:(NSString *)value forKey:(NSString *)key extension:(NSString *)extensionName;

- (NSData *)dataValueForKey:(NSString *)key extension:(NSString *)extensionName;
- (void)setDataValue:(NSData *)value forKey:(NSString *)key extension:(NSString *)extensionName;

- (void)removeAllValuesForExtension:(NSString *)extensionName;

- (NSException *)mutationDuringEnumerationException;

@end
