//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

extern const CGFloat OWSMessageHeaderViewDateHeaderVMargin;

@class ConversationStyle;
@class ConversationViewItem;

NS_ASSUME_NONNULL_BEGIN

@interface OWSMessageHeaderView : UIStackView

- (void)loadForDisplayWithViewItem:(ConversationViewItem *)viewItem
                 conversationStyle:(ConversationStyle *)conversationStyle;

- (CGSize)measureWithConversationViewItem:(ConversationViewItem *)viewItem
                        conversationStyle:(ConversationStyle *)conversationStyle;

@end

NS_ASSUME_NONNULL_END
