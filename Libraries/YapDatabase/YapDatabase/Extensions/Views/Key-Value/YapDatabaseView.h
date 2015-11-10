#import <Foundation/Foundation.h>

#import "YapAbstractDatabaseExtension.h"
#import "YapDatabaseViewConnection.h"
#import "YapDatabaseViewTransaction.h"

/**
 * Welcome to YapDatabase!
 *
 * https://github.com/yaptv/YapDatabase
 *
 * The project wiki has a wealth of documentation if you have any questions.
 * https://github.com/yaptv/YapDatabase/wiki
 * 
 * YapDatabaseView is an extension designed to work with YapDatabase.
 * It gives you a persistent sorted "view" of a configurable subset of your data.
 *
 * For the full documentation on Views, please see the related wiki article:
 * https://github.com/yaptv/YapDatabase/wiki/Views
 * 
 * Just in case you don't have Internet access, here's a quick overview:
 * 
 * YapDatabaseView provides the ability to create a "view" of your data.
 * That is, imagine you want to display your data in a table.
 *
 * - Do you want to display all your data, or just a subset of it?
 * - Do you want to group it into sections?
 * - How do you want to sort the objects?
 * 
 * In sqlite terms, this translates into:
 * - WHERE ...     (filter)
 * - GROUP BY ...  (group)
 * - ORDER BY ...  (sort)
 * 
 * And this is essentially what a view does.
 * It allows you to specify the terms of the view by answering the 3 questions above.
 * Furthermore, a view is persistent. So when you alter the table, the view is automatically updated as well.
 * 
 * Let's start from the beginning.
 * When you create an instance of a view, you specify 2 blocks:
 *
 * - The first block is called the grouping block, and it handles both filtering and grouping.
 *   When you add or update rows in the databse the grouping block is invoked.
 *   Your grouping block can inspect the row and determine if it should be a part of the view.
 *   If not, your grouping block simply returns 'nil' and the object is excluded from the view (removing it if needed).
 *   Otherwise your grouping block returns a group, which can be any string you want.
 *   Once the view knows what group the row belongs to,
 *   it then needs to determine the index/position of the row within the group.
 *
 * - The second block is called the sorting block, and it handles sorting.
 *   After invoking the grouping block to determine what group a database row belongs to (if any),
 *   the view then needs to determine what index within that group the row should be.
 *   In order to do this, it needs to compare the new/updated row with existing rows in the same view group.
 *   This is what the sorting block is used for.
 *   So the sorting block will be invoked automatically during this process until the view has come to a conclusion.
 *
 * The steps to setup and use YapDatabaseView:
 *
 * 1. Create an instance of it (configured however you like):
 *
 *    YapDatabaseView *myView = [[YapDatabaseView alloc] initWith...];
 *
 * 2. Then you register the view with the databse:
 *
 *    [myDatabase registerExtension:myView withName:@"view"];
 *
 * 3. Access the view within a transaction (just like you access the databse):
 * 
 *    [myDatabaseConnection readWithTransaction:^(YapDatabaseReadTransaction *transaction){
 *        
 *        [[transaction extension:@"view"] objectAtIndex:0 inGroup:@"songs"];
 *    }];
 *
 * @see [YapAbstractDatabase registerExtension:withName:]
**/


/**
 * The grouping block handles both filtering and grouping.
 * 
 * When you add or update rows in the databse the grouping block is invoked.
 * Your grouping block can inspect the row and determine if it should be a part of the view.
 * If not, your grouping block simply returns 'nil' and the object is excluded from the view (removing it if needed).
 * Otherwise your grouping block returns a group, which can be any string you want.
 * Once the view knows what group the row belongs to,
 * it with then determine the index/position of the row within the group (using the sorting block).
 * 
 * You should choose a block type that takes the minimum number of required parameters.
 * The view can make various optimizations based on required parameters of the block.
**/
typedef id YapDatabaseViewGroupingBlock; // One of the YapDatabaseViewGroupingX types below.

typedef NSString* (^YapDatabaseViewGroupingWithKeyBlock)(NSString *key);
typedef NSString* (^YapDatabaseViewGroupingWithObjectBlock)(NSString *key, id object);
typedef NSString* (^YapDatabaseViewGroupingWithMetadataBlock)(NSString *key, id metadata);
typedef NSString* (^YapDatabaseViewGroupingWithRowBlock)(NSString *key, id object, id metadata);

/**
 * The sorting block handles sorting of objects within their group.
 *
 * After the view invokes the grouping block to determine what group a database row belongs to (if any),
 * the view then needs to determine what index within that group the row should be.
 * In order to do this, it needs to compare the new/updated row with existing rows in the same view group.
 * This is what the sorting block is used for.
 * So the sorting block will be invoked automatically during this process until the view has come to a conclusion.
 * 
 * You should choose a block type that takes the minimum number of required parameters.
 * The view can make various optimizations based on required parameters of the block.
 * 
 * For example, if sorting is based on the object, and the metadata of a row is updated,
 * then the view can deduce that the index hasn't changed (if the group hans't), and can skip this step.
 * 
 * Performance Note:
 * 
 * The view uses various optimizations (based on common patterns)
 * to reduce the number of times it needs to invoke the sorting block.
 *
 * - Pattern      : row is updated, but its index in the view doesn't change.
 *   Optimization : if an updated row doesn't change groups, the view will first compare it with
 *                  objects to the left and right.
 *
 * - Pattern      : rows are added to the beginning or end or a view
 *   Optimization : if the last change put an object at the beginning of the view, then it will test this quickly.
 *                  if the last change put an object at the end of the view, then it will test this quickly.
 * 
 * These optimizations offer huge performance benefits to many common cases.
 * For example, adding objects to a view that are sorted by timestamp of when they arrived.
 *
 * The optimizations are not always performed.
 * That is, if the row is added to a group it didn't previously belong,
 * or if the last change didn't place an item at the beginning or end of the view.
 *
 * If optimizations fail, or are skipped, then the view uses a binary search algorithm.
 * 
 * Although this may be considered "internal information",
 * I feel it is important to explain for the following reason:
 * 
 * Another common pattern is to fetch a number of objects in a batch, and then insert them into the database.
 * Now imagine a situation in which the view is sorting posts based on timestamp,
 * and you just fetched the most recent 10 posts. You can enumerate these 10 posts in forwards or backwards order
 * while adding them to the database. One direction will hit the optimization every time. The other will cause
 * the view to perform a binary search every time. These little one-liner optimzations are easy.
**/
typedef id YapDatabaseViewSortingBlock; // One of the YapDatabaseViewSortingX types below.

typedef NSComparisonResult (^YapDatabaseViewSortingWithKeyBlock)      \
                 (NSString *group, NSString *key1, NSString *key2);
typedef NSComparisonResult (^YapDatabaseViewSortingWithObjectBlock)   \
                 (NSString *group, NSString *key1, id object1, NSString *key2, id object2);
typedef NSComparisonResult (^YapDatabaseViewSortingWithMetadataBlock) \
                 (NSString *group, NSString *key1, id metadata, NSString *key2, id metadata2);
typedef NSComparisonResult (^YapDatabaseViewSortingWithRowBlock)      \
                 (NSString *group, NSString *key1, id object1, id metadata1, NSString *key2, id object2, id metadata2);

#ifndef YapDatabaseViewBlockTypeDefined
#define YapDatabaseViewBlockTypeDefined 1

/**
 * Use this enum to specify what kind of block you're passing.
**/
typedef enum {
	YapDatabaseViewBlockTypeWithKey       = 101,
	YapDatabaseViewBlockTypeWithObject    = 102,
	YapDatabaseViewBlockTypeWithMetadata  = 103,
	YapDatabaseViewBlockTypeWithRow       = 104
} YapDatabaseViewBlockType;

#endif


@interface YapDatabaseView : YapAbstractDatabaseExtension

/* Inherited from YapAbstractDatabaseExtension

@property (nonatomic, strong, readonly) NSString *registeredName;

*/

- (id)initWithGroupingBlock:(YapDatabaseViewGroupingBlock)groupingBlock
          groupingBlockType:(YapDatabaseViewBlockType)groupingBlockType
               sortingBlock:(YapDatabaseViewSortingBlock)sortingBlock
           sortingBlockType:(YapDatabaseViewBlockType)sortingBlockType;

- (id)initWithGroupingBlock:(YapDatabaseViewGroupingBlock)groupingBlock
          groupingBlockType:(YapDatabaseViewBlockType)groupingBlockType
               sortingBlock:(YapDatabaseViewSortingBlock)sortingBlock
           sortingBlockType:(YapDatabaseViewBlockType)sortingBlockType
                    version:(int)version;

@property (nonatomic, strong, readonly) YapDatabaseViewGroupingBlock groupingBlock;
@property (nonatomic, strong, readonly) YapDatabaseViewSortingBlock sortingBlock;

@property (nonatomic, assign, readonly) YapDatabaseViewBlockType groupingBlockType;
@property (nonatomic, assign, readonly) YapDatabaseViewBlockType sortingBlockType;

/**
 * The version assists you in updating your blocks.
 * 
 * If you need to change the groupingBlock or sortingBlock,
 * then simply pass an incremented version during the init method,
 * and the view will automatically update itself.
**/
@property (nonatomic, assign, readonly) int version;

@end
