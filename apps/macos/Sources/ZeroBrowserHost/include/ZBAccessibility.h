#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class ZBAXNode;

/// One tab's accessibility tree, kept from Chromium's updates, read by VoiceOver through the page view.
@interface ZBAXTree : NSObject
@property (nonatomic, weak, nullable) NSView *view;
@property (nonatomic, copy, nullable) NSString *treeId;
/// What VoiceOver's press does (a click at the element's centre, as CEF's own Mac bridge does).
@property (nonatomic, copy, nullable) void (^press)(ZBAXNode *node);
/// A field focused (text nil) or filled with `text` as if typed: what 1Password's Universal Autofill and other
/// assistive apps set through AXFocused and AXValue.
@property (nonatomic, copy, nullable) void (^fill)(ZBAXNode *node, NSString *_Nullable text);
/// Every notification the tree posts for VoiceOver (announcements, values, states), as it posts it: Zero Dev's checks
/// read them back.
@property (nonatomic, copy, nullable) void (^posted)(id element, NSString *name, NSDictionary *_Nullable info);
/// The page's address, from Chromium's tree data: the web area's AXURL, which tells assistive apps (1Password) the site.
@property (nonatomic, readonly, nullable) NSString *url;
@property (nonatomic, readonly, nullable) ZBAXNode *root;
@property (nonatomic, readonly, nullable) ZBAXNode *focused;
@property (nonatomic, readonly) NSUInteger count;
- (void)apply:(NSString *)json;
- (void)move:(NSString *)json;
- (nullable ZBAXNode *)node:(int)nodeId;
@end

@interface ZBAXNode : NSAccessibilityElement
/// Where it is, in the page view's points.
- (CGRect)pageRect;
@end

NS_ASSUME_NONNULL_END
