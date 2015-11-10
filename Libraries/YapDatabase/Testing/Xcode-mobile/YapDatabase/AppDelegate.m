#import "AppDelegate.h"
#import "ViewController.h"

#import "BenchmarkYapCache.h"
#import "BenchmarkYapDatabase.h"

#import "YapDatabase.h"
#import "YapDatabaseView.h"

#import "YapCollectionsDatabase.h"
#import "YapCollectionsDatabaseView.h"

#import "DDLog.h"
#import "DDTTYLogger.h"
#import "YapDatabaseLogging.h"


@implementation AppDelegate
{
	YapDatabase *otfDatabase;
	YapDatabaseConnection *otfDatabaseConnection;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	[DDLog addLogger:[DDTTYLogger sharedInstance]];
	
	[[DDTTYLogger sharedInstance] setColorsEnabled:YES];
	[[DDTTYLogger sharedInstance] setForegroundColor:[UIColor grayColor]
	                                 backgroundColor:nil
	                                         forFlag:YDB_LOG_FLAG_TRACE
	                                         context:YDBLogContext];
	
	double delayInSeconds = 2.0;
	dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
	dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
		
		[self debug];
	//	[self debugOnTheFlyViews];
	});
	
	// Normal UI stuff
	
	self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
	
	if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone) {
		self.viewController = [[ViewController alloc] initWithNibName:@"ViewController_iPhone" bundle:nil];
	} else {
		self.viewController = [[ViewController alloc] initWithNibName:@"ViewController_iPad" bundle:nil];
	}
	self.window.rootViewController = self.viewController;
	[self.window makeKeyAndVisible];
	return YES;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Debugging Utilities
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSString *)databasePath:(NSString *)suffix
{
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
	NSString *baseDir = ([paths count] > 0) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
	
	NSString *databaseName = [NSString stringWithFormat:@"database-%@.sqlite", suffix];
	
	return [baseDir stringByAppendingPathComponent:databaseName];
}

- (void)yapDatabaseModified:(NSNotification *)notification
{
	NSLog(@"YapDatabaseModified: %@", notification);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark General Debugging
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)debug
{
	NSLog(@"Starting debug...");
	
	NSString *databasePath = [self databasePath:NSStringFromSelector(_cmd)];
	
	YapDatabase *database = [[YapDatabase alloc] initWithPath:databasePath];
	
	[[NSNotificationCenter defaultCenter] addObserver:self
	                                         selector:@selector(yapDatabaseModified:)
	                                             name:YapDatabaseModifiedNotification
	                                           object:database];
	
	YapDatabaseConnection *databaseConnection = [database newConnection];
	
	YapDatabaseViewBlockType groupingBlockType;
	YapDatabaseViewGroupingWithKeyBlock groupingBlock;
	
	YapDatabaseViewBlockType sortingBlockType;
	YapDatabaseViewSortingWithObjectBlock sortingBlock;
	
	groupingBlockType = YapDatabaseViewBlockTypeWithKey;
	groupingBlock = ^NSString *(NSString *key){
		
		return @"";
	};
	
	sortingBlockType = YapDatabaseViewBlockTypeWithObject;
	sortingBlock = ^(NSString *group, NSString *key1, id obj1, NSString *key2, id obj2){
		
		NSString *object1 = (NSString *)obj1;
		NSString *object2 = (NSString *)obj2;
		
		return [object1 compare:object2];
	};
	
	YapDatabaseView *databaseView =
	    [[YapDatabaseView alloc] initWithGroupingBlock:groupingBlock
	                                 groupingBlockType:groupingBlockType
	                                      sortingBlock:sortingBlock
	                                  sortingBlockType:sortingBlockType];
	
	if (![database registerExtension:databaseView withName:@"order"])
	{
		NSLog(@"Failure registering extension");
	}
	
	[databaseConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
		
		[transaction setObject:@"value" forKey:@"key"];
	}];
	
	[databaseConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
		
		[[transaction ext:@"order"] touchObjectForKey:@"key"];
	}];
	
	[databaseConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
		
		[[transaction ext:@"order"] enumerateKeysInGroup:@""
		                                      usingBlock:^(NSString *key, NSUInteger index, BOOL *stop) {
			
			NSLog(@"%lu: %@", (unsigned long)index, key);
		}];
	}];
	
	NSLog(@"Debug complete");
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark On-The-Fly Extensions Debugging
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)debugOnTheFlyViews
{
	NSString *databasePath = [self databasePath:NSStringFromSelector(_cmd)];
	
//	[[NSFileManager defaultManager] removeItemAtPath:databasePath error:NULL];
	
	otfDatabase = [[YapDatabase alloc] initWithPath:databasePath];
	otfDatabaseConnection = [otfDatabase newConnection];
	
	[self printDatabaseCount];
	
	[self registerMainView];
	[self printMainViewCount];
	
	[otfDatabaseConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
		
		NSUInteger count = 5;
		NSLog(@"Adding %lu items...", (unsigned long)count);
		
		for (NSUInteger i = 0; i < count; i++)
		{
			NSString *key = [[NSUUID UUID] UUIDString];
			NSString *obj = [[NSUUID UUID] UUIDString];
			
			[transaction setObject:obj forKey:key];
		}
	}];
	
	[self printDatabaseCount];
	[self printMainViewCount];
	
	[self registerOnTheFlyView];
	
	[self printOnTheFlyViewCount];
}

- (void)registerMainView
{
	NSLog(@"Registering mainView....");
	
	YapDatabaseViewBlockType groupingBlockType;
	YapDatabaseViewGroupingWithObjectBlock groupingBlock;

	YapDatabaseViewBlockType sortingBlockType;
	YapDatabaseViewSortingWithObjectBlock sortingBlock;

	groupingBlockType = YapDatabaseViewBlockTypeWithObject;
	groupingBlock = ^NSString *(NSString *key, id object){
		
		return @"";
	};

	sortingBlockType = YapDatabaseViewBlockTypeWithObject;
	sortingBlock = ^(NSString *group, NSString *key1, id obj1, NSString *key2, id obj2){
		
		return [obj1 compare:obj2];
	};

	YapDatabaseView *databaseView =
	    [[YapDatabaseView alloc] initWithGroupingBlock:groupingBlock
	                                 groupingBlockType:groupingBlockType
	                                      sortingBlock:sortingBlock
	                                  sortingBlockType:sortingBlockType];
	
	if ([otfDatabase registerExtension:databaseView withName:@"main"])
		NSLog(@"Registered mainView");
	else
		NSLog(@"ERROR registering mainView !");
}

- (void)registerOnTheFlyView
{
	NSLog(@"Registering onTheFlyView....");
	
	YapDatabaseViewBlockType groupingBlockType;
	YapDatabaseViewGroupingWithObjectBlock groupingBlock;

	YapDatabaseViewBlockType sortingBlockType;
	YapDatabaseViewSortingWithObjectBlock sortingBlock;

	groupingBlockType = YapDatabaseViewBlockTypeWithObject;
	groupingBlock = ^NSString *(NSString *key, id object){
		
		return @"";
	};

	sortingBlockType = YapDatabaseViewBlockTypeWithObject;
	sortingBlock = ^(NSString *group, NSString *key1, id obj1, NSString *key2, id obj2){
		
		return [obj1 compare:obj2];
	};

	YapDatabaseView *databaseView =
	    [[YapDatabaseView alloc] initWithGroupingBlock:groupingBlock
	                                 groupingBlockType:groupingBlockType
	                                      sortingBlock:sortingBlock
	                                  sortingBlockType:sortingBlockType];
	
	if ([otfDatabase registerExtension:databaseView withName:@"on-the-fly"])
		NSLog(@"Registered onTheFlyView");
	else
		NSLog(@"ERROR registering onTheFlyView !");
}

- (void)printDatabaseCount
{
	[otfDatabaseConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
		
		NSUInteger count = [transaction numberOfKeys];
		
		NSLog(@"database.count = %lu", (unsigned long)count);
	}];
}

- (void)printMainViewCount
{
	[otfDatabaseConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
		
		NSUInteger count = [[transaction ext:@"main"] numberOfKeysInGroup:@""];
		
		NSLog(@"mainView.count = %lu", (unsigned long)count);
	}];
}

- (void)printOnTheFlyViewCount
{
	[otfDatabaseConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
		
		NSUInteger count = [[transaction ext:@"on-the-fly"] numberOfKeysInGroup:@""];
		
		NSLog(@"onTheFlyView.count = %lu", (unsigned long)count);
	}];
}

@end
