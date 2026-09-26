#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// YTLiquidGlass v1.0 — Tab bar + header + full search + player glass
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


// Search and player declarations are intentionally minimal. The implementation
// discovers private child views at runtime so YouTube/YTVideoOverlay keep
// ownership of their controls and behavior.
@interface YTSearchViewController : UIViewController
@end

@interface YTMainAppControlsOverlayView : UIView
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


#pragma mark - Search back button Liquid Glass

static const void *kYTLGSearchBackGlassKey =
    &kYTLGSearchBackGlassKey;

static UIVisualEffect *YTLGSmallControlGlassEffect(void) {
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

static id YTLGObjectIvar(
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

static UIView *YTLGFindDescendantOfClass(
    UIView *view,
    Class targetClass
) {
    if (!view || !targetClass) return nil;

    if ([view isKindOfClass:targetClass]) {
        return view;
    }

    for (UIView *subview in view.subviews) {
        UIView *match =
            YTLGFindDescendantOfClass(
                subview,
                targetClass
            );

        if (match) return match;
    }

    return nil;
}

static UIButton *
YTLGSearchBackButton(
    YTSearchViewController *controller
) {
    if (!controller) return nil;

    id ivarButton =
        YTLGObjectIvar(
            controller,
            "_backButton"
        );

    if ([ivarButton isKindOfClass:UIButton.class]) {
        return (UIButton *)ivarButton;
    }

    // Fallback for YouTube versions where the ivar name changes: find the
    // visible icon-sized UIButton immediately to the left of YTSearchBarView.
    UIView *root = controller.view;
    Class searchClass =
        NSClassFromString(@"YTSearchBarView");

    UIView *searchField =
        YTLGFindDescendantOfClass(
            root,
            searchClass
        );

    if (!searchField) return nil;

    CGRect searchFrame =
        [root convertRect:searchField.bounds
                 fromView:searchField];

    NSMutableArray<UIView *> *stack =
        [NSMutableArray arrayWithObject:root];

    UIButton *best = nil;
    CGFloat bestDistance = CGFLOAT_MAX;

    while (stack.count > 0) {
        UIView *candidate = stack.lastObject;
        [stack removeLastObject];

        for (UIView *subview in candidate.subviews) {
            [stack addObject:subview];

            if (![subview
                    isKindOfClass:UIButton.class] ||
                subview.hidden ||
                subview.alpha <= 0.01) {
                continue;
            }

            CGRect frame =
                [root convertRect:subview.bounds
                        fromView:subview];

            if (frame.size.width <= 0.0 ||
                frame.size.height <= 0.0 ||
                frame.size.width > 64.0 ||
                frame.size.height > 64.0) {
                continue;
            }

            if (CGRectGetMidX(frame) >=
                CGRectGetMinX(searchFrame)) {
                continue;
            }

            CGFloat distance =
                CGRectGetMinX(searchFrame) -
                CGRectGetMaxX(frame);

            if (distance >= -8.0 &&
                distance < bestDistance) {
                best = (UIButton *)subview;
                bestDistance = distance;
            }
        }
    }

    return best;
}

static UIVisualEffectView *
YTLGSearchBackGlassView(UIButton *button) {
    UIVisualEffectView *glass =
        objc_getAssociatedObject(
            button,
            kYTLGSearchBackGlassKey
        );

    if (!glass) {
        glass =
            [[UIVisualEffectView alloc]
                initWithEffect:
                    YTLGSmallControlGlassEffect()];

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

static void YTLGUpdateSearchBackGlass(
    YTSearchViewController *controller
) {
    UIButton *button =
        YTLGSearchBackButton(controller);

    if (!button ||
        !button.window ||
        !button.superview ||
        button.hidden ||
        button.alpha <= 0.01) {
        return;
    }

    UIView *host = button.superview;

    UIVisualEffectView *glass =
        YTLGSearchBackGlassView(button);

    if (glass.superview != host) {
        [glass removeFromSuperview];
        [host insertSubview:glass
               belowSubview:button];
    }

    CGRect buttonFrame =
        [button convertRect:button.bounds
                     toView:host];

    CGFloat side =
        MAX(44.0,
            MIN(48.0,
                MAX(buttonFrame.size.width,
                    buttonFrame.size.height)));

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

static void YTLGRefreshSearchBackSoon(
    YTSearchViewController *controller
) {
    if (!controller) return;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (controller.view.window) {
                YTLGUpdateSearchBackGlass(
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

    YTLGUpdateSearchBackGlass(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);

    YTLGRefreshSearchBackSoon(self);
}

%end

%end


#pragma mark - Video player top-controls Liquid Glass

static const void *kYTLGPlayerLeftGlassKey =
    &kYTLGPlayerLeftGlassKey;

static const void *kYTLGPlayerRightGlassKey =
    &kYTLGPlayerRightGlassKey;

static BOOL YTLGControlHasVisibleContent(
    UIControl *control
) {
    if (!control ||
        control.hidden ||
        control.alpha <= 0.01) {
        return NO;
    }

    if ([control isKindOfClass:UIButton.class]) {
        UIButton *button =
            (UIButton *)control;

        if (button.currentImage ||
            button.currentTitle.length > 0 ||
            button.currentBackgroundImage) {
            return YES;
        }
    }

    for (UIView *subview in control.subviews) {
        if (subview.hidden ||
            subview.alpha <= 0.01 ||
            CGRectIsEmpty(subview.bounds)) {
            continue;
        }

        if ([subview
                isKindOfClass:UIImageView.class]) {
            if (((UIImageView *)subview).image) {
                return YES;
            }

            continue;
        }

        if ([subview
                isKindOfClass:UILabel.class]) {
            if (((UILabel *)subview).text.length > 0) {
                return YES;
            }

            continue;
        }

        return YES;
    }

    return NO;
}

static void YTLGCollectPlayerControls(
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

        CGSize size = subview.bounds.size;

        BOOL iconSized =
            size.width > 0.0 &&
            size.height > 0.0 &&
            size.width <= 72.0 &&
            size.height <= 72.0;

        if ([subview
                isKindOfClass:UIControl.class] &&
            iconSized &&
            YTLGControlHasVisibleContent(
                (UIControl *)subview)) {

            [controls addObject:
                (UIControl *)subview];

            continue;
        }

        YTLGCollectPlayerControls(
            subview,
            controls
        );
    }
}

static UIView *
YTLGTopPlayerControlsContainer(
    YTMainAppControlsOverlayView *overlay
) {
    id value =
        YTLGObjectIvar(
            overlay,
            "_topControlsAccessibilityContainerView"
        );

    if ([value isKindOfClass:UIView.class]) {
        return (UIView *)value;
    }

    @try {
        value =
            [overlay valueForKey:
                @"_topControlsAccessibilityContainerView"];
    } @catch (__unused NSException *exception) {
        value = nil;
    }

    return [value isKindOfClass:UIView.class]
        ? (UIView *)value
        : nil;
}

static UIView *
YTLGDirectBranchUnderAncestor(
    UIView *view,
    UIView *ancestor
) {
    if (!view || !ancestor) return nil;

    UIView *branch = view;

    while (branch.superview &&
           branch.superview != ancestor) {
        branch = branch.superview;
    }

    return branch.superview == ancestor
        ? branch
        : nil;
}

static UIVisualEffectView *
YTLGPlayerGroupGlass(
    YTMainAppControlsOverlayView *overlay,
    const void *key,
    NSString *identifier
) {
    UIVisualEffectView *glass =
        objc_getAssociatedObject(
            overlay,
            key
        );

    if (!glass) {
        glass =
            [[UIVisualEffectView alloc]
                initWithEffect:
                    YTLGSmallControlGlassEffect()];

        glass.userInteractionEnabled = NO;
        glass.opaque = NO;
        glass.backgroundColor =
            UIColor.clearColor;
        glass.clipsToBounds = YES;
        glass.layer.cornerCurve =
            kCACornerCurveContinuous;

        glass.accessibilityIdentifier =
            identifier;

        objc_setAssociatedObject(
            overlay,
            key,
            glass,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }

    return glass;
}

static void YTLGApplyPlayerGroupGlass(
    YTMainAppControlsOverlayView *overlay,
    UIView *topContainer,
    NSArray<UIControl *> *controls,
    const void *key,
    NSString *identifier
) {
    UIVisualEffectView *glass =
        objc_getAssociatedObject(
            overlay,
            key
        );

    if (controls.count == 0) {
        glass.hidden = YES;
        return;
    }

    CGRect unionRect = CGRectNull;

    for (UIControl *control in controls) {
        CGRect frame =
            [control convertRect:control.bounds
                          toView:overlay];

        if (CGRectIsEmpty(frame) ||
            frame.size.width > 80.0 ||
            frame.size.height > 80.0) {
            continue;
        }

        unionRect =
            CGRectIsNull(unionRect)
                ? frame
                : CGRectUnion(
                    unionRect,
                    frame
                );
    }

    if (CGRectIsNull(unionRect) ||
        CGRectIsEmpty(unionRect)) {
        if (glass) glass.hidden = YES;
        return;
    }

    unionRect =
        CGRectInset(
            unionRect,
            -8.0,
            -5.0
        );

    CGRect safe =
        UIEdgeInsetsInsetRect(
            overlay.bounds,
            overlay.safeAreaInsets
        );

    if (CGRectIsEmpty(safe)) {
        safe = overlay.bounds;
    }

    unionRect =
        CGRectIntersection(
            unionRect,
            safe
        );

    if (CGRectIsNull(unionRect) ||
        CGRectIsEmpty(unionRect) ||
        unionRect.size.height > 62.0 ||
        unionRect.size.width >
            overlay.bounds.size.width * 0.48) {

        if (glass) glass.hidden = YES;
        return;
    }

    // A single top icon should read as a circle, not a narrow lozenge.
    if (controls.count == 1) {
        CGFloat side =
            MAX(
                44.0,
                unionRect.size.height
            );

        CGPoint center =
            CGPointMake(
                CGRectGetMidX(unionRect),
                CGRectGetMidY(unionRect)
            );

        unionRect =
            CGRectMake(
                center.x - side * 0.5,
                center.y - side * 0.5,
                side,
                side
            );
    }

    glass =
        YTLGPlayerGroupGlass(
            overlay,
            key,
            identifier
        );

    glass.hidden = NO;
    glass.frame = unionRect;
    glass.layer.cornerRadius =
        unionRect.size.height * 0.5;

    UIView *branch =
        YTLGDirectBranchUnderAncestor(
            topContainer,
            overlay
        );

    if (branch) {
        if (glass.superview != overlay) {
            [glass removeFromSuperview];
        }

        [overlay insertSubview:glass
                 belowSubview:branch];
    } else {
        if (glass.superview != overlay) {
            [glass removeFromSuperview];
            [overlay insertSubview:glass
                           atIndex:0];
        }
    }
}

static void YTLGUpdatePlayerTopGlass(
    YTMainAppControlsOverlayView *overlay
) {
    if (!overlay ||
        !overlay.window ||
        CGRectIsEmpty(overlay.bounds)) {
        return;
    }

    UIView *topContainer =
        YTLGTopPlayerControlsContainer(
            overlay
        );

    if (!topContainer ||
        topContainer.hidden ||
        topContainer.alpha <= 0.01) {

        UIVisualEffectView *left =
            objc_getAssociatedObject(
                overlay,
                kYTLGPlayerLeftGlassKey
            );

        UIVisualEffectView *right =
            objc_getAssociatedObject(
                overlay,
                kYTLGPlayerRightGlassKey
            );

        left.hidden = YES;
        right.hidden = YES;
        return;
    }

    NSMutableArray<UIControl *> *controls =
        [NSMutableArray array];

    YTLGCollectPlayerControls(
        topContainer,
        controls
    );

    CGFloat midX =
        overlay.bounds.size.width * 0.5;

    NSMutableArray<UIControl *> *left =
        [NSMutableArray array];

    NSMutableArray<UIControl *> *right =
        [NSMutableArray array];

    for (UIControl *control in controls) {
        CGRect frame =
            [control convertRect:control.bounds
                          toView:overlay];

        // Ignore anything straddling the center; those are likely central
        // playback controls rather than top-corner actions.
        if (CGRectGetMaxX(frame) < midX) {
            [left addObject:control];
        } else if (CGRectGetMinX(frame) > midX) {
            [right addObject:control];
        }
    }

    YTLGApplyPlayerGroupGlass(
        overlay,
        topContainer,
        left,
        kYTLGPlayerLeftGlassKey,
        @"YTLiquidGlass.PlayerTopLeft"
    );

    YTLGApplyPlayerGroupGlass(
        overlay,
        topContainer,
        right,
        kYTLGPlayerRightGlassKey,
        @"YTLiquidGlass.PlayerTopRight"
    );
}

static void YTLGRefreshPlayerTopGlassSoon(
    YTMainAppControlsOverlayView *overlay
) {
    if (!overlay) return;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (overlay.window) {
                YTLGUpdatePlayerTopGlass(
                    overlay
                );
            }
        }
    );
}

%group YTLiquidGlassPlayerTopControls

%hook YTMainAppControlsOverlayView

- (void)layoutSubviews {
    %orig;

    YTLGUpdatePlayerTopGlass(self);
}

- (void)didMoveToWindow {
    %orig;

    if (self.window) {
        YTLGRefreshPlayerTopGlassSoon(self);
    }
}

- (void)setTopOverlayVisible:(BOOL)visible
    isAutonavCanceledState:(BOOL)canceledState {

    %orig(visible, canceledState);

    YTLGRefreshPlayerTopGlassSoon(self);
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
            NSClassFromString(@"YTMainAppControlsOverlayView")) {

            %init(YTLiquidGlassPlayerTopControls);
        }
    }
}
