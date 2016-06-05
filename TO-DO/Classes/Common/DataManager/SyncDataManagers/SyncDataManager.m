//
//  SyncDataManager.m
//  TO-DO
//
//  Created by Siegrain on 16/6/2.
//  Copyright © 2016年 com.siegrain. All rights reserved.
//

#import "AFHTTPRequestOperationManager+Synchronous.h"
#import "AFNetworking.h"
#import "CDTodo.h"
#import "CDUser.h"
#import "DateUtil.h"
#import "GCDQueue.h"
#import "LCSyncRecord.h"
#import "LCTodo.h"
#import "LCUser.h"
#import "SCLAlertHelper.h"
#import "SyncDataManager.h"

static NSString* const kGetServerDateApiUrl = @"https://api.leancloud.cn/1.1/date";

static NSInteger const kFetchLimitPerQueue = 50;
static NSInteger const kInvalidTimeInterval = 10;

@interface
SyncDataManager ()
@property (nonatomic, readwrite, strong) CDUser* cdUser;
@property (nonatomic, readwrite, strong) LCUser* lcUser;

@property (nonatomic, readwrite, assign) BOOL isSyncing;
@property (nonatomic, readwrite, strong) NSManagedObjectContext* localContext;
@end

@implementation SyncDataManager
#pragma mark - accessors
+ (BOOL)isSyncing
{
    return [[self dataManager] isSyncing];
}
#pragma mark - initial
+ (instancetype)dataManager
{
    static SyncDataManager* dataManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dataManager = [[SyncDataManager alloc] init];
        dataManager.lcUser = [LCUser currentUser];
        dataManager.cdUser = [CDUser userWithLCUser:dataManager.lcUser];
        dataManager.isSyncing = NO;
    });
    return dataManager;
}
- (void)setupContext
{
    /*
	 Mark: MagicalRecord
	 在另一个线程中，对于根上下文的操作是无效的，必须新建一个上下文，该上下文属于根上下文的分支
	 若不想保存该上下文的内容，在执行save之前释放掉即可
	 */
    _localContext = [NSManagedObjectContext MR_newPrivateQueueContext];
}
#pragma mark - synchronization
- (void)synchronize:(void (^)(bool succeed))complete;
{
    //    if (_isSyncing) return complete(YES);
    //    _isSyncing = YES;
    /*
	 同步方式：
	 每一次队列同步最新的五十条数据，有错误的话，队列作废
	 1. 若 Server 没有该 Client(需要手机的唯一识别码进行辨认) 的同步记录，则将本地所有数据进行上传，并将服务器上所有的数据进行下载
	 2. 若 lastSyncTimeOnServer = lastSyncTimeOnClient，表明服务器数据没有变化，则仅需要上传本地修改过的数据和新增的数据	
	 3. 若 lastSyncTimeOnServer > lastSyncTimeOnClient，则进行全数据对比，先对比同步所有已有数据，再将其他数据从服务器上下载
	 
	 注意事项：
	 1. 所有同步时间戳均以服务器时间为准，每次同步之前先获取服务器的时间戳
	 2. 若本地时间与服务器时间相差1分钟以上，提醒并不予同步
	 3. 对比同步规则：1.大版本同步小版本 2.版本相同的话，以线上数据为准进行覆盖（另一种做法是建立冲突副本，根据本项目的实际情况不采用这种方式）
	 */
    __weak typeof(self) weakSelf = self;
    GCDQueue* queue = [GCDQueue globalQueueWithLevel:DISPATCH_QUEUE_PRIORITY_DEFAULT];
    [queue async:^{
        [weakSelf setupContext];

        LCSyncRecord* lastSyncRecord = nil;
        CDSyncRecord* syncRecord = nil;
        if (![weakSelf prepareToSynchornize:&lastSyncRecord cdSyncRecord:&syncRecord])
            return [weakSelf returnWithError:nil description:@"2. 准备同步失败，停止同步" returnWithBlock:complete];

        //2-1. 记录为空，下载所有服务器数据，上传所有本地数据
        if (!lastSyncRecord) {
            __block NSMutableArray<LCTodo*>* todosReadyToUpload = nil;

            dispatch_group_t group = dispatch_group_create();
            //2-1-1. 上传数据
            [queue asyncWithGroup:group block:^{
                NSArray<CDTodo*>* todosNeedsToUpload = [weakSelf fetchTodoHasSynchronized:NO lastRecordIsUpdateAt:[NSDate date]];
                for (CDTodo* todo in todosNeedsToUpload) {
                    //2-1-1-1. 转换为LeanCloud对象，添加到待上传列表中
                    LCTodo* lcTodo = [LCTodo lcTodoWithCDTodo:todo];
                    lcTodo.syncStatus = SyncStatusSynchronizing;
                    [todosReadyToUpload addObject:lcTodo];

                    //2-1-1-2. 修改本地数据状态为同步完成，同时赋予唯一编号
                    todo.syncStatus = @(SyncStatusSynchronized);
                    todo.objectId = lcTodo.objectId;
                }
            }];
            //2-1-2. 下载数据
            [queue asyncWithGroup:group block:^{
                NSArray<LCTodo*>* todosNeedsToDownload = [weakSelf retrieveTodos];
                if (!todosNeedsToDownload) [weakSelf returnWithError:nil description:@"2-1-2. 下载数据失败" returnWithBlock:complete];

                for (LCTodo* todo in todosNeedsToDownload) {
                    CDTodo* cdTodo = [[CDTodo cdTodoWithLCTodo:todo] MR_inContext:_localContext];
                    cdTodo.syncStatus = @(SyncStatusSynchronized);
                }
            }];
            //2-1-3. 回调
            [queue asyncGroupNotify:group block:^{
                // 2-1-3-1. 上传数据并保存服务器的同步记录
                // TODO: 这个东西要用LeanCloud的云函数来做，不然无法保证数据正确
                NSError* error = nil;
                [LCTodo saveAll:todosReadyToUpload error:&error];
                if (error) return [weakSelf returnWithError:error description:@"2-1-3-1. 上传数据失败" returnWithBlock:complete];

                // 2-1-3-2. 保存服务器的同步记录
                NSDate* now = [NSDate date];
                lastSyncRecord.isFinished = YES;
                lastSyncRecord.syncEndTime = now;
                [lastSyncRecord save:&error];
                if (error) [weakSelf returnWithError:nil description:@"2-1-3-2. 同步记录失败" returnWithBlock:complete];

                // 2-1-3-2. 上传成功后更新本地数据
                syncRecord.isFinished = @(YES);
                syncRecord.syncEndTime = now;

                [[GCDQueue mainQueue] sync:^{
                    DDLogInfo(@"all fucking done");
                    return complete(YES);
                }];
            }];
        }
    }];
}
- (BOOL)prepareToSynchornize:(LCSyncRecord**)lastSyncRecord cdSyncRecord:(CDSyncRecord**)cdSyncRecord
{
    //1. 获取服务器上最新的同步记录
    *lastSyncRecord = [self retriveLatestSyncRecord];

    //2. 在本地和线上插入同步记录，准备开始同步
    *cdSyncRecord = [self insertAndGetSyncRecord];
    if (!*cdSyncRecord) return NO;

    return YES;
}
#pragma mark - LeanCloud methods
#pragma mark - retrieve sync record
/**
 *  根据本机唯一标识获取服务器上的最新一条同步记录
 */
- (LCSyncRecord*)retriveLatestSyncRecord
{
    AVQuery* query = [AVQuery queryWithClassName:[LCSyncRecord parseClassName]];
    [query whereKey:@"isFinished" equalTo:@(YES)];
    [query whereKey:@"user" equalTo:_lcUser];
    [query whereKey:@"phoneIdentifier" equalTo:_cdUser.phoneIdentifier];
    [query orderByDescending:@"syncBeginTime"];
    NSError* error = nil;
    LCSyncRecord* record = (LCSyncRecord*)[query getFirstObject:&error];
    if (error && error.code != 101) {  //101意思是没有这个表
        [SCLAlertHelper errorAlertWithContent:error.localizedDescription];
        return [self returnWithError:error description:[NSString stringWithFormat:@"1. %s", __func__]];
        ;
    }

    return record;
}
#pragma mark - retrieve todo
- (NSArray<LCTodo*>*)retrieveTodos
{
    AVQuery* query = [AVQuery queryWithClassName:[LCTodo parseClassName]];
    [query whereKey:@"isHidden" equalTo:@(NO)];
    [query whereKey:@"user" equalTo:_lcUser];
    [query setLimit:kFetchLimitPerQueue];

    NSError* error = nil;
    NSArray<LCTodo*>* array = [query findObjects:&error];
    if (error && error.code != 101) {  //101意思是没有这个表
        [SCLAlertHelper errorAlertWithContent:error.localizedDescription];
        return [self returnWithError:error description:[NSString stringWithFormat:@"2-1. %s", __func__]];
    }

    return array;
}
#pragma mark - MagicRecord methods
#pragma mark - retrieve data that needs to sync
- (NSArray<CDTodo*>*)fetchTodoHasSynchronized:(BOOL)synchronized lastRecordIsUpdateAt:(NSDate*)updateAt
{
    NSMutableArray* arguments = [NSMutableArray new];
    NSString* predicateFormat = @"user = %@ and syncStatus != %@ and updatedAt <= %@";
    [arguments addObjectsFromArray:@[ _cdUser, @(SyncStatusSynchronized), updateAt ]];
    if (synchronized)
        predicateFormat = [predicateFormat stringByAppendingString:@" and objectId != nil"];
    else
        predicateFormat = [predicateFormat stringByAppendingString:@" and objectId = nil"];

    NSPredicate* filter = [NSPredicate predicateWithFormat:predicateFormat argumentArray:[arguments copy]];
    NSFetchRequest* request = [CDTodo MR_requestAllWithPredicate:filter inContext:_localContext];
    [request setFetchLimit:kFetchLimitPerQueue];
    request.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"updatedAt" ascending:NO] ];
    NSArray<CDTodo*>* data = [CDTodo MR_executeFetchRequest:request inContext:_localContext];

    return data;
}
#pragma mark - both MagicRecord and LeanCloud methods
#pragma mark - insert sync record
- (CDSyncRecord*)insertAndGetSyncRecord
{
    NSDate* serverDate = [self serverDate];
    if (!serverDate) return nil;

    NSError* error = nil;
    LCSyncRecord* lcSyncRecord = [LCSyncRecord object];
    lcSyncRecord.isFinished = NO;
    lcSyncRecord.user = self.lcUser;
    lcSyncRecord.syncBeginTime = serverDate;
    lcSyncRecord.phoneIdentifier = self.cdUser.phoneIdentifier;
    lcSyncRecord.syncEndTime = nil;

    [lcSyncRecord save:&error];
    if (error) return [self returnWithError:error description:[NSString stringWithFormat:@"2. %s", __func__]];

    CDSyncRecord* cdSyncRecord = [CDSyncRecord syncRecordFromLCSyncRecord:lcSyncRecord inContext:_localContext];

    return cdSyncRecord;
}
#pragma mark - helper
- (NSDate*)serverDate
{
    NSDictionary* parameters = [NSDictionary dictionaryWithObjects:@[ kLeanCloudAppID, kLeanCloudAppKey ] forKeys:@[ @"X-LC-Id", @"X-LC-Key" ]];
    AFHTTPRequestOperationManager* manager = [AFHTTPRequestOperationManager manager];
    NSError* error = nil;
    NSDictionary* responseObject = [manager syncGET:kGetServerDateApiUrl parameters:parameters operation:nil error:&error];
    if (error) return [self returnWithError:error description:@"2. 无法获取服务器时间"];

    NSDate* serverDate = [DateUtil dateFromISO8601String:responseObject[@"iso"]];
    NSInteger intervalFromServer = fabs([serverDate timeIntervalSince1970] - [[NSDate date] timeIntervalSince1970]);
    if (intervalFromServer > kInvalidTimeInterval) {
        [SCLAlertHelper errorAlertWithContent:@"手机时间和正常时间相差过大，请调整时间后再试。"];
        return [self returnWithError:nil description:@"2. 本地时间和服务器时间相差过大，已停止同步"];
    }

    return serverDate;
}
#pragma mark - failed handler
- (id)returnWithError:(NSError* _Nullable)error description:(NSString* _Nonnull)description
{
    DDLogError(@"%@ ::: %@", description, error ? error.localizedDescription : @"");
    _localContext = nil;
    return nil;
}
- (void)returnWithError:(NSError* _Nullable)error description:(NSString* _Nonnull)description returnWithBlock:(void (^_Nullable)(bool succeed))block
{
    DDLogError(@"%@ ::: %@", description, error ? error.localizedDescription : @"");
    _localContext = nil;

    [[GCDQueue mainQueue] sync:^{
        return block(NO);
    }];
}

@end
