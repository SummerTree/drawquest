#import "YapCollectionsDatabaseFullTextSearchConnection.h"
#import "YapCollectionsDatabaseFullTextSearchPrivate.h"
#import "YapAbstractDatabaseExtensionPrivate.h"
#import "YapAbstractDatabasePrivate.h"
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



@implementation YapCollectionsDatabaseFullTextSearchConnection {
@private
	
	sqlite3_stmt *insertRowidStatement;
	sqlite3_stmt *setRowidStatement;
	sqlite3_stmt *removeRowidStatement;
	sqlite3_stmt *removeAllStatement;
	sqlite3_stmt *queryStatement;
	sqlite3_stmt *querySnippetStatement;
}

@synthesize fullTextSearch = fts;

- (id)initWithFTS:(YapCollectionsDatabaseFullTextSearch *)inFTS
   databaseConnection:(YapCollectionsDatabaseConnection *)inDatabaseConnection
{
	if ((self = [super init]))
	{
		fts = inFTS;
		databaseConnection = inDatabaseConnection;
	}
	return self;
}

- (void)dealloc
{
	sqlite_finalize_null(&insertRowidStatement);
	sqlite_finalize_null(&setRowidStatement);
	sqlite_finalize_null(&removeRowidStatement);
	sqlite_finalize_null(&removeAllStatement);
	sqlite_finalize_null(&queryStatement);
	sqlite_finalize_null(&querySnippetStatement);
}

/**
 * Required override method from YapAbstractDatabaseExtensionConnection
**/
- (void)_flushMemoryWithLevel:(int)level
{
	if (level >= YapDatabaseConnectionFlushMemoryLevelModerate)
	{
		sqlite_finalize_null(&insertRowidStatement);
		sqlite_finalize_null(&setRowidStatement);
		sqlite_finalize_null(&removeRowidStatement);
		sqlite_finalize_null(&removeAllStatement);
		sqlite_finalize_null(&queryStatement);
		sqlite_finalize_null(&querySnippetStatement);
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Accessors
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Required override method from YapAbstractDatabaseExtensionConnection.
**/
- (YapAbstractDatabaseExtension *)extension
{
	return fts;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Transactions
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Required override method from YapAbstractDatabaseExtensionConnection.
**/
- (id)newReadTransaction:(YapAbstractDatabaseTransaction *)inDatabaseTransaction
{
	__unsafe_unretained YapCollectionsDatabaseReadTransaction *databaseTransaction =
	    (YapCollectionsDatabaseReadTransaction *)inDatabaseTransaction;
	
	YapCollectionsDatabaseFullTextSearchTransaction *transaction =
	    [[YapCollectionsDatabaseFullTextSearchTransaction alloc] initWithFTSConnection:self
	                                                               databaseTransaction:databaseTransaction];
	
	return transaction;
}

/**
 * Required override method from YapAbstractDatabaseExtensionConnection.
**/
- (id)newReadWriteTransaction:(YapAbstractDatabaseTransaction *)inDatabaseTransaction
{
	__unsafe_unretained YapCollectionsDatabaseReadTransaction *databaseTransaction =
	    (YapCollectionsDatabaseReadTransaction *)inDatabaseTransaction;
	
	YapCollectionsDatabaseFullTextSearchTransaction *transaction =
	    [[YapCollectionsDatabaseFullTextSearchTransaction alloc] initWithFTSConnection:self
	                                                               databaseTransaction:databaseTransaction];
	
	if (blockDict == nil)
		blockDict = [NSMutableDictionary dictionaryWithSharedKeySet:fts->columnNamesSharedKeySet];
	
	return transaction;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Changeset
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Required override method from YapAbstractDatabaseExtension
**/
- (void)postRollbackCleanup
{
	// Nothing to do for this particular extension.
	//
	// YapAbstractDatabaseExtension rows a "not implemented" exception
	// to ensure extensions have implementations of all required methods.
}

/**
 * Required override method from YapAbstractDatabaseExtension
**/
- (void)getInternalChangeset:(NSMutableDictionary **)internalChangesetPtr
           externalChangeset:(NSMutableDictionary **)externalChangesetPtr
{
	// Nothing to do for this particular extension.
	//
	// YapAbstractDatabaseExtension rows a "not implemented" exception
	// to ensure extensions have implementations of all required methods.
}

/**
 * Required override method from YapAbstractDatabaseExtension
**/
- (void)processChangeset:(NSDictionary *)changeset
{
	// Nothing to do for this particular extension.
	//
	// YapAbstractDatabaseExtension rows a "not implemented" exception
	// to ensure extensions have implementations of all required methods.
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Statements
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (sqlite3_stmt *)insertRowidStatement
{
	if (insertRowidStatement == NULL)
	{
		NSMutableString *string = [NSMutableString stringWithCapacity:100];
		[string appendFormat:@"INSERT INTO \"%@\" (\"rowid\"", [fts tableName]];
		
		for (NSString *columnName in fts->columnNames)
		{
			[string appendFormat:@", \"%@\"", columnName];
		}
		
		[string appendString:@") VALUES (?"];
		
		NSUInteger count = [fts->columnNames count];
		NSUInteger i;
		for (i = 0; i < count; i++)
		{
			[string appendString:@", ?"];
		}
		
		[string appendString:@");"];
		
		sqlite3 *db = databaseConnection->db;
		
		int status = sqlite3_prepare_v2(db, [string UTF8String], -1, &insertRowidStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"%@: Error creating prepared statement: %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return insertRowidStatement;
}

- (sqlite3_stmt *)setRowidStatement
{
	if (setRowidStatement == NULL)
	{
		NSMutableString *string = [NSMutableString stringWithCapacity:100];
		[string appendFormat:@"INSERT OR REPLACE INTO \"%@\" (\"rowid\"", [fts tableName]];
		
		for (NSString *columnName in fts->columnNames)
		{
			[string appendFormat:@", \"%@\"", columnName];
		}
		
		[string appendString:@") VALUES (?"];
		
		NSUInteger count = [fts->columnNames count];
		NSUInteger i;
		for (i = 0; i < count; i++)
		{
			[string appendString:@", ?"];
		}
		
		[string appendString:@");"];
		
		sqlite3 *db = databaseConnection->db;
		
		int status = sqlite3_prepare_v2(db, [string UTF8String], -1, &setRowidStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"%@: Error creating prepared statement: %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return setRowidStatement;
}

- (sqlite3_stmt *)removeRowidStatement
{
	if (removeRowidStatement == NULL)
	{
		NSString *string = [NSString stringWithFormat:@"DELETE FROM \"%@\" WHERE \"rowid\" = ?;", [fts tableName]];
		
		sqlite3 *db = databaseConnection->db;
		
		int status = sqlite3_prepare_v2(db, [string UTF8String], -1, &removeRowidStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"%@: Error creating prepared statement: %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return removeRowidStatement;
}

- (sqlite3_stmt *)removeAllStatement
{
	if (removeAllStatement == NULL)
	{
		NSString *string = [NSString stringWithFormat:@"DELETE FROM \"%@\";", [fts tableName]];
		
		sqlite3 *db = databaseConnection->db;
		
		int status = sqlite3_prepare_v2(db, [string UTF8String], -1, &removeAllStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"%@: Error creating prepared statement: %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return removeAllStatement;
}

- (sqlite3_stmt *)queryStatement
{
	if (queryStatement == NULL)
	{
		NSString *tableName = [fts tableName];
		
		NSString *string = [NSString stringWithFormat:
		    @"SELECT \"rowid\" FROM \"%1$@\" WHERE \"%1$@\" MATCH ?;", tableName];
		
		sqlite3 *db = databaseConnection->db;
		
		int status = sqlite3_prepare_v2(db, [string UTF8String], -1, &queryStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"%@: Error creating prepared statement: %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return queryStatement;
}

- (sqlite3_stmt *)querySnippetStatement
{
	if (querySnippetStatement == NULL)
	{
		NSString *tableName = [fts tableName];
		
		NSString *string = [NSString stringWithFormat:
		    @"SELECT \"rowid\", snippet(\"%1$@\", ?, ?, ?, ?, ?) FROM \"%1$@\" WHERE \"%1$@\" MATCH ?;", tableName];
		
		sqlite3 *db = databaseConnection->db;
		
		int status = sqlite3_prepare_v2(db, [string UTF8String], -1, &querySnippetStatement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"%@: Error creating prepared statement: %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return querySnippetStatement;
}

@end
