#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

// YTLiquidGlass v2.1 — Consolidated non-player Liquid Glass + watch-page actions
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
@property(nonatomic, readonly) UIButton *button;
@end

@interface YTSlimVideoOwnerView : UIView
@property(nonatomic, readonly) UIView *subscribeSwitch;
@property(nonatomic, strong) UIView *sponsorButton;
@property(nonatomic, readonly) UIView *notificationMultiToggleButton;
@property(nonatomic, readonly) UIView *notificationToggleButton;
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

static const void *kYTLGNativeButtonSignatureKey =
    &kYTLGNativeButtonSignatureKey;

static void YTLGCollectTitledButtons(
    UIView *view,
    NSMutableArray<UIButton *> *buttons
) {
    if (!view) return;

    for (UIView *subview in view.subviews) {
        if (subview.hidden ||
            subview.alpha <= 0.01 ||
            CGRectIsEmpty(subview.bounds)) {
            continue;
        }

        if ([subview isKindOfClass:UIButton.class]) {
            UIButton *button = (UIButton *)subview;

            NSString *title =
                [button titleForState:UIControlStateNormal]
                ?: button.currentTitle
                ?: button.titleLabel.text;

            // Only title-bearing action pills. This intentionally ignores
            // avatar/icon-only controls and navigation/player buttons.
            if (title.length > 0 &&
                button.bounds.size.height >= 28.0 &&
                button.bounds.size.height <= 64.0 &&
                button.bounds.size.width >= 56.0) {

                [buttons addObject:button];
            }
        }

        YTLGCollectTitledButtons(
            subview,
            buttons
        );
    }
}

static BOOL YTLGViewIsDescendantOfView(
    UIView *view,
    UIView *ancestor
) {
    if (!view || !ancestor) return NO;

    UIView *cursor = view;

    while (cursor) {
        if (cursor == ancestor) {
            return YES;
        }

        cursor = cursor.superview;
    }

    return NO;
}

static NSString *
YTLGNativeButtonSignature(
    UIButton *button,
    BOOL prominent
) {
    NSString *title =
        [button titleForState:UIControlStateNormal]
        ?: button.currentTitle
        ?: button.titleLabel.text
        ?: @"";

    UIImage *image =
        [button imageForState:UIControlStateNormal]
        ?: button.currentImage;

    return [NSString stringWithFormat:
        @"%@|%lu|%d|%d",
        title,
        (unsigned long)image.hash,
        prominent,
        button.enabled
    ];
}

static void YTLGApplyNativeGlassButton(
    UIButton *button,
    BOOL prominent
) {
    if (!button) return;

    if (@available(iOS 26.0, *)) {
        SEL regularSelector =
            @selector(glassButtonConfiguration);

        SEL prominentSelector =
            @selector(prominentGlassButtonConfiguration);

        if (![UIButtonConfiguration
                respondsToSelector:
                    (prominent
                        ? prominentSelector
                        : regularSelector)]) {
            return;
        }

        NSString *signature =
            YTLGNativeButtonSignature(
                button,
                prominent
            );

        NSString *previous =
            objc_getAssociatedObject(
                button,
                kYTLGNativeButtonSignatureKey
            );

        if ([previous isEqualToString:signature] &&
            button.configuration != nil) {
            return;
        }

        NSString *title =
            [button titleForState:UIControlStateNormal]
            ?: button.currentTitle
            ?: button.titleLabel.text;

        UIImage *image =
            [button imageForState:UIControlStateNormal]
            ?: button.currentImage
            ?: button.imageView.image;

        UIColor *foreground =
            [button titleColorForState:UIControlStateNormal]
            ?: button.tintColor;

        UIButtonConfiguration *configuration = nil;

        if (prominent) {
            configuration =
                [UIButtonConfiguration
                    prominentGlassButtonConfiguration];
        } else {
            configuration =
                [UIButtonConfiguration
                    glassButtonConfiguration];
        }

        configuration.title = title;

        if (image) {
            configuration.image = image;
            configuration.imagePadding = 7.0;
        }

        if (foreground) {
            configuration.baseForegroundColor =
                foreground;
        }

        button.configuration = configuration;
        button.automaticallyUpdatesConfiguration = YES;

        // Remove the legacy filled/outlined backing. UIKit's configuration now
        // owns the native Liquid Glass surface.
        button.opaque = NO;
        button.backgroundColor =
            UIColor.clearColor;
        button.layer.backgroundColor =
            UIColor.clearColor.CGColor;

        objc_setAssociatedObject(
            button,
            kYTLGNativeButtonSignatureKey,
            signature,
            OBJC_ASSOCIATION_COPY_NONATOMIC
        );
    }
}

static void YTLGUpdateChannelHeaderButtons(
    YTC4TabbedHeaderView *header
) {
    if (!header ||
        !header.window ||
        CGRectIsEmpty(header.bounds)) {
        return;
    }

    NSMutableArray<UIButton *> *buttons =
        [NSMutableArray array];

    YTLGCollectTitledButtons(
        header,
        buttons
    );

    UIView *subscribeContainer =
        header.subscribeSwitch;

    UIView *sponsorContainer =
        header.sponsorButton;

    for (UIButton *button in buttons) {
        // The main Subscribe CTA gets prominent system glass. Join and other
        // normal channel/profile actions use standard glass.
        BOOL prominent =
            subscribeContainer &&
            YTLGViewIsDescendantOfView(
                button,
                subscribeContainer
            );

        // Sponsor/Join is intentionally regular, not prominent.
        if (sponsorContainer &&
            YTLGViewIsDescendantOfView(
                button,
                sponsorContainer
            )) {
            prominent = NO;
        }

        YTLGApplyNativeGlassButton(
            button,
            prominent
        );
    }
}

static void YTLGRefreshChannelHeaderSoon(
    YTC4TabbedHeaderView *header
) {
    if (!header) return;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (header.window) {
                YTLGUpdateChannelHeaderButtons(
                    header
                );
            }
        }
    );
}

%group YTLiquidGlassChannelActions

%hook YTC4TabbedHeaderView

- (void)layoutSubviews {
    %orig;

    YTLGUpdateChannelHeaderButtons(self);
}

- (void)didMoveToWindow {
    %orig;

    if (self.window) {
        YTLGRefreshChannelHeaderSoon(self);
    }
}

%end

%end


#pragma mark - Watch-page metadata/action Liquid Glass

// The controls in this module live BELOW the normal video player:
// Subscribe, Like, Dislike, Share, Thanks, More, notification, etc.
// No player-overlay class is hooked here.

static const void *kYTLGWatchActionSignatureKey =
    &kYTLGWatchActionSignatureKey;

static UIButton *
YTLGFirstButtonDescendant(UIView *view) {
    if (!view) return nil;

    if ([view isKindOfClass:UIButton.class]) {
        return (UIButton *)view;
    }

    for (UIView *subview in view.subviews) {
        UIButton *button =
            YTLGFirstButtonDescendant(subview);

        if (button) {
            return button;
        }
    }

    return nil;
}

static NSArray<UIButton *> *
YTLGButtonDescendants(UIView *view) {
    if (!view) return @[];

    NSMutableArray<UIButton *> *buttons =
        [NSMutableArray array];

    NSMutableArray<UIView *> *stack =
        [NSMutableArray arrayWithObject:view];

    while (stack.count > 0) {
        UIView *candidate = stack.lastObject;
        [stack removeLastObject];

        for (UIView *subview in candidate.subviews) {
            if ([subview isKindOfClass:UIButton.class]) {
                [buttons addObject:(UIButton *)subview];
            }

            [stack addObject:subview];
        }
    }

    return buttons;
}

static NSString *
YTLGWatchActionButtonSignature(
    UIButton *button,
    BOOL prominent,
    BOOL iconOnly
) {
    NSString *title =
        [button titleForState:UIControlStateNormal]
        ?: button.currentTitle
        ?: button.titleLabel.text
        ?: @"";

    UIImage *image =
        [button imageForState:UIControlStateNormal]
        ?: button.currentImage
        ?: button.imageView.image;

    return [NSString stringWithFormat:
        @"%@|%lu|%d|%d|%d",
        title,
        (unsigned long)image.hash,
        prominent,
        iconOnly,
        button.enabled
    ];
}

static void
YTLGApplyWatchNativeGlassButton(
    UIButton *button,
    BOOL prominent,
    BOOL preferIconOnly
) {
    if (!button) return;

    if (@available(iOS 26.0, *)) {
        SEL selector =
            prominent
                ? @selector(prominentGlassButtonConfiguration)
                : @selector(glassButtonConfiguration);

        if (![UIButtonConfiguration
                respondsToSelector:selector]) {
            return;
        }

        NSString *signature =
            YTLGWatchActionButtonSignature(
                button,
                prominent,
                preferIconOnly
            );

        NSString *previous =
            objc_getAssociatedObject(
                button,
                kYTLGWatchActionSignatureKey
            );

        if ([previous isEqualToString:signature] &&
            button.configuration != nil) {
            return;
        }

        NSString *title =
            [button titleForState:UIControlStateNormal]
            ?: button.currentTitle
            ?: button.titleLabel.text;

        UIImage *image =
            [button imageForState:UIControlStateNormal]
            ?: button.currentImage
            ?: button.imageView.image;

        UIButtonConfiguration *configuration =
            prominent
                ? [UIButtonConfiguration
                    prominentGlassButtonConfiguration]
                : [UIButtonConfiguration
                    glassButtonConfiguration];

        // Preserve YouTube's own symbol/artwork.
        configuration.image = image;

        if (!preferIconOnly &&
            title.length > 0) {
            configuration.title = title;
            configuration.imagePadding = 7.0;
        } else {
            configuration.title = nil;

            // Compact icon controls should read as native round/capsule glass,
            // not oversized empty pills.
            configuration.contentInsets =
                NSDirectionalEdgeInsetsMake(
                    8.0,
                    8.0,
                    8.0,
                    8.0
                );
        }

        configuration.cornerStyle =
            UIButtonConfigurationCornerStyleCapsule;

        UIColor *foreground =
            [button titleColorForState:UIControlStateNormal]
            ?: button.tintColor;

        if (foreground) {
            configuration.baseForegroundColor =
                foreground;
        }

        button.configuration = configuration;
        button.automaticallyUpdatesConfiguration = YES;

        button.opaque = NO;
        button.backgroundColor =
            UIColor.clearColor;
        button.layer.backgroundColor =
            UIColor.clearColor.CGColor;

        objc_setAssociatedObject(
            button,
            kYTLGWatchActionSignatureKey,
            signature,
            OBJC_ASSOCIATION_COPY_NONATOMIC
        );
    }
}

static void
YTLGUpdateWatchActionView(
    YTSlimVideoDetailsActionView *actionView
) {
    if (!actionView ||
        !actionView.window) {
        return;
    }

    UIButton *button =
        actionView.button;

    if (!button) {
        button =
            YTLGFirstButtonDescendant(
                actionView
            );
    }

    if (!button) return;

    // Like, dislike, share, Super Thanks, More, etc. are icon actions.
    YTLGApplyWatchNativeGlassButton(
        button,
        NO,
        YES
    );

    actionView.opaque = NO;
    actionView.backgroundColor =
        UIColor.clearColor;
}

static void
YTLGUpdateWatchOwnerView(
    YTSlimVideoOwnerView *owner
) {
    if (!owner ||
        !owner.window) {
        return;
    }

    // Subscribe is the primary call-to-action on the watch page.
    for (UIButton *button
            in YTLGButtonDescendants(
                owner.subscribeSwitch)) {

        YTLGApplyWatchNativeGlassButton(
            button,
            YES,
            NO
        );
    }

    // Join/Sponsor is secondary.
    for (UIButton *button
            in YTLGButtonDescendants(
                owner.sponsorButton)) {

        YTLGApplyWatchNativeGlassButton(
            button,
            NO,
            NO
        );
    }

    // Once subscribed, YouTube can expose bell/notification controls.
    for (UIButton *button
            in YTLGButtonDescendants(
                owner.notificationToggleButton)) {

        YTLGApplyWatchNativeGlassButton(
            button,
            NO,
            YES
        );
    }

    for (UIButton *button
            in YTLGButtonDescendants(
                owner.notificationMultiToggleButton)) {

        YTLGApplyWatchNativeGlassButton(
            button,
            NO,
            YES
        );
    }
}

static void
YTLGRefreshWatchOwnerSoon(
    YTSlimVideoOwnerView *owner
) {
    if (!owner) return;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (owner.window) {
                YTLGUpdateWatchOwnerView(owner);
            }
        }
    );
}

%group YTLiquidGlassWatchMetadataActions

%hook YTSlimVideoDetailsActionView

- (void)layoutSubviews {
    %orig;

    YTLGUpdateWatchActionView(self);
}

- (void)didMoveToWindow {
    %orig;

    if (self.window) {
        YTLGUpdateWatchActionView(self);
    }
}

%end


%hook YTSlimVideoOwnerView

- (void)layoutSubviews {
    %orig;

    YTLGUpdateWatchOwnerView(self);
}

- (void)didMoveToWindow {
    %orig;

    if (self.window) {
        YTLGRefreshWatchOwnerSoon(self);
    }
}

%end

%end

%ctor {
    if (@available(iOS 26.0, *)) {
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

        if (NSClassFromString(@"YTC4TabbedHeaderView") &&
            [UIButtonConfiguration
                respondsToSelector:
                    @selector(glassButtonConfiguration)]) {

            %init(YTLiquidGlassChannelActions);
        }

        if ((NSClassFromString(@"YTSlimVideoDetailsActionView") ||
             NSClassFromString(@"YTSlimVideoOwnerView")) &&
            [UIButtonConfiguration
                respondsToSelector:
                    @selector(glassButtonConfiguration)]) {

            %init(YTLiquidGlassWatchMetadataActions);
        }
    }
}
