#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

// YTLiquidGlass v3.3-DIAGNOSTIC — Runtime watch-row inspector
//
// Goals:
//   • Use UIKit's own iOS 26+/27 Liquid Glass tab bar presentation.
//   • Never use UITabBarController, so UIKit cannot create a "More" tab.
//   • Treat YouTube/YTLite's renderer array as the source of truth for
//     active tabs and their order.
//   • Forward selections back to YouTube via selectItemWithPivotIdentifier:.
//   • Preserve YTLite add/remove/reorder/custom-tab behavior.
//
// No Home/Shorts/Subscriptions/etc. identifiers are hard-coded.

@interface YTIPivotBarItemRenderer : NSObject
@property(nonatomic, copy, readonly) NSString *pivotIdentifier;
// YouTube uses this for thumbnail-backed pivot items such as the account/avatar tab.
@property(nonatomic, strong, readonly) id thumbnail;
@end

@interface YTIPivotBarIconOnlyItemRenderer : NSObject
@property(nonatomic, copy, readonly) NSString *pivotIdentifier;
@end

@interface YTIPivotBarSupportedRenderers : NSObject
- (YTIPivotBarItemRenderer *)pivotBarItemRenderer;
- (YTIPivotBarIconOnlyItemRenderer *)pivotBarIconOnlyItemRenderer;
@end

@interface YTIPivotBarRenderer : NSObject
- (NSMutableArray<YTIPivotBarSupportedRenderers *> *)itemsArray;
@end

@interface YTPivotBarViewController : UIViewController
@property(nonatomic, copy, readonly) NSString *selectedPivotIdentifier;
- (UIView *)pivotBarView;
- (void)selectItemWithPivotIdentifier:(id)identifier;
@end

@interface YTPivotBarView : UIView
- (void)setRenderer:(YTIPivotBarRenderer *)renderer;
- (void)selectItemWithPivotIdentifier:(id)identifier;
@end

@interface YTPivotBarItemView : UIView
@property(nonatomic, strong, readonly) YTIPivotBarItemRenderer *renderer;
@property(nonatomic, strong, readonly) UIButton *navigationButton;
@property(nonatomic, weak, readonly) YTPivotBarViewController *delegate;
- (void)setRenderer:(id)renderer;
@end

// Dedicated YouTube container for the top-right navigation controls.
// Current YouTubeHeader exposes this class publicly, so we can target the
// header controls without touching arbitrary YTQTMButton instances elsewhere.
@interface YTRightNavigationButtons : UIView
@property(nonatomic, assign) CGFloat leadingPadding;
@property(nonatomic, assign) CGFloat tailingPadding;
- (id)buttonForType:(NSUInteger)type;
- (void)setButton:(id)button forType:(NSUInteger)type;
@end


@interface YTSearchViewController : UIViewController
@end

// YouTube's normal navigation/header surface used on results and pushed pages.
@interface YTHeaderView : UIView
@end


@interface YTActionSheetAction : NSObject
@property(nonatomic, copy, readonly) NSString *title;
@property(nonatomic, strong, readonly) UIImage *iconImage;
@property(nonatomic, strong, readonly) UIButton *button;
@property(nonatomic, copy, readonly) id handler;
@property(nonatomic, assign, readonly) BOOL shouldDismissOnAction;
@end

@interface YTActionSheetController : NSObject
@property(nonatomic, strong, readonly) UIView *sourceView;
- (NSArray<YTActionSheetAction *> *)actions;
@end

@interface YTDefaultSheetController : NSObject
- (NSArray<YTActionSheetAction *> *)actions;
@end


// Normal channel/profile-page header. We only touch titled action buttons
// inside this container; player/Shorts controls are never scanned.
@interface YTC4TabbedHeaderView : UIView
@property(nonatomic, readonly) UIView *subscribeSwitch;
@property(nonatomic, readonly) UIView *sponsorButton;
@end


// These are the controls shown BELOW a normal watch-page video. They are
// metadata/action UI, not part of the player overlay.
@interface YTSlimVideoDetailsActionView : UIView
// Current YouTubeHeader exposes the label/toggle state, but no longer exposes
// the old child `button` property used by earlier YouTube builds.
@property(nonatomic, strong, readwrite) UILabel *label;
@property(nonatomic, assign, readwrite, getter=isToggled) BOOL toggled;
@end

@interface YTSlimVideoScrollableActionBarCell : UICollectionViewCell
@end

@interface YTSlimVideoOwnerView : UIView
@property(nonatomic, readonly) UIView *subscribeSwitch;
@property(nonatomic, strong) UIView *sponsorButton;
@property(nonatomic, readonly) UIView *notificationMultiToggleButton;
@property(nonatomic, readonly) UIView *notificationToggleButton;
@end


// Reusable YouTube/Google controls used throughout normal non-player UI.
@interface YTLightweightQTMButton : UIButton
@property(nonatomic, strong) UIColor *enabledBackgroundColor;
@property(nonatomic, strong) UIColor *disabledBackgroundColorLight;
@property(nonatomic, strong) UIColor *disabledBackgroundColorDark;
@end

@interface YTSubscribeSwitch : UIControl
@end

@interface YTNotificationPreferenceToggleButton : UIButton
@end

@interface YTNotificationMultiToggleButton : UIButton
@end

static const void *kYTLGNativeBarKey = &kYTLGNativeBarKey;
static const void *kYTLGActiveIdentifiersKey = &kYTLGActiveIdentifiersKey;
static const void *kYTLGOwnerKey = &kYTLGOwnerKey;
static const void *kYTLGRefreshingKey = &kYTLGRefreshingKey;

#pragma mark - Native bar subclass

@interface YTLGNativeTabBar : UITabBar <UITabBarDelegate>
@property(nonatomic, weak) YTPivotBarViewController *youtubeController;
@property(nonatomic, copy) NSArray<NSString *> *pivotIdentifiers;
@property(nonatomic, copy) NSString *contentSignature;
@property(nonatomic, assign) BOOL syncingSelection;
@end

@implementation YTLGNativeTabBar

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.delegate = self;
        self.syncingSelection = NO;

        // Standalone UITabBar: display all items directly.
        // This avoids UITabBarController's automatic "More" controller.
        self.itemPositioning = UITabBarItemPositioningFill;

        self.translucent = YES;
        self.opaque = NO;
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = NO;

        self.accessibilityIdentifier =
            @"YTLiquidGlass.NativeTabBar";
    }
    return self;
}

- (void)tabBar:(UITabBar *)tabBar
 didSelectItem:(UITabBarItem *)item {

    if (self.syncingSelection) {
        return;
    }

    NSUInteger index =
        [tabBar.items indexOfObjectIdenticalTo:item];

    if (index == NSNotFound ||
        index >= self.pivotIdentifiers.count) {
        return;
    }

    NSString *identifier =
        self.pivotIdentifiers[index];

    if (identifier.length > 0 &&
        self.youtubeController) {

        [self.youtubeController
            selectItemWithPivotIdentifier:identifier];
    }
}

@end

#pragma mark - Renderer source of truth

static NSString *
YTLGPivotIdentifierForSupportedRenderer(
    YTIPivotBarSupportedRenderers *supported
) {
    if (!supported) return nil;

    YTIPivotBarItemRenderer *regular = nil;
    YTIPivotBarIconOnlyItemRenderer *iconOnly = nil;

    if ([supported
            respondsToSelector:
                @selector(pivotBarItemRenderer)]) {
        regular =
            [supported pivotBarItemRenderer];
    }

    if (regular.pivotIdentifier.length > 0) {
        return regular.pivotIdentifier;
    }

    if ([supported
            respondsToSelector:
                @selector(pivotBarIconOnlyItemRenderer)]) {
        iconOnly =
            [supported pivotBarIconOnlyItemRenderer];
    }

    if (iconOnly.pivotIdentifier.length > 0) {
        return iconOnly.pivotIdentifier;
    }

    return nil;
}

static NSArray<NSString *> *
YTLGIdentifiersFromRenderer(
    YTIPivotBarRenderer *renderer
) {
    if (!renderer ||
        ![renderer respondsToSelector:@selector(itemsArray)]) {
        return @[];
    }

    NSMutableArray<NSString *> *identifiers =
        [NSMutableArray array];

    NSArray *supportedItems =
        [renderer itemsArray];

    for (YTIPivotBarSupportedRenderers *supported
            in supportedItems) {

        NSString *identifier =
            YTLGPivotIdentifierForSupportedRenderer(
                supported
            );

        if (identifier.length == 0) {
            continue;
        }

        // Avoid accidental duplicate renderers producing duplicate native tabs.
        if (![identifiers containsObject:identifier]) {
            [identifiers addObject:identifier];
        }
    }

    return identifiers;
}

static void YTLGStoreActiveIdentifiers(
    YTPivotBarView *bar,
    NSArray<NSString *> *identifiers
) {
    if (!bar) return;

    objc_setAssociatedObject(
        bar,
        kYTLGActiveIdentifiersKey,
        [identifiers copy],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );
}

static NSArray<NSString *> *
YTLGActiveIdentifiers(YTPivotBarView *bar) {
    NSArray *value =
        objc_getAssociatedObject(
            bar,
            kYTLGActiveIdentifiersKey
        );

    return [value isKindOfClass:NSArray.class]
        ? value
        : @[];
}

#pragma mark - Runtime item views

static void YTLGCollectItemViews(
    UIView *view,
    NSMutableArray<YTPivotBarItemView *> *items,
    UIView *nativeBar
) {
    if (!view || view == nativeBar) {
        return;
    }

    Class itemClass =
        NSClassFromString(@"YTPivotBarItemView");

    if (itemClass &&
        [view isKindOfClass:itemClass]) {
        [items addObject:(YTPivotBarItemView *)view];
        return;
    }

    for (UIView *subview in view.subviews) {
        YTLGCollectItemViews(
            subview,
            items,
            nativeBar
        );
    }
}

static NSArray<YTPivotBarItemView *> *
YTLGAllItemViews(YTPivotBarView *bar) {
    NSMutableArray *items =
        [NSMutableArray array];

    UIView *nativeBar =
        objc_getAssociatedObject(
            bar,
            kYTLGNativeBarKey
        );

    YTLGCollectItemViews(
        bar,
        items,
        nativeBar
    );

    return items;
}

static NSDictionary<NSString *, YTPivotBarItemView *> *
YTLGItemViewsByIdentifier(YTPivotBarView *bar) {
    NSMutableDictionary *map =
        [NSMutableDictionary dictionary];

    for (YTPivotBarItemView *item
            in YTLGAllItemViews(bar)) {

        NSString *identifier =
            item.renderer.pivotIdentifier;

        if (identifier.length > 0 &&
            !map[identifier]) {
            map[identifier] = item;
        }
    }

    return map;
}

static YTPivotBarView *
YTLGAncestorPivotBar(UIView *view) {
    Class barClass =
        NSClassFromString(@"YTPivotBarView");

    UIView *candidate = view;

    while (candidate) {
        if (barClass &&
            [candidate isKindOfClass:barClass]) {
            return (YTPivotBarView *)candidate;
        }

        candidate = candidate.superview;
    }

    return nil;
}

#pragma mark - Native item appearance

static BOOL
YTLGItemUsesOriginalArtwork(YTPivotBarItemView *item) {
    if (!item) {
        return NO;
    }

    // YouTube's profile/account pivot is thumbnail-backed rather than a normal
    // vector icon. Never template-tint thumbnail artwork: doing so turns the
    // account picture into a flat white/blue silhouette.
    id thumbnail = item.renderer.thumbnail;
    if (thumbnail != nil) {
        return YES;
    }

    return NO;
}

static UIImage *
YTLGNativeImage(UIImage *image, BOOL preserveOriginal) {
    if (![image isKindOfClass:UIImage.class]) {
        return nil;
    }

    if (preserveOriginal ||
        image.renderingMode ==
            UIImageRenderingModeAlwaysOriginal) {

        return [image
            imageWithRenderingMode:
                UIImageRenderingModeAlwaysOriginal];
    }

    // Normal tab glyphs stay template images so UIKit's native Liquid Glass
    // bar can apply adaptive selected/unselected coloring.
    return [image
        imageWithRenderingMode:
            UIImageRenderingModeAlwaysTemplate];
}

static NSString *
YTLGTitleForItemView(YTPivotBarItemView *item) {
    UIButton *button = item.navigationButton;

    if (![button isKindOfClass:UIButton.class]) {
        return nil;
    }

    NSString *normal =
        [button titleForState:UIControlStateNormal];

    // Respect YTLite's "Hide Tab Labels" feature.
    if (normal != nil) {
        return normal.length > 0 ? normal : nil;
    }

    NSString *current = button.currentTitle;

    if (current.length > 0) {
        return current;
    }

    return nil;
}

static NSString *
YTLGAccessibilityTitle(
    YTPivotBarItemView *item,
    NSString *visibleTitle,
    NSString *identifier
) {
    NSString *label =
        item.navigationButton.accessibilityLabel;

    if (label.length > 0) {
        return label;
    }

    if (visibleTitle.length > 0) {
        return visibleTitle;
    }

    return identifier;
}

static UIImage *
YTLGNormalImageForItem(
    YTPivotBarItemView *item
) {
    UIButton *button = item.navigationButton;

    if (![button isKindOfClass:UIButton.class]) {
        return nil;
    }

    UIImage *image =
        [button imageForState:UIControlStateNormal];

    if (!image) {
        image = button.currentImage;
    }

    if (!image) {
        image = button.imageView.image;
    }

    return YTLGNativeImage(
        image,
        YTLGItemUsesOriginalArtwork(item)
    );
}

static UIImage *
YTLGSelectedImageForItem(
    YTPivotBarItemView *item,
    UIImage *fallback
) {
    UIButton *button = item.navigationButton;

    if (![button isKindOfClass:UIButton.class]) {
        return fallback;
    }

    UIImage *image =
        [button imageForState:UIControlStateSelected];

    if (!image) {
        image =
            [button imageForState:
                UIControlStateHighlighted];
    }

    if (!image) {
        image = fallback;
    }

    return YTLGNativeImage(
        image,
        YTLGItemUsesOriginalArtwork(item)
    );
}

static NSString *
YTLGContentSignature(
    NSArray<NSString *> *identifiers,
    NSDictionary<NSString *, YTPivotBarItemView *> *views
) {
    NSMutableArray *parts =
        [NSMutableArray array];

    for (NSString *identifier in identifiers) {
        YTPivotBarItemView *item =
            views[identifier];

        NSString *title =
            item ? (YTLGTitleForItemView(item) ?: @"")
                 : @"";

        UIImage *normal =
            item ? YTLGNormalImageForItem(item)
                 : nil;

        UIImage *selected =
            item ? YTLGSelectedImageForItem(
                       item,
                       normal
                   )
                 : nil;

        [parts addObject:
            [NSString stringWithFormat:
                @"%@|%@|%lu|%lu",
                identifier,
                title,
                (unsigned long)normal.hash,
                (unsigned long)selected.hash]];
    }

    return [parts componentsJoinedByString:@"||"];
}

#pragma mark - Old YouTube chrome suppression

static BOOL YTLGViewContainsPivotItem(
    UIView *view,
    UIView *nativeBar
) {
    if (!view || view == nativeBar) {
        return NO;
    }

    Class itemClass =
        NSClassFromString(@"YTPivotBarItemView");

    if (itemClass &&
        [view isKindOfClass:itemClass]) {
        return YES;
    }

    for (UIView *subview in view.subviews) {
        if (YTLGViewContainsPivotItem(
                subview,
                nativeBar)) {
            return YES;
        }
    }

    return NO;
}

static void YTLGSuppressOriginalChrome(
    YTPivotBarView *bar,
    YTLGNativeTabBar *nativeBar
) {
    if (!bar || !nativeBar) return;

    bar.opaque = NO;
    bar.backgroundColor = UIColor.clearColor;
    bar.layer.backgroundColor =
        UIColor.clearColor.CGColor;

    // Preserve layout containers that own real YTPivotBarItemView instances,
    // but hide other custom background/indicator siblings.
    for (UIView *subview in bar.subviews) {
        if (subview == nativeBar) {
            subview.hidden = NO;
            subview.alpha = 1.0;
            subview.userInteractionEnabled = YES;
            continue;
        }

        if (YTLGViewContainsPivotItem(
                subview,
                nativeBar)) {

            subview.hidden = NO;

            // Keep its layout alive, but remove custom backing color.
            subview.opaque = NO;
            subview.backgroundColor =
                UIColor.clearColor;
        } else {
            subview.alpha = 0.0;
            subview.userInteractionEnabled = NO;
        }
    }

    // Hide YouTube's actual tab buttons while leaving their renderer/button
    // objects alive for YTLite updates and for icon/title mirroring.
    for (YTPivotBarItemView *item
            in YTLGAllItemViews(bar)) {

        item.alpha = 0.0;
        item.userInteractionEnabled = NO;
        item.opaque = NO;
        item.backgroundColor =
            UIColor.clearColor;
    }

    nativeBar.hidden = NO;
    nativeBar.alpha = 1.0;
    nativeBar.userInteractionEnabled = YES;

    [bar bringSubviewToFront:nativeBar];

    bar.clipsToBounds = NO;
    bar.layer.masksToBounds = NO;
}

#pragma mark - Native UITabBar creation

static YTLGNativeTabBar *
YTLGNativeBarForPivotBar(YTPivotBarView *bar) {
    YTLGNativeTabBar *nativeBar =
        objc_getAssociatedObject(
            bar,
            kYTLGNativeBarKey
        );

    if (!nativeBar) {
        nativeBar =
            [[YTLGNativeTabBar alloc]
                initWithFrame:bar.bounds];

        nativeBar.autoresizingMask =
            UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleHeight;

        [bar addSubview:nativeBar];

        objc_setAssociatedObject(
            bar,
            kYTLGNativeBarKey,
            nativeBar,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }

    return nativeBar;
}

static YTPivotBarViewController *
YTLGOwnerForBar(YTPivotBarView *bar) {
    return objc_getAssociatedObject(
        bar,
        kYTLGOwnerKey
    );
}

static void YTLGSetOwnerForBar(
    YTPivotBarView *bar,
    YTPivotBarViewController *owner
) {
    objc_setAssociatedObject(
        bar,
        kYTLGOwnerKey,
        owner,
        OBJC_ASSOCIATION_ASSIGN
    );
}

#pragma mark - Refresh

static void YTLGSyncSelection(
    YTPivotBarView *bar,
    YTLGNativeTabBar *nativeBar
) {
    YTPivotBarViewController *owner =
        YTLGOwnerForBar(bar);

    if (!owner) return;

    NSString *selected =
        owner.selectedPivotIdentifier;

    if (selected.length == 0) return;

    NSUInteger index =
        [nativeBar.pivotIdentifiers
            indexOfObject:selected];

    if (index == NSNotFound ||
        index >= nativeBar.items.count) {
        return;
    }

    UITabBarItem *target =
        nativeBar.items[index];

    if (nativeBar.selectedItem != target) {
        nativeBar.syncingSelection = YES;
        nativeBar.selectedItem = target;
        nativeBar.syncingSelection = NO;
    }
}

static void YTLGRefreshNow(
    YTPivotBarView *bar
) {
    if (!bar ||
        CGRectIsEmpty(bar.bounds)) {
        return;
    }

    NSNumber *refreshing =
        objc_getAssociatedObject(
            bar,
            kYTLGRefreshingKey
        );

    if (refreshing.boolValue) {
        return;
    }

    objc_setAssociatedObject(
        bar,
        kYTLGRefreshingKey,
        @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    YTLGNativeTabBar *nativeBar =
        YTLGNativeBarForPivotBar(bar);

    nativeBar.frame = bar.bounds;
    nativeBar.youtubeController =
        YTLGOwnerForBar(bar);

    NSArray<NSString *> *identifiers =
        YTLGActiveIdentifiers(bar);

    NSDictionary<NSString *,
                 YTPivotBarItemView *> *views =
        YTLGItemViewsByIdentifier(bar);

    // If setRenderer has not supplied the authoritative list yet, fall back
    // briefly to the live item views. As soon as the renderer arrives this is
    // replaced by YTLite's real active order.
    if (identifiers.count == 0 &&
        views.count > 0) {

        NSMutableArray *fallback =
            [NSMutableArray array];

        NSArray *allViews =
            YTLGAllItemViews(bar);

        [allViews
            enumerateObjectsUsingBlock:
                ^(YTPivotBarItemView *item,
                  NSUInteger idx,
                  BOOL *stop) {

            NSString *identifier =
                item.renderer.pivotIdentifier;

            if (identifier.length > 0 &&
                ![fallback
                    containsObject:identifier]) {

                [fallback addObject:identifier];
            }
        }];

        identifiers = fallback;
    }

    NSString *signature =
        YTLGContentSignature(
            identifiers,
            views
        );

    if (![nativeBar.contentSignature
            isEqualToString:signature]) {

        NSMutableArray<UITabBarItem *> *nativeItems =
            [NSMutableArray array];

        NSMutableArray<NSString *> *nativeIdentifiers =
            [NSMutableArray array];

        for (NSString *identifier in identifiers) {
            YTPivotBarItemView *itemView =
                views[identifier];

            // Wait for the concrete item view before exposing this tab.
            // Item-view setRenderer:/layout hooks will trigger another refresh.
            if (!itemView) {
                continue;
            }

            NSString *title =
                YTLGTitleForItemView(itemView);

            NSString *accessibilityTitle =
                YTLGAccessibilityTitle(
                    itemView,
                    title,
                    identifier
                );

            UIImage *normal =
                YTLGNormalImageForItem(
                    itemView
                );

            UIImage *selected =
                YTLGSelectedImageForItem(
                    itemView,
                    normal
                );

            UITabBarItem *nativeItem =
                [[UITabBarItem alloc]
                    initWithTitle:title
                           image:normal
                   selectedImage:selected];

            nativeItem.accessibilityLabel =
                accessibilityTitle;

            [nativeItems addObject:nativeItem];
            [nativeIdentifiers addObject:identifier];
        }

        nativeBar.pivotIdentifiers =
            nativeIdentifiers;

        // Standalone UITabBar displays the supplied items directly and never
        // synthesizes UITabBarController's "More" view controller.
        [nativeBar
            setItems:nativeItems
            animated:NO];

        nativeBar.contentSignature =
            signature;
    }

    // Force even redistribution whenever the active count changes.
    nativeBar.itemPositioning =
        UITabBarItemPositioningFill;

    YTLGSyncSelection(
        bar,
        nativeBar
    );

    YTLGSuppressOriginalChrome(
        bar,
        nativeBar
    );

    [nativeBar setNeedsLayout];
    [nativeBar layoutIfNeeded];

    objc_setAssociatedObject(
        bar,
        kYTLGRefreshingKey,
        @NO,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );
}

static void YTLGRefreshSoon(
    YTPivotBarView *bar
) {
    if (!bar) return;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (bar.window) {
                YTLGRefreshNow(bar);
            }
        }
    );
}

static void YTLGRefreshAfter(
    YTPivotBarView *bar,
    NSTimeInterval delay
) {
    if (!bar) return;

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(delay * NSEC_PER_SEC)
        ),
        dispatch_get_main_queue(),
        ^{
            if (bar.window) {
                YTLGRefreshNow(bar);
            }
        }
    );
}

static void YTLGInstallForController(
    YTPivotBarViewController *owner
) {
    if (!owner) return;

    UIView *rawBar =
        [owner pivotBarView];

    Class barClass =
        NSClassFromString(@"YTPivotBarView");

    if (!rawBar ||
        !barClass ||
        ![rawBar isKindOfClass:barClass]) {
        return;
    }

    YTPivotBarView *bar =
        (YTPivotBarView *)rawBar;

    YTLGSetOwnerForBar(
        bar,
        owner
    );

    YTLGNativeTabBar *nativeBar =
        YTLGNativeBarForPivotBar(bar);

    nativeBar.youtubeController = owner;
    nativeBar.frame = bar.bounds;

    YTLGRefreshNow(bar);

    // YouTube builds some item buttons asynchronously after the controller
    // appears. These settle passes make a fresh install converge without
    // requiring the user to switch tabs or reopen the app.
    YTLGRefreshAfter(bar, 0.05);
    YTLGRefreshAfter(bar, 0.20);
    YTLGRefreshAfter(bar, 0.60);
}

#pragma mark - Hooks

%group YTLiquidGlassStandaloneTabBar

%hook YTPivotBarView

- (void)setRenderer:(YTIPivotBarRenderer *)renderer {
    %orig(renderer);

    // YTLite mutates renderer.itemsArray when tabs are enabled/disabled.
    // Capture that post-hook renderer as the authoritative active order.
    NSArray<NSString *> *identifiers =
        YTLGIdentifiersFromRenderer(renderer);

    YTLGStoreActiveIdentifiers(
        self,
        identifiers
    );

    YTLGRefreshSoon(self);
    YTLGRefreshAfter(self, 0.10);
}

- (void)layoutSubviews {
    %orig;

    YTLGNativeTabBar *nativeBar =
        objc_getAssociatedObject(
            self,
            kYTLGNativeBarKey
        );

    if (nativeBar) {
        nativeBar.frame = self.bounds;
        YTLGRefreshNow(self);
    }
}

- (void)didMoveToWindow {
    %orig;

    if (self.window) {
        YTLGRefreshSoon(self);
        YTLGRefreshAfter(self, 0.15);
    }
}

- (void)selectItemWithPivotIdentifier:(id)identifier {
    %orig(identifier);

    YTLGRefreshSoon(self);
}

%end

%hook YTPivotBarItemView

- (void)setRenderer:(id)renderer {
    %orig(renderer);

    YTPivotBarView *bar =
        YTLGAncestorPivotBar(self);

    if (bar) {
        YTLGRefreshSoon(bar);
        YTLGRefreshAfter(bar, 0.05);
    }
}

- (void)didMoveToWindow {
    %orig;

    if (self.window) {
        YTPivotBarView *bar =
            YTLGAncestorPivotBar(self);

        if (bar) {
            YTLGRefreshSoon(bar);
        }
    }
}

%end

%hook YTPivotBarViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            YTLGInstallForController(self);
        }
    );
}

- (void)viewDidLayoutSubviews {
    %orig;

    YTLGInstallForController(self);
}

- (void)selectItemWithPivotIdentifier:(id)identifier {
    %orig(identifier);

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            YTLGInstallForController(self);

            UIView *rawBar =
                [self pivotBarView];

            if (rawBar) {
                YTLGRefreshNow(
                    (YTPivotBarView *)rawBar
                );
            }
        }
    );
}

%end

%end


#pragma mark - Top navigation Liquid Glass

static const void *kYTLGTopNavGlassKey = &kYTLGTopNavGlassKey;

static UIVisualEffect *YTLGTopNavigationGlassEffect(void) {
    if (@available(iOS 26.0, *)) {
        Class glassClass = NSClassFromString(@"UIGlassEffect");

        if (glassClass &&
            [glassClass respondsToSelector:@selector(effectWithStyle:)]) {

            UIGlassEffect *effect =
                [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];

            // The YouTube buttons remain the hit-test owners above this
            // sibling glass surface.
            effect.interactive = NO;
            return effect;
        }
    }

    return [UIBlurEffect
        effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
}

static void YTLGCollectTopNavigationControls(
    UIView *view,
    NSMutableArray<UIControl *> *controls
) {
    if (!view) return;

    for (UIView *subview in view.subviews) {
        if (subview.hidden ||
            subview.alpha <= 0.01 ||
            CGRectIsEmpty(subview.bounds)) {
            continue;
        }

        if ([subview isKindOfClass:UIControl.class]) {
            [controls addObject:(UIControl *)subview];
            continue;
        }

        YTLGCollectTopNavigationControls(
            subview,
            controls
        );
    }
}

static CGRect YTLGTopNavigationContentRect(
    YTRightNavigationButtons *container
) {
    NSMutableArray<UIControl *> *controls =
        [NSMutableArray array];

    YTLGCollectTopNavigationControls(
        container,
        controls
    );

    CGRect unionRect = CGRectNull;

    for (UIControl *control in controls) {
        CGRect frame =
            [control convertRect:control.bounds
                          toView:container];

        if (CGRectIsEmpty(frame) ||
            frame.size.width < 4.0 ||
            frame.size.height < 4.0) {
            continue;
        }

        unionRect =
            CGRectIsNull(unionRect)
                ? frame
                : CGRectUnion(unionRect, frame);
    }

    if (CGRectIsNull(unionRect) ||
        CGRectIsEmpty(unionRect)) {

        unionRect = container.bounds;
    }

    // Native navigation glass typically has a little optical breathing room
    // around the 44pt button targets.
    unionRect = CGRectInset(
        unionRect,
        -6.0,
        -4.0
    );

    // Keep the glass inside the actual navigation container when possible.
    CGRect bounds = container.bounds;

    if (!CGRectIsEmpty(bounds)) {
        CGFloat minX = MAX(CGRectGetMinX(bounds),
                           CGRectGetMinX(unionRect));
        CGFloat minY = MAX(CGRectGetMinY(bounds),
                           CGRectGetMinY(unionRect));
        CGFloat maxX = MIN(CGRectGetMaxX(bounds),
                           CGRectGetMaxX(unionRect));
        CGFloat maxY = MIN(CGRectGetMaxY(bounds),
                           CGRectGetMaxY(unionRect));

        if (maxX > minX && maxY > minY) {
            unionRect =
                CGRectMake(
                    minX,
                    minY,
                    maxX - minX,
                    maxY - minY
                );
        }
    }

    // A single icon should still get a proper round 44pt glass surface.
    CGFloat targetHeight =
        MAX(44.0, unionRect.size.height);

    CGFloat targetWidth =
        MAX(targetHeight, unionRect.size.width);

    CGPoint center =
        CGPointMake(
            CGRectGetMidX(unionRect),
            CGRectGetMidY(unionRect)
        );

    return CGRectMake(
        center.x - targetWidth * 0.5,
        center.y - targetHeight * 0.5,
        targetWidth,
        targetHeight
    );
}

static UIVisualEffectView *
YTLGTopNavigationGlassView(
    YTRightNavigationButtons *container
) {
    UIVisualEffectView *glass =
        objc_getAssociatedObject(
            container,
            kYTLGTopNavGlassKey
        );

    if (!glass) {
        glass =
            [[UIVisualEffectView alloc]
                initWithEffect:
                    YTLGTopNavigationGlassEffect()];

        glass.userInteractionEnabled = NO;
        glass.opaque = NO;
        glass.backgroundColor = UIColor.clearColor;
        glass.clipsToBounds = YES;
        glass.layer.cornerCurve =
            kCACornerCurveContinuous;

        glass.accessibilityIdentifier =
            @"YTLiquidGlass.TopNavigation";

        objc_setAssociatedObject(
            container,
            kYTLGTopNavGlassKey,
            glass,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }

    return glass;
}

static void YTLGRemoveTopNavigationGlass(
    YTRightNavigationButtons *container
) {
    UIVisualEffectView *glass =
        objc_getAssociatedObject(
            container,
            kYTLGTopNavGlassKey
        );

    [glass removeFromSuperview];
}

static void YTLGUpdateTopNavigationGlass(
    YTRightNavigationButtons *container
) {
    if (!container ||
        !container.window ||
        !container.superview ||
        CGRectIsEmpty(container.bounds)) {
        return;
    }

    UIView *host = container.superview;

    UIVisualEffectView *glass =
        YTLGTopNavigationGlassView(container);

    // Host the effect as a sibling immediately behind YouTube's button
    // container. This lets the material sample the real page/header backdrop
    // and avoids placing a backdrop effect *inside* another control hierarchy.
    if (glass.superview != host) {
        [glass removeFromSuperview];

        NSUInteger index =
            [host.subviews indexOfObjectIdenticalTo:container];

        if (index == NSNotFound) {
            [host addSubview:glass];
            [host bringSubviewToFront:container];
        } else {
            [host insertSubview:glass
                        atIndex:index];
        }
    }

    CGRect localRect =
        YTLGTopNavigationContentRect(container);

    CGRect hostRect =
        [container convertRect:localRect
                        toView:host];

    glass.frame = hostRect;

    CGFloat radius =
        MIN(
            hostRect.size.height * 0.5,
            24.0
        );

    glass.layer.cornerRadius =
        MAX(0.0, radius);

    // Remove the legacy flat backing while keeping every original button,
    // target/action, accessibility label and avatar untouched.
    container.opaque = NO;
    container.backgroundColor =
        UIColor.clearColor;
    container.layer.backgroundColor =
        UIColor.clearColor.CGColor;

    // The glass must remain immediately below YouTube's live controls.
    [host insertSubview:glass
           belowSubview:container];
}

static void YTLGRefreshTopNavigationSoon(
    YTRightNavigationButtons *container
) {
    if (!container) return;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (container.window) {
                YTLGUpdateTopNavigationGlass(
                    container
                );
            }
        }
    );
}

%group YTLiquidGlassTopNavigation

%hook YTRightNavigationButtons

- (void)layoutSubviews {
    %orig;

    YTLGUpdateTopNavigationGlass(self);
}

- (void)didMoveToSuperview {
    %orig;

    if (self.superview) {
        YTLGRefreshTopNavigationSoon(self);
    } else {
        YTLGRemoveTopNavigationGlass(self);
    }
}

- (void)didMoveToWindow {
    %orig;

    if (self.window) {
        YTLGRefreshTopNavigationSoon(self);
    } else {
        YTLGRemoveTopNavigationGlass(self);
    }
}

- (void)setButton:(id)button
          forType:(NSUInteger)type {

    %orig(button, type);

    // Search/cast/notifications/account controls can be added/removed
    // dynamically. Recompute the capsule from whatever buttons YouTube
    // actually has after that update.
    YTLGRefreshTopNavigationSoon(self);
}

%end

%end


#pragma mark - Search box Liquid Glass

static const void *kYTLGSearchGlassKey = &kYTLGSearchGlassKey;

static UIVisualEffect *YTLGSearchGlassEffect(void) {
    if (@available(iOS 26.0, *)) {
        Class glassClass = NSClassFromString(@"UIGlassEffect");

        if (glassClass &&
            [glassClass respondsToSelector:@selector(effectWithStyle:)]) {

            UIGlassEffect *effect =
                [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];

            // The real YouTube search box remains responsible for interaction.
            effect.interactive = NO;
            return effect;
        }
    }

    return [UIBlurEffect
        effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
}

static UIVisualEffectView *
YTLGSearchGlassView(UIView *searchBox) {
    UIVisualEffectView *glass =
        objc_getAssociatedObject(
            searchBox,
            kYTLGSearchGlassKey
        );

    if (!glass) {
        glass =
            [[UIVisualEffectView alloc]
                initWithEffect:
                    YTLGSearchGlassEffect()];

        glass.userInteractionEnabled = NO;
        glass.opaque = NO;
        glass.backgroundColor =
            UIColor.clearColor;

        glass.clipsToBounds = YES;
        glass.layer.cornerCurve =
            kCACornerCurveContinuous;

        glass.accessibilityIdentifier =
            @"YTLiquidGlass.SearchBox";

        [searchBox insertSubview:glass
                        atIndex:0];

        objc_setAssociatedObject(
            searchBox,
            kYTLGSearchGlassKey,
            glass,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }

    return glass;
}

static void YTLGUpdateSearchGlass(id container) {
    UIView *searchBox = (UIView *)container;

    if (!searchBox ||
        !searchBox.window ||
        CGRectIsEmpty(searchBox.bounds)) {
        return;
    }

    UIVisualEffectView *glass =
        YTLGSearchGlassView(searchBox);

    if (!CGRectEqualToRect(
            glass.frame,
            searchBox.bounds)) {

        glass.frame = searchBox.bounds;
    }

    glass.layer.cornerRadius =
        searchBox.bounds.size.height * 0.5;

    // Remove YouTube's flat grey pill so the actual system glass can show.
    searchBox.opaque = NO;
    searchBox.backgroundColor =
        UIColor.clearColor;

    // Keep the material behind YouTube's label / cancel / icon content.
    [searchBox sendSubviewToBack:glass];
}

static void YTLGRefreshSearchGlassSoon(id container) {
    if (!container) return;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            UIView *view = (UIView *)container;

            if (view.window) {
                YTLGUpdateSearchGlass(container);
            }
        }
    );
}

%group YTLiquidGlassSearchBox

%hook YTSearchBoxView

- (void)layoutSubviews {
    %orig;

    YTLGUpdateSearchGlass(self);
}

- (void)didMoveToWindow {
    %orig;

    if (((UIView *)self).window) {
        YTLGRefreshSearchGlassSoon(self);
    }
}

- (void)didMoveToSuperview {
    %orig;

    if (((UIView *)self).superview) {
        YTLGRefreshSearchGlassSoon(self);
    }
}

%end

%end


#pragma mark - Active search field Liquid Glass

// YTSearchBarView is YouTube's editable top search field. It is a UITextField
// subclass, so unlike YTSearchBoxView we must NOT insert the effect inside it.
// The text field manages its own internal subviews on every keystroke. Instead,
// host a sibling glass view immediately behind the field in its superview.

static const void *kYTLGActiveSearchGlassKey =
    &kYTLGActiveSearchGlassKey;

static UIVisualEffect *YTLGActiveSearchEffect(void) {
    if (@available(iOS 26.0, *)) {
        Class glassClass =
            NSClassFromString(@"UIGlassEffect");

        if (glassClass &&
            [glassClass
                respondsToSelector:
                    @selector(effectWithStyle:)]) {

            UIGlassEffect *effect =
                [UIGlassEffect
                    effectWithStyle:
                        UIGlassEffectStyleRegular];

            effect.interactive = NO;
            return effect;
        }
    }

    return [UIBlurEffect
        effectWithStyle:
            UIBlurEffectStyleSystemChromeMaterial];
}

static UIVisualEffectView *
YTLGActiveSearchGlassView(UIView *field) {
    UIVisualEffectView *glass =
        objc_getAssociatedObject(
            field,
            kYTLGActiveSearchGlassKey
        );

    if (!glass) {
        glass =
            [[UIVisualEffectView alloc]
                initWithEffect:
                    YTLGActiveSearchEffect()];

        glass.userInteractionEnabled = NO;
        glass.opaque = NO;
        glass.backgroundColor =
            UIColor.clearColor;
        glass.clipsToBounds = YES;
        glass.layer.cornerCurve =
            kCACornerCurveContinuous;

        glass.accessibilityIdentifier =
            @"YTLiquidGlass.ActiveSearchField";

        objc_setAssociatedObject(
            field,
            kYTLGActiveSearchGlassKey,
            glass,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }

    return glass;
}

static void
YTLGRemoveActiveSearchGlass(UIView *field) {
    UIVisualEffectView *glass =
        objc_getAssociatedObject(
            field,
            kYTLGActiveSearchGlassKey
        );

    [glass removeFromSuperview];
}

static void
YTLGUpdateActiveSearchGlass(id object) {
    UIView *field = (UIView *)object;

    if (!field ||
        !field.window ||
        !field.superview ||
        CGRectIsEmpty(field.bounds)) {
        return;
    }

    UIView *host = field.superview;

    UIVisualEffectView *glass =
        YTLGActiveSearchGlassView(field);

    if (glass.superview != host) {
        [glass removeFromSuperview];

        NSUInteger index =
            [host.subviews
                indexOfObjectIdenticalTo:field];

        if (index == NSNotFound) {
            [host addSubview:glass];
            [host bringSubviewToFront:field];
        } else {
            [host insertSubview:glass
                        atIndex:index];
        }
    }

    CGRect frame =
        [field convertRect:field.bounds
                    toView:host];

    // Keep the glass exactly aligned with YouTube's editable field.
    glass.frame = frame;
    glass.layer.cornerRadius =
        frame.size.height * 0.5;

    // Remove Google's flat fill. The text/caret/clear button continue to be
    // drawn by the original field above the system glass.
    field.opaque = NO;
    field.backgroundColor =
        UIColor.clearColor;

    // UITextField subclasses sometimes use a CALayer fill in addition to
    // backgroundColor.
    field.layer.backgroundColor =
        UIColor.clearColor.CGColor;

    [host insertSubview:glass
           belowSubview:field];
}

static void
YTLGRefreshActiveSearchSoon(id object) {
    if (!object) return;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            UIView *field =
                (UIView *)object;

            if (field.window) {
                YTLGUpdateActiveSearchGlass(
                    object
                );
            }
        }
    );
}

%group YTLiquidGlassActiveSearch

%hook YTSearchBarView

- (void)layoutSubviews {
    %orig;

    YTLGUpdateActiveSearchGlass(self);
}

- (void)didMoveToSuperview {
    %orig;

    UIView *field = (UIView *)self;

    if (field.superview) {
        YTLGRefreshActiveSearchSoon(self);
    } else {
        YTLGRemoveActiveSearchGlass(field);
    }
}

- (void)didMoveToWindow {
    %orig;

    UIView *field = (UIView *)self;

    if (field.window) {
        YTLGRefreshActiveSearchSoon(self);
    } else {
        YTLGRemoveActiveSearchGlass(field);
    }
}

- (void)setBackgroundColor:(UIColor *)color {
    // On Liquid Glass builds the sibling material owns the background.
    // Keep YouTube's own text/caret/content, but do not let it repaint the
    // legacy flat grey capsule over the glass.
    if (@available(iOS 26.0, *)) {
        %orig(UIColor.clearColor);
        YTLGRefreshActiveSearchSoon(self);
        return;
    }

    %orig(color);
}

%end

%end


#pragma mark - Compact search-entry back button glass

static const void *kYTLGSearchBackGlassKey =
    &kYTLGSearchBackGlassKey;

static UIVisualEffect *YTLGCompactControlGlassEffect(void) {
    if (@available(iOS 26.0, *)) {
        Class glassClass =
            NSClassFromString(@"UIGlassEffect");

        if (glassClass &&
            [glassClass respondsToSelector:
                @selector(effectWithStyle:)]) {

            UIGlassEffect *effect =
                [UIGlassEffect
                    effectWithStyle:
                        UIGlassEffectStyleRegular];

            effect.interactive = NO;
            return effect;
        }
    }

    return [UIBlurEffect
        effectWithStyle:
            UIBlurEffectStyleSystemChromeMaterial];
}

static id YTLGReadObjectIvar(
    id object,
    const char *name
) {
    if (!object || !name) return nil;

    Class cls = object_getClass(object);

    while (cls) {
        Ivar ivar =
            class_getInstanceVariable(cls, name);

        if (ivar) {
            return object_getIvar(object, ivar);
        }

        cls = class_getSuperclass(cls);
    }

    return nil;
}

static UIButton *
YTLGSearchControllerBackButton(
    YTSearchViewController *controller
) {
    id value =
        YTLGReadObjectIvar(
            controller,
            "_backButton"
        );

    return [value isKindOfClass:UIButton.class]
        ? (UIButton *)value
        : nil;
}

static UIVisualEffectView *
YTLGCompactBackGlassView(UIButton *button) {
    UIVisualEffectView *glass =
        objc_getAssociatedObject(
            button,
            kYTLGSearchBackGlassKey
        );

    if (!glass) {
        glass =
            [[UIVisualEffectView alloc]
                initWithEffect:
                    YTLGCompactControlGlassEffect()];

        glass.userInteractionEnabled = NO;
        glass.opaque = NO;
        glass.backgroundColor =
            UIColor.clearColor;
        glass.clipsToBounds = YES;
        glass.layer.cornerCurve =
            kCACornerCurveContinuous;

        glass.accessibilityIdentifier =
            @"YTLiquidGlass.SearchBack";

        objc_setAssociatedObject(
            button,
            kYTLGSearchBackGlassKey,
            glass,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }

    return glass;
}

static void YTLGUpdateCompactSearchBack(
    YTSearchViewController *controller
) {
    UIButton *button =
        YTLGSearchControllerBackButton(
            controller
        );

    if (!button ||
        !button.window ||
        !button.superview ||
        button.hidden ||
        button.alpha <= 0.01) {
        return;
    }

    UIView *host = button.superview;

    UIVisualEffectView *glass =
        YTLGCompactBackGlassView(button);

    if (glass.superview != host) {
        [glass removeFromSuperview];
        [host insertSubview:glass
               belowSubview:button];
    }

    CGRect buttonFrame =
        [button convertRect:button.bounds
                     toView:host];

    // Compact native-sized circle: intentionally smaller than v1.0's 44–48pt
    // platter so it visually balances the search field and mic control.
    CGFloat side = 36.0;

    CGRect frame =
        CGRectMake(
            CGRectGetMidX(buttonFrame) -
                side * 0.5,
            CGRectGetMidY(buttonFrame) -
                side * 0.5,
            side,
            side
        );

    glass.frame = frame;
    glass.layer.cornerRadius =
        side * 0.5;

    button.opaque = NO;
    button.backgroundColor =
        UIColor.clearColor;

    [host insertSubview:glass
           belowSubview:button];
}

static void YTLGRefreshCompactSearchBackSoon(
    YTSearchViewController *controller
) {
    if (!controller) return;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (controller.view.window) {
                YTLGUpdateCompactSearchBack(
                    controller
                );
            }
        }
    );
}

%group YTLiquidGlassSearchBack

%hook YTSearchViewController

- (void)viewWillLayoutSubviews {
    %orig;

    YTLGUpdateCompactSearchBack(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);

    YTLGRefreshCompactSearchBackSoon(self);
}

%end

%end


#pragma mark - Normal header left/back Liquid Glass

static const void *kYTLGHeaderLeftGlassKey =
    &kYTLGHeaderLeftGlassKey;

static BOOL YTLGButtonHasDrawnContent(
    UIButton *button
) {
    if (!button ||
        button.hidden ||
        button.alpha <= 0.01) {
        return NO;
    }

    if (button.currentImage ||
        button.currentTitle.length > 0 ||
        button.currentBackgroundImage) {
        return YES;
    }

    for (UIView *subview in button.subviews) {
        if (subview.hidden ||
            subview.alpha <= 0.01 ||
            CGRectIsEmpty(subview.bounds)) {
            continue;
        }

        if ([subview isKindOfClass:UIImageView.class]) {
            if (((UIImageView *)subview).image) {
                return YES;
            }
            continue;
        }

        if ([subview isKindOfClass:UILabel.class]) {
            if (((UILabel *)subview).text.length > 0) {
                return YES;
            }
            continue;
        }

        return YES;
    }

    return NO;
}

static void YTLGCollectHeaderButtons(
    UIView *view,
    NSMutableArray<UIButton *> *buttons
) {
    for (UIView *subview in view.subviews) {
        if (subview.hidden ||
            subview.alpha <= 0.01 ||
            CGRectIsEmpty(subview.bounds)) {
            continue;
        }

        CGSize size = subview.bounds.size;

        BOOL iconSized =
            size.width > 0.0 &&
            size.height > 0.0 &&
            size.width <= 64.0 &&
            size.height <= 64.0;

        if ([subview isKindOfClass:UIButton.class] &&
            iconSized &&
            YTLGButtonHasDrawnContent(
                (UIButton *)subview)) {

            [buttons addObject:
                (UIButton *)subview];

            continue;
        }

        YTLGCollectHeaderButtons(
            subview,
            buttons
        );
    }
}

static UIVisualEffectView *
YTLGHeaderLeftGlassView(
    YTHeaderView *header
) {
    UIVisualEffectView *glass =
        objc_getAssociatedObject(
            header,
            kYTLGHeaderLeftGlassKey
        );

    if (!glass) {
        glass =
            [[UIVisualEffectView alloc]
                initWithEffect:
                    YTLGCompactControlGlassEffect()];

        glass.userInteractionEnabled = NO;
        glass.opaque = NO;
        glass.backgroundColor =
            UIColor.clearColor;
        glass.clipsToBounds = YES;
        glass.layer.cornerCurve =
            kCACornerCurveContinuous;

        glass.accessibilityIdentifier =
            @"YTLiquidGlass.HeaderLeft";

        objc_setAssociatedObject(
            header,
            kYTLGHeaderLeftGlassKey,
            glass,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );

        [header insertSubview:glass
                     atIndex:0];
    }

    return glass;
}

static void YTLGUpdateHeaderLeftGlass(
    YTHeaderView *header
) {
    if (!header ||
        !header.window ||
        CGRectIsEmpty(header.bounds)) {
        return;
    }

    NSMutableArray<UIButton *> *buttons =
        [NSMutableArray array];

    YTLGCollectHeaderButtons(
        header,
        buttons
    );

    CGFloat midX =
        header.bounds.size.width * 0.5;

    UIButton *bestButton = nil;
    CGRect bestFrame = CGRectNull;
    CGFloat bestMinX = CGFLOAT_MAX;

    for (UIButton *button in buttons) {
        CGRect frame =
            [header convertRect:button.bounds
                       fromView:button];

        // Only consider real left-edge navigation actions. Anything near the
        // center is a title/control; anything on the right is handled by the
        // existing YTRightNavigationButtons glass.
        if (CGRectGetMidX(frame) >= midX ||
            CGRectGetMinX(frame) >
                header.bounds.size.width * 0.28) {
            continue;
        }

        // Avoid giant/invisible touch targets.
        if (frame.size.width <= 0.0 ||
            frame.size.height <= 0.0 ||
            frame.size.width > 64.0 ||
            frame.size.height > 64.0) {
            continue;
        }

        if (CGRectGetMinX(frame) < bestMinX) {
            bestMinX = CGRectGetMinX(frame);
            bestButton = button;
            bestFrame = frame;
        }
    }

    UIVisualEffectView *glass =
        objc_getAssociatedObject(
            header,
            kYTLGHeaderLeftGlassKey
        );

    if (!bestButton ||
        CGRectIsNull(bestFrame)) {
        glass.hidden = YES;
        return;
    }

    // A compact 36pt circle matches the dedicated search-entry back button.
    CGFloat side = 36.0;

    CGRect frame =
        CGRectMake(
            CGRectGetMidX(bestFrame) -
                side * 0.5,
            CGRectGetMidY(bestFrame) -
                side * 0.5,
            side,
            side
        );

    CGRect safe =
        UIEdgeInsetsInsetRect(
            header.bounds,
            header.safeAreaInsets
        );

    if (!CGRectIsEmpty(safe)) {
        // If the proposed circle would float into the status bar, clamp it
        // back into the safe header region.
        if (CGRectGetMinY(frame) <
            CGRectGetMinY(safe)) {

            frame.origin.y =
                CGRectGetMinY(safe);
        }
    }

    glass =
        YTLGHeaderLeftGlassView(header);

    glass.hidden = NO;
    glass.frame = frame;
    glass.layer.cornerRadius =
        side * 0.5;

    // Keep the original button/action above the material.
    [header insertSubview:glass
             belowSubview:bestButton];
}

%group YTLiquidGlassHeaderLeft

%hook YTHeaderView

- (void)layoutSubviews {
    %orig;

    YTLGUpdateHeaderLeftGlass(self);
}

- (void)didMoveToWindow {
    %orig;

    if (self.window) {
        dispatch_async(
            dispatch_get_main_queue(),
            ^{
                YTLGUpdateHeaderLeftGlass(self);
            }
        );
    }
}

%end

%end


#pragma mark - Native Liquid Glass action menus

// v1.2 only put glass *behind* YouTube's GOODialogView. That still left
// YouTube's legacy row/layout machinery in charge, so it could never look like
// the native Apollo menu. v1.3 instead translates ordinary YouTube sheet
// actions to UIKit UIAction/UIMenu and lets UIContextMenuInteraction present
// the entire menu.
//
// Private _presentMenuAtLocation: / _UIContextMenuStyle are used deliberately:
// Apollo Reborn uses the same UIKit path to request the compact actions-only
// presentation. This is a sideloaded tweak, not App Store code.

static const void *kYTLGNativeMenuPresenterKey =
    &kYTLGNativeMenuPresenterKey;

static BOOL YTLGNameLooksLikeMediaUI(
    NSString *name
) {
    if (name.length == 0) return NO;

    NSString *lower = name.lowercaseString;

    NSArray<NSString *> *blocked = @[
        @"player",
        @"playback",
        @"reel",
        @"short",
        @"watchcontroller",
        @"fullscreen",
        @"videooverlay"
    ];

    for (NSString *needle in blocked) {
        if ([lower containsString:needle]) {
            return YES;
        }
    }

    return NO;
}

static BOOL YTLGSourceBelongsToMediaUI(
    UIView *source
) {
    if (!source) return NO;

    // View ancestry catches player-overlay buttons without excluding ordinary
    // feed cells that simply happen to contain a video thumbnail.
    UIView *view = source;
    for (NSUInteger depth = 0;
         view && depth < 24;
         depth++, view = view.superview) {

        if (YTLGNameLooksLikeMediaUI(
                NSStringFromClass(view.class))) {
            return YES;
        }
    }

    // Responder ancestry catches player/watch/Shorts controllers.
    UIResponder *responder = source;
    for (NSUInteger depth = 0;
         responder && depth < 32;
         depth++, responder = responder.nextResponder) {

        if (YTLGNameLooksLikeMediaUI(
                NSStringFromClass(responder.class))) {
            return YES;
        }
    }

    return NO;
}

static id YTLGSafeValue(
    id object,
    NSString *key
) {
    if (!object || key.length == 0) {
        return nil;
    }

    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id YTLGControllerIvarObject(
    id object,
    const char *name
) {
    if (!object || !name) return nil;

    Class cls = object_getClass(object);

    while (cls) {
        Ivar ivar =
            class_getInstanceVariable(cls, name);

        if (ivar) {
            return object_getIvar(object, ivar);
        }

        cls = class_getSuperclass(cls);
    }

    return nil;
}

static NSArray *
YTLGActionsForSheetController(id controller) {
    if (!controller) return @[];

    if ([controller respondsToSelector:@selector(actions)]) {
        id actions =
            ((id (*)(id, SEL))objc_msgSend)(
                controller,
                @selector(actions)
            );

        if ([actions isKindOfClass:NSArray.class]) {
            return actions;
        }
    }

    id ivarActions =
        YTLGControllerIvarObject(
            controller,
            "_actions"
        );

    return [ivarActions isKindOfClass:NSArray.class]
        ? ivarActions
        : @[];
}

static UIView *
YTLGSourceViewForSheetController(
    id controller,
    UIView *explicitSource
) {
    if (explicitSource &&
        explicitSource.window) {
        return explicitSource;
    }

    if ([controller
            respondsToSelector:
                @selector(sourceView)]) {

        id value =
            ((id (*)(id, SEL))objc_msgSend)(
                controller,
                @selector(sourceView)
            );

        if ([value isKindOfClass:UIView.class] &&
            ((UIView *)value).window) {
            return (UIView *)value;
        }
    }

    id ivarSource =
        YTLGControllerIvarObject(
            controller,
            "_sourceView"
        );

    if ([ivarSource isKindOfClass:UIView.class] &&
        ((UIView *)ivarSource).window) {
        return (UIView *)ivarSource;
    }

    return nil;
}

static NSString *
YTLGTitleForYouTubeAction(id action) {
    NSString *title = nil;

    if ([action respondsToSelector:@selector(title)]) {
        id value =
            ((id (*)(id, SEL))objc_msgSend)(
                action,
                @selector(title)
            );

        if ([value isKindOfClass:NSString.class]) {
            title = value;
        }
    }

    if (title.length == 0) {
        title = YTLGSafeValue(action, @"title");
    }

    UIButton *button = nil;

    if ([action respondsToSelector:@selector(button)]) {
        id value =
            ((id (*)(id, SEL))objc_msgSend)(
                action,
                @selector(button)
            );

        if ([value isKindOfClass:UIButton.class]) {
            button = value;
        }
    }

    if (title.length == 0) {
        NSString *buttonTitle =
            [button titleForState:UIControlStateNormal]
            ?: button.currentTitle
            ?: button.titleLabel.text;

        if (buttonTitle.length > 0) {
            title = buttonTitle;
        }
    }

    return title;
}

static NSString *
YTLGSubtitleForYouTubeAction(id action) {
    id subtitle =
        YTLGSafeValue(
            action,
            @"subtitle"
        );

    return [subtitle isKindOfClass:NSString.class]
        ? subtitle
        : nil;
}

static UIImage *
YTLGImageForYouTubeAction(id action) {
    UIImage *image = nil;

    if ([action
            respondsToSelector:
                @selector(iconImage)]) {

        id value =
            ((id (*)(id, SEL))objc_msgSend)(
                action,
                @selector(iconImage)
            );

        if ([value isKindOfClass:UIImage.class]) {
            image = value;
        }
    }

    if (!image) {
        id value =
            YTLGSafeValue(
                action,
                @"iconImage"
            );

        if ([value isKindOfClass:UIImage.class]) {
            image = value;
        }
    }

    UIButton *button = nil;

    if ([action respondsToSelector:@selector(button)]) {
        id value =
            ((id (*)(id, SEL))objc_msgSend)(
                action,
                @selector(button)
            );

        if ([value isKindOfClass:UIButton.class]) {
            button = value;
        }
    }

    if (!image) {
        image =
            [button imageForState:UIControlStateNormal]
            ?: button.currentImage
            ?: button.imageView.image;
    }

    if (image &&
        image.renderingMode !=
            UIImageRenderingModeAlwaysOriginal) {

        image =
            [image imageWithRenderingMode:
                UIImageRenderingModeAlwaysTemplate];
    }

    return image;
}

static BOOL YTLGActionEnabled(id action) {
    UIButton *button = nil;

    if ([action respondsToSelector:@selector(button)]) {
        id value =
            ((id (*)(id, SEL))objc_msgSend)(
                action,
                @selector(button)
            );

        if ([value isKindOfClass:UIButton.class]) {
            button = value;
        }
    }

    return button ? button.enabled : YES;
}

static void YTLGInvokeYouTubeAction(
    id action
) {
    if (!action) return;

    id handler = nil;

    if ([action respondsToSelector:@selector(handler)]) {
        handler =
            ((id (*)(id, SEL))objc_msgSend)(
                action,
                @selector(handler)
            );
    }

    if (!handler) {
        handler =
            YTLGSafeValue(
                action,
                @"handler"
            );
    }

    if (!handler) return;

    // YouTube has used both no-argument handlers and handlers receiving the
    // YTActionSheetAction. On arm64 the extra object argument is harmless for
    // the no-argument form and preserves compatibility with the latter.
    void (^block)(id) = handler;
    block(action);
}

@interface YTLGNativeMenuPresenter :
    NSObject <UIContextMenuInteractionDelegate>

@property(nonatomic, strong) id youtubeSheetController;
@property(nonatomic, weak) UIView *sourceView;
@property(nonatomic, strong) UIContextMenuInteraction *interaction;
@property(nonatomic, strong) UIMenu *menu;
@property(nonatomic, copy) dispatch_block_t pendingAction;
@property(nonatomic, assign) BOOL ending;

- (BOOL)presentFromSource:(UIView *)source
               completion:(dispatch_block_t)completion;
- (void)finishPresentation;

@end

@implementation YTLGNativeMenuPresenter

- (UIMenu *)buildMenu {
    NSArray *youtubeActions =
        YTLGActionsForSheetController(
            self.youtubeSheetController
        );

    if (youtubeActions.count == 0) {
        return nil;
    }

    NSMutableArray<UIMenuElement *> *elements =
        [NSMutableArray array];

    __weak typeof(self) weakSelf = self;

    for (id youtubeAction in youtubeActions) {
        NSString *title =
            YTLGTitleForYouTubeAction(
                youtubeAction
            );

        // Custom content rows / spacers cannot be represented faithfully as
        // UIAction. If a sheet has one of those, fall back to YouTube's own
        // presentation instead of silently dropping functionality.
        if (title.length == 0) {
            return nil;
        }

        UIImage *image =
            YTLGImageForYouTubeAction(
                youtubeAction
            );

        UIAction *nativeAction =
            [UIAction actionWithTitle:title
                                image:image
                           identifier:nil
                              handler:
                ^(__unused UIAction *selected) {

            YTLGNativeMenuPresenter *strongSelf =
                weakSelf;

            if (!strongSelf) {
                YTLGInvokeYouTubeAction(
                    youtubeAction
                );
                return;
            }

            strongSelf.pendingAction = ^{
                YTLGInvokeYouTubeAction(
                    youtubeAction
                );
            };

            // Let UIKit complete the Liquid Glass dismissal before YouTube's
            // handler presents its next screen/sheet.
            [strongSelf.interaction dismissMenu];
        }];

        NSString *subtitle =
            YTLGSubtitleForYouTubeAction(
                youtubeAction
            );

        if (subtitle.length > 0 &&
            [nativeAction
                respondsToSelector:
                    @selector(setSubtitle:)]) {
            nativeAction.subtitle = subtitle;
        }

        if (!YTLGActionEnabled(
                youtubeAction)) {
            nativeAction.attributes |=
                UIMenuElementAttributesDisabled;
        }

        [elements addObject:nativeAction];
    }

    if (elements.count == 0) {
        return nil;
    }

    return [UIMenu
        menuWithTitle:@""
        image:nil
        identifier:nil
        options:0
        children:elements];
}

- (UIContextMenuConfiguration *)
contextMenuInteraction:
    (__unused UIContextMenuInteraction *)interaction
configurationForMenuAtLocation:
    (__unused CGPoint)location {

    self.menu = [self buildMenu];

    if (!self.menu) {
        return nil;
    }

    UIMenu *menu = self.menu;

    return [UIContextMenuConfiguration
        configurationWithIdentifier:nil
                    previewProvider:nil
                     actionProvider:
        ^UIMenu *(__unused NSArray<UIMenuElement *> *suggested) {
            return menu;
        }];
}

// Match the compact actions-only UIKit style used by Apollo's native action
// menus. On iOS 26/27 this is the path that produces the real Liquid Glass
// menu rather than a preview platter + legacy menu.
- (id)_contextMenuInteraction:
    (__unused UIContextMenuInteraction *)interaction
styleForMenuWithConfiguration:
    (__unused UIContextMenuConfiguration *)configuration {

    Class styleClass =
        objc_getClass("_UIContextMenuStyle");

    SEL defaultStyle =
        NSSelectorFromString(@"defaultStyle");

    if (!styleClass ||
        ![styleClass respondsToSelector:defaultStyle]) {
        return nil;
    }

    id style =
        ((id (*)(id, SEL))objc_msgSend)(
            styleClass,
            defaultStyle
        );

    SEL setLayout =
        NSSelectorFromString(
            @"setPreferredLayout:"
        );

    if ([style respondsToSelector:setLayout]) {
        // 3 = compact/actions-only layout used by UIKit's own button menus.
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(
            style,
            setLayout,
            3
        );
    }

    SEL setOverlap =
        NSSelectorFromString(
            @"setShouldMenuOverlapSourcePreview:"
        );

    if ([style respondsToSelector:setOverlap]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            style,
            setOverlap,
            YES
        );
    }

    return style;
}


- (UITargetedPreview *)ytlg_previewForSource {
    UIView *source = self.sourceView;

    if (!source ||
        !source.window ||
        CGRectIsEmpty(source.bounds)) {
        return nil;
    }

    UIPreviewParameters *parameters =
        [UIPreviewParameters new];

    parameters.backgroundColor =
        UIColor.clearColor;

    CGFloat radius =
        MIN(source.bounds.size.width,
            source.bounds.size.height) * 0.5;

    parameters.visiblePath =
        [UIBezierPath
            bezierPathWithRoundedRect:source.bounds
                         cornerRadius:radius];

    parameters.shadowPath =
        [UIBezierPath bezierPath];

    return [[UITargetedPreview alloc]
        initWithView:source
          parameters:parameters];
}

- (UITargetedPreview *)
contextMenuInteraction:
    (__unused UIContextMenuInteraction *)interaction
previewForHighlightingMenuWithConfiguration:
    (__unused UIContextMenuConfiguration *)configuration {

    return [self ytlg_previewForSource];
}

- (UITargetedPreview *)
contextMenuInteraction:
    (__unused UIContextMenuInteraction *)interaction
previewForDismissingMenuWithConfiguration:
    (__unused UIContextMenuConfiguration *)configuration {

    return [self ytlg_previewForSource];
}

- (void)contextMenuInteraction:
    (__unused UIContextMenuInteraction *)interaction
willEndForConfiguration:
    (__unused UIContextMenuConfiguration *)configuration
animator:
    (id<UIContextMenuInteractionAnimating>)animator {

    if (self.ending) return;
    self.ending = YES;

    __weak typeof(self) weakSelf = self;

    if (animator) {
        [animator addCompletion:^{
            [weakSelf finishPresentation];
        }];
    } else {
        [self finishPresentation];
    }
}

- (void)finishPresentation {
    UIView *source = self.sourceView;

    if (self.interaction && source) {
        [source removeInteraction:
            self.interaction];
    }

    if (source &&
        objc_getAssociatedObject(
            source,
            kYTLGNativeMenuPresenterKey
        ) == self) {

        objc_setAssociatedObject(
            source,
            kYTLGNativeMenuPresenterKey,
            nil,
            OBJC_ASSOCIATION_ASSIGN
        );
    }

    dispatch_block_t pending =
        self.pendingAction;

    self.pendingAction = nil;
    self.interaction = nil;
    self.menu = nil;
    self.youtubeSheetController = nil;

    if (pending) {
        dispatch_async(
            dispatch_get_main_queue(),
            pending
        );
    }
}

- (BOOL)presentFromSource:(UIView *)source
               completion:(dispatch_block_t)completion {

    if (!source ||
        !source.window ||
        YTLGSourceBelongsToMediaUI(source)) {
        return NO;
    }

    self.sourceView = source;

    // Build once before touching the view. Unsupported/custom sheets cleanly
    // fall back to YouTube's original sheet.
    self.menu = [self buildMenu];
    if (!self.menu) {
        return NO;
    }

    UIContextMenuInteraction *interaction =
        [[UIContextMenuInteraction alloc]
            initWithDelegate:self];

    SEL present =
        NSSelectorFromString(
            @"_presentMenuAtLocation:"
        );

    if (![interaction respondsToSelector:present]) {
        return NO;
    }

    self.interaction = interaction;

    [source addInteraction:interaction];

    objc_setAssociatedObject(
        source,
        kYTLGNativeMenuPresenterKey,
        self,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    // Apollo also asks UIKit to use the menu-driver style for programmatic
    // presentations. Keep it conditional so a future UIKit simply ignores it.
    SEL driver =
        NSSelectorFromString(
            @"_setFallbackDriverStyle:"
        );

    if ([interaction respondsToSelector:driver]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(
            interaction,
            driver,
            1
        );
    }

    CGPoint point =
        CGPointMake(
            CGRectGetMidX(source.bounds),
            CGRectGetMidY(source.bounds)
        );

    ((void (*)(id, SEL, CGPoint))objc_msgSend)(
        interaction,
        present,
        point
    );

    if (completion) {
        completion();
    }

    return YES;
}

@end

static BOOL YTLGTryPresentNativeSheetMenu(
    id sheetController,
    UIView *source,
    dispatch_block_t completion
) {
    UIView *resolvedSource =
        YTLGSourceViewForSheetController(
            sheetController,
            source
        );

    if (!resolvedSource ||
        YTLGSourceBelongsToMediaUI(
            resolvedSource)) {
        return NO;
    }

    // Retire any menu already attached to this same source.
    YTLGNativeMenuPresenter *previous =
        objc_getAssociatedObject(
            resolvedSource,
            kYTLGNativeMenuPresenterKey
        );

    if (previous) {
        [previous.interaction dismissMenu];
    }

    YTLGNativeMenuPresenter *presenter =
        [YTLGNativeMenuPresenter new];

    presenter.youtubeSheetController =
        sheetController;

    return [presenter
        presentFromSource:resolvedSource
               completion:completion];
}

%group YTLiquidGlassNativeActionMenus

%hook YTActionSheetController

- (void)presentFromView:(UIView *)view {
    if (YTLGTryPresentNativeSheetMenu(
            self,
            view,
            nil)) {
        return;
    }

    %orig(view);
}

- (void)presentFromView:(UIView *)view
             completion:(void (^)(void))completion {

    if (YTLGTryPresentNativeSheetMenu(
            self,
            view,
            completion)) {
        return;
    }

    %orig(view, completion);
}

- (void)presentFromView:(UIView *)view
               animated:(BOOL)animated
             completion:(void (^)(void))completion {

    if (YTLGTryPresentNativeSheetMenu(
            self,
            view,
            completion)) {
        return;
    }

    %orig(view, animated, completion);
}

- (void)presentFromView:(UIView *)view
               animated:(BOOL)animated
             completion:(void (^)(void))completion
             scrimColor:(UIColor *)scrimColor {

    if (YTLGTryPresentNativeSheetMenu(
            self,
            view,
            completion)) {
        return;
    }

    %orig(view, animated, completion, scrimColor);
}

- (void)presentFromViewController:
            (UIViewController *)viewController
                       animated:(BOOL)animated
                     completion:(void (^)(void))completion {

    UIView *source =
        YTLGSourceViewForSheetController(
            self,
            nil
        );

    if (source &&
        YTLGTryPresentNativeSheetMenu(
            self,
            source,
            completion)) {
        return;
    }

    %orig(viewController, animated, completion);
}

%end


%hook YTDefaultSheetController

- (void)presentFromView:(UIView *)view {
    if (YTLGTryPresentNativeSheetMenu(
            self,
            view,
            nil)) {
        return;
    }

    %orig(view);
}

- (void)presentFromView:(UIView *)view
             completion:(void (^)(void))completion {

    if (YTLGTryPresentNativeSheetMenu(
            self,
            view,
            completion)) {
        return;
    }

    %orig(view, completion);
}

- (void)presentFromView:(UIView *)view
               animated:(BOOL)animated
             completion:(void (^)(void))completion {

    if (YTLGTryPresentNativeSheetMenu(
            self,
            view,
            completion)) {
        return;
    }

    %orig(view, animated, completion);
}

- (void)presentFromViewController:
            (UIViewController *)viewController
                       animated:(BOOL)animated
                     completion:(void (^)(void))completion {

    UIView *source =
        YTLGSourceViewForSheetController(
            self,
            nil
        );

    if (source &&
        YTLGTryPresentNativeSheetMenu(
            self,
            source,
            completion)) {
        return;
    }

    %orig(viewController, animated, completion);
}

%end

%end


#pragma mark - Native Liquid Glass channel/profile action buttons

#pragma mark - Watch-page metadata/action Liquid Glass

// v2.1 attempted to apply UIButtonConfiguration to YouTube's metadata controls.
// The screenshot proved that YouTube re-styles those custom controls afterwards,
// so the native configuration never became visible.
//
// v2.2 instead adds actual UIGlassEffect surfaces behind the existing controls.
// The original YouTube controls remain responsible for hit-testing, state,
// actions and layout. The actual player overlay is still completely untouched.

static const void *kYTLGWatchActionGlassKey =
    &kYTLGWatchActionGlassKey;

static const void *kYTLGWatchSubscribeGlassKey =
    &kYTLGWatchSubscribeGlassKey;

static const void *kYTLGWatchSecondaryGlassKey =
    &kYTLGWatchSecondaryGlassKey;

static UIVisualEffect *
YTLGWatchRegularGlassEffect(BOOL prominent) {
    if (@available(iOS 26.0, *)) {
        Class glassClass =
            NSClassFromString(@"UIGlassEffect");

        if (glassClass &&
            [glassClass respondsToSelector:
                @selector(effectWithStyle:)]) {

            UIGlassEffect *effect =
                [UIGlassEffect
                    effectWithStyle:
                        UIGlassEffectStyleRegular];

            effect.interactive = NO;

            if (prominent) {
                // Slight adaptive tint so Subscribe reads as the primary CTA
                // without reverting to YouTube's old opaque white pill.
                effect.tintColor =
                    [UIColor.labelColor
                        colorWithAlphaComponent:0.12];
            }

            return effect;
        }
    }

    return [UIBlurEffect
        effectWithStyle:
            UIBlurEffectStyleSystemChromeMaterial];
}

static UIVisualEffectView *
YTLGWatchGlassForView(
    UIView *owner,
    const void *key,
    BOOL prominent,
    NSString *identifier
) {
    if (!owner) return nil;

    UIVisualEffectView *glass =
        objc_getAssociatedObject(
            owner,
            key
        );

    if (!glass) {
        glass =
            [[UIVisualEffectView alloc]
                initWithEffect:
                    YTLGWatchRegularGlassEffect(
                        prominent
                    )];

        glass.userInteractionEnabled = NO;
        glass.opaque = NO;
        glass.backgroundColor =
            UIColor.clearColor;
        glass.clipsToBounds = YES;
        glass.layer.cornerCurve =
            kCACornerCurveContinuous;

        glass.accessibilityIdentifier =
            identifier;

        [owner insertSubview:glass
                    atIndex:0];

        objc_setAssociatedObject(
            owner,
            key,
            glass,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }

    return glass;
}

static id
YTLGWatchObjectIvar(
    id object,
    const char *name
) {
    if (!object || !name) return nil;

    Class cls = object_getClass(object);

    while (cls) {
        Ivar ivar =
            class_getInstanceVariable(
                cls,
                name
            );

        if (ivar) {
            return object_getIvar(
                object,
                ivar
            );
        }

        cls = class_getSuperclass(cls);
    }

    return nil;
}

static void
YTLGClearLegacyControlBackground(
    UIView *view
) {
    if (!view) return;

    view.opaque = NO;
    view.backgroundColor =
        UIColor.clearColor;
    view.layer.backgroundColor =
        UIColor.clearColor.CGColor;
}

static void
YTLGUpdateWatchActionGlass(
    YTSlimVideoDetailsActionView *actionView
) {
    if (!actionView ||
        !actionView.window ||
        actionView.hidden ||
        actionView.alpha <= 0.01 ||
        CGRectIsEmpty(actionView.bounds)) {
        return;
    }

    UIVisualEffectView *glass =
        YTLGWatchGlassForView(
            actionView,
            kYTLGWatchActionGlassKey,
            NO,
            @"YTLiquidGlass.WatchAction"
        );

    UILabel *label = nil;

    if ([actionView
            respondsToSelector:
                @selector(label)]) {
        label = actionView.label;
    }

    BOOL hasVisibleTitle =
        label &&
        !label.hidden &&
        label.alpha > 0.01 &&
        ((label.text.length > 0) ||
         (label.attributedText.length > 0));

    CGRect bounds = actionView.bounds;

    if (hasVisibleTitle) {
        // Current watch-page text actions (including Subscribe on layouts that
        // use the unified slim action bar) should read as a proper capsule.
        CGFloat horizontalInset = 2.0;
        CGFloat verticalInset = 2.0;

        CGRect frame =
            CGRectInset(
                bounds,
                horizontalInset,
                verticalInset
            );

        if (frame.size.width < 44.0) {
            frame = CGRectMake(
                CGRectGetMidX(bounds) - 22.0,
                frame.origin.y,
                44.0,
                frame.size.height
            );
        }

        glass.frame = frame;
        glass.layer.cornerRadius =
            frame.size.height * 0.5;
    } else {
        // Icon-only Like/Dislike/Share/Thanks/More actions get one compact
        // native-looking glass circle centered on the action view itself.
        CGFloat available =
            MIN(
                bounds.size.width,
                bounds.size.height
            );

        CGFloat side =
            MIN(
                44.0,
                MAX(
                    38.0,
                    available - 2.0
                )
            );

        CGPoint center =
            CGPointMake(
                CGRectGetMidX(bounds),
                CGRectGetMidY(bounds)
            );

        glass.frame =
            CGRectMake(
                center.x - side * 0.5,
                center.y - side * 0.5,
                side,
                side
            );

        glass.layer.cornerRadius =
            side * 0.5;
    }

    if (@available(iOS 26.0, *)) {
        if ([glass.effect
                isKindOfClass:
                    NSClassFromString(@"UIGlassEffect")]) {

            UIGlassEffect *effect =
                (UIGlassEffect *)glass.effect;

            effect.tintColor =
                actionView.isToggled
                    ? [UIColor.labelColor
                        colorWithAlphaComponent:0.14]
                    : nil;
        }
    }

    actionView.opaque = NO;
    actionView.backgroundColor =
        UIColor.clearColor;
    actionView.layer.backgroundColor =
        UIColor.clearColor.CGColor;

    [actionView sendSubviewToBack:glass];
}

static void
YTLGUpdateWatchSubscribeGlass(
    UIView *subscribeSwitch
) {
    if (!subscribeSwitch ||
        !subscribeSwitch.window ||
        subscribeSwitch.hidden ||
        subscribeSwitch.alpha <= 0.01 ||
        CGRectIsEmpty(subscribeSwitch.bounds)) {
        return;
    }

    UIVisualEffectView *glass =
        YTLGWatchGlassForView(
            subscribeSwitch,
            kYTLGWatchSubscribeGlassKey,
            YES,
            @"YTLiquidGlass.WatchSubscribe"
        );

    glass.frame =
        subscribeSwitch.bounds;

    glass.layer.cornerRadius =
        subscribeSwitch.bounds.size.height *
        0.5;

    YTLGClearLegacyControlBackground(
        subscribeSwitch
    );

    // YTSubscribeSwitch uses a dedicated _backgroundImageView for its old
    // opaque subscribe/unsubscribe artwork. Hide only that background image;
    // the status label and interaction stay intact.
    id backgroundImageView =
        YTLGWatchObjectIvar(
            subscribeSwitch,
            "_backgroundImageView"
        );

    if ([backgroundImageView
            isKindOfClass:UIImageView.class]) {
        ((UIImageView *)backgroundImageView).hidden =
            YES;
    }

    // Keep the title readable on dark/light glass.
    id statusLabel =
        YTLGWatchObjectIvar(
            subscribeSwitch,
            "_statusLabel"
        );

    if (statusLabel &&
        [statusLabel
            respondsToSelector:
                @selector(setTextColor:)]) {

        ((void (*)(id, SEL, UIColor *))objc_msgSend)(
            statusLabel,
            @selector(setTextColor:),
            UIColor.labelColor
        );
    }

    [subscribeSwitch sendSubviewToBack:glass];
}

static void
YTLGUpdateWatchSecondaryControlGlass(
    UIView *control,
    NSString *identifier
) {
    if (!control ||
        !control.window ||
        control.hidden ||
        control.alpha <= 0.01 ||
        CGRectIsEmpty(control.bounds)) {
        return;
    }

    UIVisualEffectView *glass =
        YTLGWatchGlassForView(
            control,
            kYTLGWatchSecondaryGlassKey,
            NO,
            identifier
        );

    glass.frame =
        control.bounds;

    glass.layer.cornerRadius =
        control.bounds.size.height * 0.5;

    YTLGClearLegacyControlBackground(
        control
    );

    [control sendSubviewToBack:glass];
}

static void
YTLGUpdateWatchOwnerGlass(
    YTSlimVideoOwnerView *owner
) {
    if (!owner ||
        !owner.window) {
        return;
    }

    UIView *subscribe =
        owner.subscribeSwitch;

    if (subscribe) {
        YTLGUpdateWatchSubscribeGlass(
            subscribe
        );
    }

    UIView *sponsor =
        owner.sponsorButton;

    if (sponsor) {
        YTLGUpdateWatchSecondaryControlGlass(
            sponsor,
            @"YTLiquidGlass.WatchSponsor"
        );
    }

    UIView *bell =
        owner.notificationToggleButton;

    if (bell) {
        YTLGUpdateWatchSecondaryControlGlass(
            bell,
            @"YTLiquidGlass.WatchBell"
        );
    }

    UIView *multiBell =
        owner.notificationMultiToggleButton;

    if (multiBell) {
        YTLGUpdateWatchSecondaryControlGlass(
            multiBell,
            @"YTLiquidGlass.WatchMultiBell"
        );
    }
}

static void
YTLGRefreshWatchOwnerGlassSoon(
    YTSlimVideoOwnerView *owner
) {
    if (!owner) return;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (owner.window) {
                YTLGUpdateWatchOwnerGlass(
                    owner
                );
            }
        }
    );
}

%group YTLiquidGlassWatchMetadataActions

%hook YTSlimVideoDetailsActionView

- (void)layoutSubviews {
    %orig;

    YTLGUpdateWatchActionGlass(self);
}

- (void)didMoveToWindow {
    %orig;

    if (self.window) {
        YTLGUpdateWatchActionGlass(self);
    }
}

%end


%hook YTSlimVideoOwnerView

- (void)layoutSubviews {
    %orig;

    YTLGUpdateWatchOwnerGlass(self);
}

- (void)didMoveToWindow {
    %orig;

    if (self.window) {
        YTLGRefreshWatchOwnerGlassSoon(self);
    }
}

%end

%end




#pragma mark - Current watch-page action-bar fallback

// Current YouTube still exposes YTSlimVideoScrollableActionBarCell. Refreshing
// from this container makes the glass survive renderer/layout rebuilds and lets
// us find renamed Subscribe controls without applying a global button hook.

static BOOL
YTLGTextLooksLikeSubscribeState(
    NSString *text
) {
    if (text.length == 0) {
        return NO;
    }

    NSString *lower =
        text.lowercaseString;

    return
        [lower isEqualToString:@"subscribe"] ||
        [lower isEqualToString:@"subscribed"];
}

static BOOL
YTLGLooksLikeScopedSubscribeControl(
    UIView *view
) {
    if (!view ||
        view.hidden ||
        view.alpha <= 0.01 ||
        CGRectIsEmpty(view.bounds)) {
        return NO;
    }

    NSString *className =
        NSStringFromClass(view.class)
            .lowercaseString;

    if ([className containsString:@"subscribe"] &&
        ![className containsString:@"subscription"]) {
        return YES;
    }

    NSString *identifier =
        view.accessibilityIdentifier
            .lowercaseString;

    if ([identifier containsString:@"subscribe"] &&
        ![identifier containsString:@"subscription"]) {
        return YES;
    }

    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button =
            (UIButton *)view;

        NSString *title =
            [button titleForState:UIControlStateNormal]
            ?: button.currentTitle
            ?: button.titleLabel.text;

        if (YTLGTextLooksLikeSubscribeState(title)) {
            return YES;
        }
    }

    NSString *a11y =
        view.accessibilityLabel;

    if (YTLGTextLooksLikeSubscribeState(a11y)) {
        return YES;
    }

    return NO;
}

static void
YTLGRefreshCurrentWatchActionTree(
    UIView *root
) {
    if (!root) return;

    Class actionClass =
        NSClassFromString(
            @"YTSlimVideoDetailsActionView"
        );

    NSMutableArray<UIView *> *stack =
        [NSMutableArray
            arrayWithObject:root];

    while (stack.count > 0) {
        UIView *candidate =
            stack.lastObject;

        [stack removeLastObject];

        // Never recurse into glass views we created ourselves.
        if ([candidate.accessibilityIdentifier
                hasPrefix:@"YTLiquidGlass."]) {
            continue;
        }

        if (actionClass &&
            [candidate
                isKindOfClass:actionClass]) {

            YTLGUpdateWatchActionGlass(
                (YTSlimVideoDetailsActionView *)
                    candidate
            );

            // The action view owns its visual content; no need to look for a
            // fake child button anymore.
            continue;
        }

        if (candidate != root &&
            YTLGLooksLikeScopedSubscribeControl(
                candidate)) {

            // This scan exists only inside the watch action-bar cell, so it
            // cannot accidentally glass Home/Subscriptions/channel tabs.
            YTLGUpdateWatchSubscribeGlass(
                candidate
            );

            continue;
        }

        for (UIView *subview
                in candidate.subviews) {
            [stack addObject:subview];
        }
    }
}

static void
YTLGRefreshCurrentWatchActionTreeSoon(
    UIView *root
) {
    if (!root) return;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (root.window) {
                YTLGRefreshCurrentWatchActionTree(
                    root
                );
            }
        }
    );
}

%group YTLiquidGlassCurrentWatchActionBar

%hook YTSlimVideoScrollableActionBarCell

- (void)layoutSubviews {
    %orig;

    YTLGRefreshCurrentWatchActionTree(
        self
    );
}

- (void)didMoveToWindow {
    %orig;

    if (self.window) {
        YTLGRefreshCurrentWatchActionTreeSoon(
            self
        );
    }
}

%end

%end


#pragma mark - Reusable normal-app helpers + subscription controls

// v3.2.1: The broad YTLightweightQTMButton hook was removed entirely.
// YouTube reuses that class for navigation/category/filter controls, so only
// dedicated subscription/notification surfaces are styled below.


// This module intentionally targets YouTube's reusable normal-app controls
// instead of hard-coding English labels such as "Create a channel" or
// "View Channel". This lets localized builds and future labels benefit too.
//
// Guardrails:
//   • no player / playback / Shorts / Reels UI
//   • no tab bar / search / header controls that already have dedicated glass
//   • no watch metadata controls that already have dedicated v2.2 handling
//   • no action-sheet/dialog rows (native menu bridge owns those)

static const void *kYTLGGenericPillGlassKey =
    &kYTLGGenericPillGlassKey;

static BOOL
YTLGAncestorClassNameContains(
    UIView *view,
    NSArray<NSString *> *needles
) {
    UIView *cursor = view;

    for (NSUInteger depth = 0;
         cursor && depth < 32;
         depth++, cursor = cursor.superview) {

        NSString *name =
            NSStringFromClass(cursor.class);

        NSString *lower =
            name.lowercaseString;

        for (NSString *needle in needles) {
            if ([lower containsString:
                    needle.lowercaseString]) {
                return YES;
            }
        }
    }

    UIResponder *responder = view;

    for (NSUInteger depth = 0;
         responder && depth < 32;
         depth++, responder = responder.nextResponder) {

        NSString *name =
            NSStringFromClass(responder.class);

        NSString *lower =
            name.lowercaseString;

        for (NSString *needle in needles) {
            if ([lower containsString:
                    needle.lowercaseString]) {
                return YES;
            }
        }
    }

    return NO;
}

static BOOL
YTLGShouldSkipGlobalNormalControl(
    UIView *view
) {
    if (!view) return YES;

    static NSArray<NSString *> *blockedNames;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        blockedNames = @[
            // Actual media/player UI.
            @"player",
            @"playback",
            @"reel",
            @"short",
            @"fullscreen",
            @"videooverlay",
            @"inlineplayer",

            // Dedicated glass modules already own these.
            @"ytrightnavigationbuttons",
            @"ytpivotbar",
            @"ytsearch",
            @"ytheaderview",
            @"ytslimvideodetailsactionview",
            @"ytslimvideoownerview",

            // Menus/dialogs are handled by the native UIMenu bridge.
            @"actionsheet",
            @"goodialog",
            @"alertcontroller"
        ];
    });

    return YTLGAncestorClassNameContains(
        view,
        blockedNames
    );
}

#pragma mark - Global Subscribe / notification glass

static BOOL
YTLGShouldGlassSubscribeControl(
    UIView *control
) {
    if (!control ||
        !control.window ||
        control.hidden ||
        control.alpha <= 0.01 ||
        CGRectIsEmpty(control.bounds)) {
        return NO;
    }

    // Subscribe controls are normal content chrome, but never touch them when
    // they somehow appear inside a player/Shorts presentation.
    static NSArray<NSString *> *mediaNames;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        mediaNames = @[
            @"player",
            @"playback",
            @"reel",
            @"short",
            @"fullscreen",
            @"videooverlay",
            @"inlineplayer"
        ];
    });

    return !YTLGAncestorClassNameContains(
        control,
        mediaNames
    );
}

%group YTLiquidGlassGlobalSubscriptions

%hook YTSubscribeSwitch

- (void)layoutSubviews {
    %orig;

    if (YTLGShouldGlassSubscribeControl(self)) {
        // Reuse v2.2's direct UIGlassEffect implementation.
        YTLGUpdateWatchSubscribeGlass(self);
    }
}

- (void)didMoveToWindow {
    %orig;

    if (YTLGShouldGlassSubscribeControl(self)) {
        dispatch_async(
            dispatch_get_main_queue(),
            ^{
                if (self.window) {
                    YTLGUpdateWatchSubscribeGlass(
                        self
                    );
                }
            }
        );
    }
}

%end


%hook YTNotificationPreferenceToggleButton

- (void)layoutSubviews {
    %orig;

    if (YTLGShouldGlassSubscribeControl(self) &&
        !YTLGShouldSkipGlobalNormalControl(self)) {

        YTLGUpdateWatchSecondaryControlGlass(
            self,
            @"YTLiquidGlass.NotificationBell"
        );
    }
}

- (void)didMoveToWindow {
    %orig;

    if (YTLGShouldGlassSubscribeControl(self) &&
        !YTLGShouldSkipGlobalNormalControl(self)) {

        YTLGUpdateWatchSecondaryControlGlass(
            self,
            @"YTLiquidGlass.NotificationBell"
        );
    }
}

%end


%hook YTNotificationMultiToggleButton

- (void)layoutSubviews {
    %orig;

    if (YTLGShouldGlassSubscribeControl(self) &&
        !YTLGShouldSkipGlobalNormalControl(self)) {

        YTLGUpdateWatchSecondaryControlGlass(
            self,
            @"YTLiquidGlass.MultiNotificationBell"
        );
    }
}

- (void)didMoveToWindow {
    %orig;

    if (YTLGShouldGlassSubscribeControl(self) &&
        !YTLGShouldSkipGlobalNormalControl(self)) {

        YTLGUpdateWatchSecondaryControlGlass(
            self,
            @"YTLiquidGlass.MultiNotificationBell"
        );
    }
}

%end

%end



#pragma mark - TEMPORARY watch-row runtime diagnostic

// This module is diagnostic-only. It does not alter YouTube actions.
// When a likely Subscribe/Like/Dislike/Share/Thanks/More control appears,
// it draws a red outline over the visible runtime view and shows the class
// ancestry in a small overlay panel. This lets us identify the 2026 renderer
// path before attempting another Liquid Glass implementation.

static const NSInteger kYTLGDiagnosticOverlayTag = 0x594C4744;
static const void *kYTLGDiagnosticPendingKey =
    &kYTLGDiagnosticPendingKey;

static BOOL
YTLGDiagnosticHasBlockedAncestor(
    UIView *view
) {
    static NSArray<NSString *> *blocked;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        blocked = @[
            @"player",
            @"playback",
            @"reel",
            @"shorts",
            @"fullscreen",
            @"videooverlay",
            @"inlineplayer"
        ];
    });

    UIView *cursor = view;

    for (NSUInteger depth = 0;
         cursor && depth < 24;
         depth++, cursor = cursor.superview) {

        NSString *name =
            NSStringFromClass(cursor.class)
                .lowercaseString;

        for (NSString *needle in blocked) {
            if ([name containsString:needle]) {
                return YES;
            }
        }
    }

    return NO;
}

static NSString *
YTLGDiagnosticVisibleText(
    UIView *view
) {
    if (!view) {
        return @"";
    }

    NSMutableArray<NSString *> *parts =
        [NSMutableArray array];

    NSString *a11y =
        view.accessibilityLabel;

    if (a11y.length > 0) {
        [parts addObject:a11y];
    }

    NSString *identifier =
        view.accessibilityIdentifier;

    if (identifier.length > 0) {
        [parts addObject:identifier];
    }

    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button =
            (UIButton *)view;

        NSString *title =
            [button titleForState:UIControlStateNormal]
            ?: button.currentTitle
            ?: button.titleLabel.text;

        if (title.length > 0) {
            [parts addObject:title];
        }
    }

    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label =
            (UILabel *)view;

        if (label.text.length > 0) {
            [parts addObject:label.text];
        }
    }

    return [parts
        componentsJoinedByString:@" | "];
}

static NSString *
YTLGDiagnosticSemanticForView(
    UIView *view
) {
    if (!view ||
        view.hidden ||
        view.alpha <= 0.01 ||
        CGRectIsEmpty(view.bounds)) {
        return nil;
    }

    NSString *className =
        NSStringFromClass(view.class);

    NSString *lowerClass =
        className.lowercaseString;

    NSString *text =
        YTLGDiagnosticVisibleText(view);

    NSString *lowerText =
        text.lowercaseString;

    NSArray<NSString *> *terms = @[
        @"subscribe",
        @"subscribed",
        @"dislike",
        @"like",
        @"share",
        @"thanks",
        @"more"
    ];

    BOOL controlLike =
        [view isKindOfClass:UIControl.class] ||
        view.isAccessibilityElement ||
        [lowerClass containsString:@"button"] ||
        [lowerClass containsString:@"action"];

    if (controlLike &&
        view.bounds.size.height <= 100.0 &&
        view.bounds.size.width <= 360.0) {

        for (NSString *term in terms) {
            if ([lowerText containsString:term]) {
                return term.uppercaseString;
            }
        }
    }

    // Also include the YouTube classes that are supposed to own this row,
    // even if they have no accessibility text.
    NSArray<NSString *> *classTerms = @[
        @"slimvideodetailsaction",
        @"slimvideoscrollableactionbar",
        @"slimvideoscrollabledetailsactions",
        @"slimvideodetailsactions",
        @"slimvideoowner",
        @"slimmetadata"
    ];

    for (NSString *term in classTerms) {
        if ([lowerClass containsString:term]) {
            return @"YT-ROW";
        }
    }

    return nil;
}

static NSString *
YTLGDiagnosticClassChain(
    UIView *view
) {
    if (!view) {
        return @"";
    }

    NSMutableArray<NSString *> *names =
        [NSMutableArray array];

    UIView *cursor = view;

    for (NSUInteger depth = 0;
         cursor && depth < 6;
         depth++, cursor = cursor.superview) {

        [names addObject:
            NSStringFromClass(cursor.class)];
    }

    return [names
        componentsJoinedByString:@" ← "];
}

static UIView *
YTLGDiagnosticOverlayForWindow(
    UIWindow *window
) {
    UIView *overlay =
        [window viewWithTag:
            kYTLGDiagnosticOverlayTag];

    if (!overlay) {
        overlay =
            [[UIView alloc]
                initWithFrame:window.bounds];

        overlay.tag =
            kYTLGDiagnosticOverlayTag;

        overlay.userInteractionEnabled =
            NO;

        overlay.backgroundColor =
            UIColor.clearColor;

        overlay.autoresizingMask =
            UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleHeight;

        overlay.accessibilityIdentifier =
            @"YTLiquidGlass.Diagnostics";

        [window addSubview:overlay];
    }

    overlay.frame =
        window.bounds;

    [window bringSubviewToFront:overlay];

    return overlay;
}

static void
YTLGDiagnosticAddOutline(
    UIView *overlay,
    UIView *target,
    NSString *semantic,
    NSUInteger index
) {
    if (!overlay ||
        !target ||
        !target.window) {
        return;
    }

    CGRect frame =
        [target convertRect:target.bounds
                     toView:overlay];

    if (CGRectIsEmpty(frame) ||
        !CGRectIntersectsRect(
            overlay.bounds,
            frame)) {
        return;
    }

    UIView *box =
        [[UIView alloc]
            initWithFrame:frame];

    box.userInteractionEnabled =
        NO;

    box.backgroundColor =
        UIColor.clearColor;

    box.layer.borderWidth =
        1.5;

    box.layer.borderColor =
        UIColor.systemRedColor.CGColor;

    box.layer.cornerRadius =
        MIN(
            10.0,
            frame.size.height * 0.25
        );

    [overlay addSubview:box];

    NSString *className =
        NSStringFromClass(target.class);

    NSString *labelText =
        [NSString stringWithFormat:
            @"%lu %@ · %@",
            (unsigned long)(index + 1),
            semantic,
            className];

    UILabel *label =
        [[UILabel alloc]
            initWithFrame:CGRectZero];

    label.userInteractionEnabled =
        NO;

    label.font =
        [UIFont monospacedSystemFontOfSize:8.0
                                   weight:UIFontWeightSemibold];

    label.textColor =
        UIColor.whiteColor;

    label.backgroundColor =
        [UIColor.blackColor
            colorWithAlphaComponent:0.82];

    label.text =
        labelText;

    label.numberOfLines = 1;

    [label sizeToFit];

    CGFloat width =
        MIN(
            overlay.bounds.size.width - 12.0,
            label.bounds.size.width + 8.0
        );

    CGFloat y =
        MAX(
            2.0,
            CGRectGetMinY(frame) - 15.0
        );

    label.frame =
        CGRectMake(
            MAX(
                4.0,
                MIN(
                    CGRectGetMinX(frame),
                    overlay.bounds.size.width -
                    width - 4.0
                )
            ),
            y,
            width,
            14.0
        );

    label.layer.cornerRadius =
        3.0;

    label.layer.masksToBounds =
        YES;

    [overlay addSubview:label];
}

static void
YTLGDiagnosticScanWindow(
    UIWindow *window
) {
    if (!window ||
        window.hidden ||
        window.alpha <= 0.01 ||
        window.windowLevel != UIWindowLevelNormal) {
        return;
    }

    UIView *overlay =
        YTLGDiagnosticOverlayForWindow(
            window
        );

    for (UIView *subview
            in [overlay.subviews copy]) {
        [subview removeFromSuperview];
    }

    NSMutableArray<UIView *> *stack =
        [NSMutableArray
            arrayWithObject:window];

    NSMutableArray<UIView *> *matches =
        [NSMutableArray array];

    NSMutableArray<NSString *> *semantics =
        [NSMutableArray array];

    while (stack.count > 0 &&
           matches.count < 18) {

        UIView *candidate =
            stack.lastObject;

        [stack removeLastObject];

        if (candidate == overlay ||
            [candidate.accessibilityIdentifier
                hasPrefix:@"YTLiquidGlass.Diagnostics"]) {
            continue;
        }

        if (candidate != window) {
            NSString *semantic =
                YTLGDiagnosticSemanticForView(
                    candidate
                );

            if (semantic &&
                !YTLGDiagnosticHasBlockedAncestor(
                    candidate)) {

                [matches addObject:candidate];
                [semantics addObject:semantic];
            }
        }

        for (UIView *subview
                in candidate.subviews) {
            [stack addObject:subview];
        }
    }

    NSMutableArray<NSString *> *lines =
        [NSMutableArray array];

    NSUInteger count =
        MIN(
            matches.count,
            semantics.count
        );

    for (NSUInteger i = 0;
         i < count;
         i++) {

        UIView *target =
            matches[i];

        NSString *semantic =
            semantics[i];

        YTLGDiagnosticAddOutline(
            overlay,
            target,
            semantic,
            i
        );

        NSString *chain =
            YTLGDiagnosticClassChain(
                target
            );

        [lines addObject:
            [NSString stringWithFormat:
                @"%lu %@: %@",
                (unsigned long)(i + 1),
                semantic,
                chain]];
    }

    UILabel *panel =
        [[UILabel alloc]
            initWithFrame:CGRectZero];

    panel.userInteractionEnabled =
        NO;

    panel.numberOfLines = 0;

    panel.font =
        [UIFont monospacedSystemFontOfSize:7.0
                                   weight:UIFontWeightRegular];

    panel.textColor =
        UIColor.whiteColor;

    panel.backgroundColor =
        [UIColor.blackColor
            colorWithAlphaComponent:0.78];

    NSString *body =
        lines.count > 0
            ? [lines
                componentsJoinedByString:@"\n"]
            : @"No matching watch-row runtime views detected yet.";

    panel.text =
        [NSString stringWithFormat:
            @"YTLiquidGlass WATCH DIAGNOSTIC (%lu)\n%@",
            (unsigned long)lines.count,
            body];

    CGFloat panelWidth =
        MIN(
            overlay.bounds.size.width - 16.0,
            600.0
        );

    CGSize fit =
        [panel sizeThatFits:
            CGSizeMake(
                panelWidth - 12.0,
                220.0
            )];

    CGFloat panelHeight =
        MIN(
            220.0,
            MAX(
                36.0,
                fit.height + 10.0
            )
        );

    panel.frame =
        CGRectMake(
            8.0,
            overlay.bounds.size.height -
            panelHeight - 8.0,
            panelWidth,
            panelHeight
        );

    panel.layer.cornerRadius =
        8.0;

    panel.layer.masksToBounds =
        YES;

    [overlay addSubview:panel];

    [window bringSubviewToFront:overlay];
}

static void
YTLGDiagnosticScheduleWindowScan(
    UIWindow *window
) {
    if (!window) {
        return;
    }

    NSNumber *pending =
        objc_getAssociatedObject(
            window,
            kYTLGDiagnosticPendingKey
        );

    if (pending.boolValue) {
        return;
    }

    objc_setAssociatedObject(
        window,
        kYTLGDiagnosticPendingKey,
        @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(0.35 * NSEC_PER_SEC)
        ),
        dispatch_get_main_queue(),
        ^{
            objc_setAssociatedObject(
                window,
                kYTLGDiagnosticPendingKey,
                @NO,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );

            if (window &&
                !window.hidden) {

                YTLGDiagnosticScanWindow(
                    window
                );
            }
        }
    );
}

%group YTLiquidGlassWatchDiagnostic

%hook UICollectionViewCell

- (void)didMoveToWindow {
    %orig;

    if (self.window) {
        YTLGDiagnosticScheduleWindowScan(
            self.window
        );
    }
}

%end


%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);

    UIWindow *window =
        self.view.window;

    if (window) {
        YTLGDiagnosticScheduleWindowScan(
            window
        );
    }
}

%end

%end


%ctor {
    if (@available(iOS 26.0, *)) {
        %init(YTLiquidGlassWatchDiagnostic);

        if (NSClassFromString(@"YTPivotBarView") &&
            NSClassFromString(@"YTPivotBarItemView") &&
            NSClassFromString(@"YTPivotBarViewController")) {

            %init(YTLiquidGlassStandaloneTabBar);
        }

        if (NSClassFromString(@"UIGlassEffect") &&
            NSClassFromString(@"YTRightNavigationButtons")) {

            %init(YTLiquidGlassTopNavigation);
        }

        if (NSClassFromString(@"UIGlassEffect") &&
            NSClassFromString(@"YTSearchBoxView")) {

            %init(YTLiquidGlassSearchBox);
        }

        if (NSClassFromString(@"UIGlassEffect") &&
            NSClassFromString(@"YTSearchBarView")) {

            %init(YTLiquidGlassActiveSearch);
        }

        if (NSClassFromString(@"UIGlassEffect") &&
            NSClassFromString(@"YTSearchViewController")) {

            %init(YTLiquidGlassSearchBack);
        }

        if (NSClassFromString(@"UIGlassEffect") &&
            NSClassFromString(@"YTHeaderView")) {

            %init(YTLiquidGlassHeaderLeft);
        }

        if (NSClassFromString(@"YTActionSheetController") ||
            NSClassFromString(@"YTDefaultSheetController")) {

            %init(YTLiquidGlassNativeActionMenus);
        }

        if (NSClassFromString(@"UIGlassEffect") &&
            (NSClassFromString(@"YTSlimVideoDetailsActionView") ||
             NSClassFromString(@"YTSlimVideoOwnerView"))) {

            %init(YTLiquidGlassWatchMetadataActions);
        }

        if (NSClassFromString(@"UIGlassEffect") &&
            NSClassFromString(@"YTSlimVideoScrollableActionBarCell")) {

            %init(YTLiquidGlassCurrentWatchActionBar);
        }

        if (NSClassFromString(@"UIGlassEffect") &&
            (NSClassFromString(@"YTSubscribeSwitch") ||
             NSClassFromString(@"YTNotificationPreferenceToggleButton") ||
             NSClassFromString(@"YTNotificationMultiToggleButton"))) {

            %init(YTLiquidGlassGlobalSubscriptions);
        }
    }
}
