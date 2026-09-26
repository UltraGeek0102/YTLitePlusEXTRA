#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// YTLiquidGlass v0.4 — Native UIKit bridge
//
// Apollo Reborn gets its floating Liquid Glass tab bar from UIKit itself:
// a modern-sdk-linked UITabBarController/UITabBar produces the floating
// capsule, native Liquid Lens, spacing and selection morphing.
//
// YouTube does not use UITabBarController for its bottom navigation. It uses
// YTPivotBarView/YTPivotBarItemView. This tweak therefore creates a *visual*
// child UITabBarController that mirrors the current YouTube/YTLite tabs.
//
// YTLite/YouTube remain the source of truth for:
//   • which tabs exist
//   • tab order
//   • custom tabs
//   • pivot identifiers
//   • actual navigation
//
// A tap on the native UIKit bar is forwarded back to
// -[YTPivotBarViewController selectItemWithPivotIdentifier:].
//
// No Home/Shorts/etc. identifiers are hard-coded.

@interface YTIPivotBarItemRenderer : NSObject
@property(nonatomic, copy, readonly) NSString *pivotIdentifier;
@end

@interface YTPivotBarViewController : UIViewController
@property(nonatomic, copy, readonly) NSString *selectedPivotIdentifier;
- (UIView *)pivotBarView;
- (void)selectItemWithPivotIdentifier:(id)identifier;
@end

@interface YTPivotBarView : UIView
- (void)setRenderer:(id)renderer;
- (void)selectItemWithPivotIdentifier:(id)identifier;
@end

@interface YTPivotBarItemView : UIView
@property(nonatomic, strong, readonly) YTIPivotBarItemRenderer *renderer;
@property(nonatomic, strong, readonly) UIButton *navigationButton;
@property(nonatomic, weak, readonly) YTPivotBarViewController *delegate;
- (void)setRenderer:(id)renderer;
@end

static const void *kYTLGBridgeKey = &kYTLGBridgeKey;

@class YTLGNativeTabBarController;

static YTPivotBarView *YTLGAncestorPivotBar(UIView *view);
static NSArray<YTPivotBarItemView *> *YTLGCurrentPivotItems(YTPivotBarView *bar);
static void YTLGInstallOrRefreshBridge(YTPivotBarViewController *owner);
static void YTLGRefreshBridgeForBar(YTPivotBarView *bar);
static void YTLGSyncBridgeSelection(YTPivotBarViewController *owner);

#pragma mark - Native bridge controller

@interface YTLGNativeTabBarController : UITabBarController <UITabBarControllerDelegate>
@property(nonatomic, weak) YTPivotBarViewController *youtubeController;
@property(nonatomic, weak) YTPivotBarView *youtubeBar;
@property(nonatomic, copy) NSArray<NSString *> *pivotIdentifiers;
@property(nonatomic, copy) NSString *contentSignature;
@property(nonatomic, assign) BOOL syncingSelection;
@end

@implementation YTLGNativeTabBarController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.delegate = self;
        self.syncingSelection = NO;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // The actual material/geometry is owned by UIKit. Do not install a custom
    // UITabBarAppearance here because that can force the legacy-looking bar.
    self.view.backgroundColor = UIColor.clearColor;
    self.view.opaque = NO;
    self.view.clipsToBounds = NO;

    self.tabBar.opaque = NO;
    self.tabBar.clipsToBounds = NO;
}

- (BOOL)tabBarController:(UITabBarController *)tabBarController
 shouldSelectViewController:(UIViewController *)viewController {

    if (self.syncingSelection) {
        return YES;
    }

    NSUInteger index =
        [self.viewControllers indexOfObjectIdenticalTo:viewController];

    if (index == NSNotFound ||
        index >= self.pivotIdentifiers.count) {
        return YES;
    }

    NSString *identifier = self.pivotIdentifiers[index];

    if (identifier.length > 0 &&
        self.youtubeController) {

        // Forward the user's tap into YouTube/YTLite. This preserves their
        // navigation model instead of replacing it with our dummy controllers.
        [self.youtubeController
            selectItemWithPivotIdentifier:identifier];
    }

    return YES;
}

@end

#pragma mark - Pivot item discovery

static void YTLGCollectPivotItems(
    UIView *view,
    NSMutableArray<YTPivotBarItemView *> *items
) {
    if (!view) return;

    Class itemClass =
        NSClassFromString(@"YTPivotBarItemView");

    if (itemClass &&
        [view isKindOfClass:itemClass]) {
        [items addObject:(YTPivotBarItemView *)view];
        return;
    }

    for (UIView *subview in view.subviews) {
        // The native bridge has its own UIKit hierarchy. Never recurse into it.
        if ([subview.accessibilityIdentifier
                isEqualToString:@"YTLiquidGlass.NativeBridge"]) {
            continue;
        }

        YTLGCollectPivotItems(subview, items);
    }
}

static NSArray<YTPivotBarItemView *> *
YTLGCurrentPivotItems(YTPivotBarView *bar) {
    NSMutableArray<YTPivotBarItemView *> *items =
        [NSMutableArray array];

    YTLGCollectPivotItems(bar, items);

    [items sortUsingComparator:
        ^NSComparisonResult(
            YTPivotBarItemView *a,
            YTPivotBarItemView *b
        ) {
            CGRect af =
                [a convertRect:a.bounds toView:bar];

            CGRect bf =
                [b convertRect:b.bounds toView:bar];

            CGFloat ax = CGRectGetMidX(af);
            CGFloat bx = CGRectGetMidX(bf);

            if (ax < bx) return NSOrderedAscending;
            if (ax > bx) return NSOrderedDescending;
            return NSOrderedSame;
        }];

    return items;
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

#pragma mark - Mirroring helpers

static UIImage *YTLGNativeImage(UIImage *image) {
    if (![image isKindOfClass:UIImage.class]) {
        return nil;
    }

    // Profile/avatar-style images are commonly AlwaysOriginal. Preserve that.
    // Normal YouTube glyphs are made template images so UIKit can apply its
    // adaptive Liquid Glass selected/unselected coloring.
    if (image.renderingMode ==
        UIImageRenderingModeAlwaysOriginal) {
        return image;
    }

    return [image
        imageWithRenderingMode:
            UIImageRenderingModeAlwaysTemplate];
}

static NSString *
YTLGTitleForPivotItem(YTPivotBarItemView *item) {
    UIButton *button = item.navigationButton;

    if (![button isKindOfClass:UIButton.class]) {
        return nil;
    }

    NSString *normalTitle =
        [button titleForState:UIControlStateNormal];

    // If YTLite deliberately set an empty title (Hide Tab Labels), respect it:
    // nil title tells UIKit to use its native compact icon-only presentation.
    if (normalTitle != nil) {
        return normalTitle.length > 0
            ? normalTitle
            : nil;
    }

    NSString *currentTitle = button.currentTitle;

    if (currentTitle.length > 0) {
        return currentTitle;
    }

    // Only use accessibility text as a fallback when the button never supplied
    // a visible title in the first place.
    NSString *accessibilityTitle =
        button.accessibilityLabel;

    return accessibilityTitle.length > 0
        ? accessibilityTitle
        : nil;
}

static NSString *
YTLGAccessibilityTitleForPivotItem(
    YTPivotBarItemView *item,
    NSString *visibleTitle
) {
    NSString *label =
        item.navigationButton.accessibilityLabel;

    if (label.length > 0) {
        return label;
    }

    if (visibleTitle.length > 0) {
        return visibleTitle;
    }

    return item.renderer.pivotIdentifier;
}

static UIImage *
YTLGNormalImageForPivotItem(
    YTPivotBarItemView *item
) {
    UIButton *button = item.navigationButton;

    UIImage *image =
        [button imageForState:UIControlStateNormal];

    if (!image) {
        image = button.currentImage;
    }

    if (!image) {
        image = button.imageView.image;
    }

    return YTLGNativeImage(image);
}

static UIImage *
YTLGSelectedImageForPivotItem(
    YTPivotBarItemView *item,
    UIImage *fallback
) {
    UIButton *button = item.navigationButton;

    UIImage *image =
        [button imageForState:UIControlStateSelected];

    if (!image) {
        image =
            [button imageForState:UIControlStateHighlighted];
    }

    if (!image) {
        image = fallback;
    }

    return YTLGNativeImage(image);
}

static NSString *
YTLGSignatureForPivotItems(
    NSArray<YTPivotBarItemView *> *items
) {
    NSMutableArray<NSString *> *parts =
        [NSMutableArray arrayWithCapacity:items.count];

    for (YTPivotBarItemView *item in items) {
        NSString *identifier =
            item.renderer.pivotIdentifier ?: @"";

        NSString *title =
            YTLGTitleForPivotItem(item) ?: @"";

        UIImage *normal =
            YTLGNormalImageForPivotItem(item);

        UIImage *selected =
            YTLGSelectedImageForPivotItem(
                item,
                normal
            );

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

#pragma mark - Original YouTube chrome suppression

static void YTLGHideOriginalPivotChrome(
    YTPivotBarView *bar,
    UIView *bridgeView
) {
    if (!bar) return;

    bar.opaque = NO;
    bar.backgroundColor = UIColor.clearColor;
    bar.layer.backgroundColor =
        UIColor.clearColor.CGColor;

    // The native UIKit bridge visually replaces YouTube's custom pivot
    // hierarchy, but the original hierarchy remains alive underneath so YTLite
    // can still rebuild/reorder it and remain the source of truth.
    for (UIView *subview in bar.subviews) {
        if (subview == bridgeView) {
            subview.hidden = NO;
            subview.alpha = 1.0;
            continue;
        }

        subview.hidden = YES;
    }

    bar.clipsToBounds = NO;
    bar.layer.masksToBounds = NO;
}

#pragma mark - Build / refresh the native UIKit tab bar

static YTLGNativeTabBarController *
YTLGBridgeForBar(YTPivotBarView *bar) {
    return objc_getAssociatedObject(
        bar,
        kYTLGBridgeKey
    );
}

static void YTLGAttachBridgeIfNeeded(
    YTPivotBarViewController *owner,
    YTPivotBarView *bar,
    YTLGNativeTabBarController *bridge
) {
    if (!owner || !bar || !bridge) return;

    if (bridge.parentViewController != owner) {
        [owner addChildViewController:bridge];
    }

    UIView *bridgeView = bridge.view;

    bridgeView.accessibilityIdentifier =
        @"YTLiquidGlass.NativeBridge";

    bridgeView.backgroundColor =
        UIColor.clearColor;

    bridgeView.opaque = NO;
    bridgeView.clipsToBounds = NO;

    bridgeView.frame = bar.bounds;

    bridgeView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    if (bridgeView.superview != bar) {
        [bridgeView removeFromSuperview];
        [bar addSubview:bridgeView];
    }

    if (bridge.parentViewController == owner) {
        [bridge didMoveToParentViewController:owner];
    }

    [bar bringSubviewToFront:bridgeView];

    [bridgeView setNeedsLayout];
    [bridgeView layoutIfNeeded];
}

static void YTLGRebuildNativeItemsIfNeeded(
    YTLGNativeTabBarController *bridge
) {
    YTPivotBarView *bar = bridge.youtubeBar;

    if (!bar) return;

    NSArray<YTPivotBarItemView *> *items =
        YTLGCurrentPivotItems(bar);

    if (items.count == 0) {
        bridge.view.hidden = YES;
        return;
    }

    NSString *signature =
        YTLGSignatureForPivotItems(items);

    BOOL needsRebuild =
        ![bridge.contentSignature
            isEqualToString:signature];

    if (needsRebuild) {
        NSMutableArray<UIViewController *> *controllers =
            [NSMutableArray arrayWithCapacity:items.count];

        NSMutableArray<NSString *> *identifiers =
            [NSMutableArray arrayWithCapacity:items.count];

        for (YTPivotBarItemView *item in items) {
            NSString *identifier =
                item.renderer.pivotIdentifier ?: @"";

            NSString *title =
                YTLGTitleForPivotItem(item);

            NSString *accessibilityTitle =
                YTLGAccessibilityTitleForPivotItem(
                    item,
                    title
                );

            UIImage *normalImage =
                YTLGNormalImageForPivotItem(item);

            UIImage *selectedImage =
                YTLGSelectedImageForPivotItem(
                    item,
                    normalImage
                );

            UIViewController *dummy =
                [[UIViewController alloc] init];

            dummy.view.backgroundColor =
                UIColor.clearColor;

            dummy.view.opaque = NO;

            UITabBarItem *tabItem =
                [[UITabBarItem alloc]
                    initWithTitle:title
                           image:normalImage
                   selectedImage:selectedImage];

            tabItem.accessibilityLabel =
                accessibilityTitle;

            dummy.tabBarItem = tabItem;

            [controllers addObject:dummy];
            [identifiers addObject:identifier];
        }

        bridge.syncingSelection = YES;
        bridge.viewControllers = controllers;
        bridge.pivotIdentifiers = identifiers;
        bridge.contentSignature = signature;
        bridge.syncingSelection = NO;
    }

    bridge.view.hidden = NO;

    // Mirror YouTube's selected pivot into UIKit's native selected tab.
    NSString *selectedIdentifier =
        bridge.youtubeController.selectedPivotIdentifier;

    NSUInteger selectedIndex =
        [bridge.pivotIdentifiers
            indexOfObject:selectedIdentifier ?: @""];

    if (selectedIndex != NSNotFound &&
        selectedIndex < bridge.viewControllers.count &&
        bridge.selectedIndex != selectedIndex) {

        bridge.syncingSelection = YES;
        bridge.selectedIndex = selectedIndex;
        bridge.syncingSelection = NO;
    }

    [bridge.view setNeedsLayout];
    [bridge.view layoutIfNeeded];
}

static void
YTLGInstallOrRefreshBridge(
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

    YTLGNativeTabBarController *bridge =
        YTLGBridgeForBar(bar);

    if (!bridge) {
        bridge =
            [[YTLGNativeTabBarController alloc] init];

        bridge.youtubeController = owner;
        bridge.youtubeBar = bar;

        objc_setAssociatedObject(
            bar,
            kYTLGBridgeKey,
            bridge,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    } else {
        bridge.youtubeController = owner;
        bridge.youtubeBar = bar;
    }

    YTLGAttachBridgeIfNeeded(
        owner,
        bar,
        bridge
    );

    YTLGRebuildNativeItemsIfNeeded(bridge);

    YTLGHideOriginalPivotChrome(
        bar,
        bridge.view
    );

    [bar bringSubviewToFront:bridge.view];
}

static void
YTLGRefreshBridgeForBar(
    YTPivotBarView *bar
) {
    if (!bar) return;

    YTLGNativeTabBarController *bridge =
        YTLGBridgeForBar(bar);

    if (!bridge) {
        // The owner hook will create it as soon as the controller is available.
        return;
    }

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (!bar.window) return;

            bridge.view.frame = bar.bounds;

            YTLGRebuildNativeItemsIfNeeded(
                bridge
            );

            YTLGHideOriginalPivotChrome(
                bar,
                bridge.view
            );

            [bar bringSubviewToFront:
                bridge.view];
        }
    );
}

static void
YTLGSyncBridgeSelection(
    YTPivotBarViewController *owner
) {
    if (!owner) return;

    UIView *rawBar =
        [owner pivotBarView];

    if (!rawBar) return;

    YTLGNativeTabBarController *bridge =
        YTLGBridgeForBar(
            (YTPivotBarView *)rawBar
        );

    if (!bridge) {
        YTLGInstallOrRefreshBridge(owner);
        return;
    }

    NSString *selected =
        owner.selectedPivotIdentifier;

    NSUInteger index =
        [bridge.pivotIdentifiers
            indexOfObject:selected ?: @""];

    if (index != NSNotFound &&
        index < bridge.viewControllers.count &&
        bridge.selectedIndex != index) {

        bridge.syncingSelection = YES;
        bridge.selectedIndex = index;
        bridge.syncingSelection = NO;
    }
}

#pragma mark - Hooks

%group YTLiquidGlassNativeBridge

%hook YTPivotBarViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            YTLGInstallOrRefreshBridge(self);
        }
    );
}

- (void)viewDidLayoutSubviews {
    %orig;

    YTLGInstallOrRefreshBridge(self);
}

- (void)selectItemWithPivotIdentifier:(id)identifier {
    %orig(identifier);

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            YTLGInstallOrRefreshBridge(self);
            YTLGSyncBridgeSelection(self);
        }
    );
}

%end

%hook YTPivotBarView

- (void)setRenderer:(id)renderer {
    %orig(renderer);

    // YTLite edits the renderer array before/around this call when the user
    // adds, removes or reorders tabs. Re-mirror the resulting runtime views.
    YTLGRefreshBridgeForBar(self);
}

- (void)layoutSubviews {
    %orig;

    YTLGNativeTabBarController *bridge =
        YTLGBridgeForBar(self);

    if (bridge) {
        bridge.view.frame = self.bounds;

        YTLGRebuildNativeItemsIfNeeded(
            bridge
        );

        YTLGHideOriginalPivotChrome(
            self,
            bridge.view
        );

        [self bringSubviewToFront:
            bridge.view];
    }
}

%end

%hook YTPivotBarItemView

- (void)setRenderer:(id)renderer {
    %orig(renderer);

    YTPivotBarView *bar =
        YTLGAncestorPivotBar(self);

    if (bar) {
        YTLGRefreshBridgeForBar(bar);
    }
}

%end

%end

%ctor {
    if (@available(iOS 26.0, *)) {
        if (NSClassFromString(@"YTPivotBarView") &&
            NSClassFromString(@"YTPivotBarItemView") &&
            NSClassFromString(@"YTPivotBarViewController")) {

            %init(YTLiquidGlassNativeBridge);
        }
    }
}
