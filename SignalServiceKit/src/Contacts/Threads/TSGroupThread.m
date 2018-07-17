//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "TSGroupThread.h"
#import "NSData+Base64.h"
#import "TSAttachmentStream.h"
#import <SignalServiceKit/TSAccountManager.h>
#import <YapDatabase/YapDatabaseConnection.h>
#import <YapDatabase/YapDatabaseTransaction.h>

NS_ASSUME_NONNULL_BEGIN

NSString *const TSGroupThreadAvatarChangedNotification = @"TSGroupThreadAvatarChangedNotification";
NSString *const TSGroupThread_NotificationKey_UniqueId = @"TSGroupThread_NotificationKey_UniqueId";

@implementation TSGroupThread

#define TSGroupThreadPrefix @"g"

- (instancetype)initWithGroupModel:(TSGroupModel *)groupModel
{
    OWSAssert(groupModel);
    OWSAssert(groupModel.groupId.length > 0);
    OWSAssert(groupModel.groupMemberIds.count > 0);
    for (NSString *recipientId in groupModel.groupMemberIds) {
        OWSAssert(recipientId.length > 0);
    }

    NSString *uniqueIdentifier = [[self class] threadIdFromGroupId:groupModel.groupId];
    self = [super initWithUniqueId:uniqueIdentifier];
    if (!self) {
        return self;
    }

    _groupModel = groupModel;

    return self;
}

- (instancetype)initWithGroupId:(NSData *)groupId
{
    OWSAssert(groupId.length > 0);

    NSString *localNumber = [TSAccountManager localNumber];
    OWSAssert(localNumber.length > 0);

    TSGroupModel *groupModel = [[TSGroupModel alloc] initWithTitle:nil
                                                         memberIds:@[ localNumber ]
                                                             image:nil
                                                           groupId:groupId];

    self = [self initWithGroupModel:groupModel];
    if (!self) {
        return self;
    }

    return self;
}

+ (nullable instancetype)threadWithGroupId:(NSData *)groupId transaction:(YapDatabaseReadTransaction *)transaction
{
    OWSAssert(groupId.length > 0);

    return [self fetchObjectWithUniqueID:[self threadIdFromGroupId:groupId] transaction:transaction];
}

+ (instancetype)getOrCreateThreadWithGroupId:(NSData *)groupId
                                 transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(groupId.length > 0);
    OWSAssert(transaction);

    TSGroupThread *thread = [self fetchObjectWithUniqueID:[self threadIdFromGroupId:groupId] transaction:transaction];
    if (!thread) {
        thread = [[self alloc] initWithGroupId:groupId];
        [thread saveWithTransaction:transaction];
    }
    return thread;
}

+ (instancetype)getOrCreateThreadWithGroupId:(NSData *)groupId
{
    OWSAssert(groupId.length > 0);

    __block TSGroupThread *thread;
    [[self dbReadWriteConnection] readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        thread = [self getOrCreateThreadWithGroupId:groupId transaction:transaction];
    }];
    return thread;
}

+ (instancetype)getOrCreateThreadWithGroupModel:(TSGroupModel *)groupModel
                                    transaction:(YapDatabaseReadWriteTransaction *)transaction {
    OWSAssert(groupModel);
    OWSAssert(groupModel.groupId.length > 0);
    OWSAssert(transaction);

    TSGroupThread *thread =
        [self fetchObjectWithUniqueID:[self threadIdFromGroupId:groupModel.groupId] transaction:transaction];

    if (!thread) {
        thread = [[TSGroupThread alloc] initWithGroupModel:groupModel];
        [thread saveWithTransaction:transaction];
    }
    return thread;
}

+ (instancetype)getOrCreateThreadWithGroupModel:(TSGroupModel *)groupModel
{
    OWSAssert(groupModel);
    OWSAssert(groupModel.groupId.length > 0);

    __block TSGroupThread *thread;
    [[self dbReadWriteConnection] readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        thread = [self getOrCreateThreadWithGroupModel:groupModel transaction:transaction];
    }];
    return thread;
}

+ (NSString *)threadIdFromGroupId:(NSData *)groupId
{
    OWSAssert(groupId.length > 0);

    return [TSGroupThreadPrefix stringByAppendingString:[groupId base64EncodedString]];
}

+ (NSData *)groupIdFromThreadId:(NSString *)threadId
{
    OWSAssert(threadId.length > 0);

    return [NSData dataFromBase64String:[threadId substringWithRange:NSMakeRange(1, threadId.length - 1)]];
}

- (NSArray<NSString *> *)recipientIdentifiers
{
    NSMutableArray<NSString *> *groupMemberIds = [self.groupModel.groupMemberIds mutableCopy];
    if (groupMemberIds == nil) {
        return @[];
    }

    [groupMemberIds removeObject:[TSAccountManager localNumber]];

    return [groupMemberIds copy];
}

// @returns all threads to which the recipient is a member.
//
// @note If this becomes a hotspot we can extract into a YapDB View.
// As is, the number of groups should be small (dozens, *maybe* hundreds), and we only enumerate them upon SN changes.
+ (NSArray<TSGroupThread *> *)groupThreadsWithRecipientId:(NSString *)recipientId
                                              transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(recipientId.length > 0);
    OWSAssert(transaction);

    NSMutableArray<TSGroupThread *> *groupThreads = [NSMutableArray new];

    [self enumerateCollectionObjectsWithTransaction:transaction usingBlock:^(id obj, BOOL *stop) {
        if ([obj isKindOfClass:[TSGroupThread class]]) {
            TSGroupThread *groupThread = (TSGroupThread *)obj;
            if ([groupThread.groupModel.groupMemberIds containsObject:recipientId]) {
                [groupThreads addObject:groupThread];
            }
        }
    }];

    return [groupThreads copy];
}

- (BOOL)isGroupThread
{
    return true;
}

- (NSString *)name
{
    return self.groupModel.groupName ? self.groupModel.groupName : NSLocalizedString(@"NEW_GROUP_DEFAULT_TITLE", @"");
}

- (void)updateAvatarWithAttachmentStream:(TSAttachmentStream *)attachmentStream
{
    [self.dbReadWriteConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [self updateAvatarWithAttachmentStream:attachmentStream transaction:transaction];
    }];
}

- (void)updateAvatarWithAttachmentStream:(TSAttachmentStream *)attachmentStream
                             transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(attachmentStream);
    OWSAssert(transaction);

    self.groupModel.groupImage = [attachmentStream image];
    [self saveWithTransaction:transaction];

    [transaction addCompletionQueue:nil
                    completionBlock:^{
                        [self fireAvatarChangedNotification];
                    }];

    // Avatars are stored directly in the database, so there's no need
    // to keep the attachment around after assigning the image.
    [attachmentStream removeWithTransaction:transaction];
}

- (void)fireAvatarChangedNotification
{
    OWSAssertIsOnMainThread();

    NSDictionary *userInfo = @{ TSGroupThread_NotificationKey_UniqueId : self.uniqueId };

    [[NSNotificationCenter defaultCenter] postNotificationName:TSGroupThreadAvatarChangedNotification
                                                        object:self.uniqueId
                                                      userInfo:userInfo];
}

@end

NS_ASSUME_NONNULL_END
