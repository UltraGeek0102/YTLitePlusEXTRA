// YTLiquidGlass vNext — native secondary rails + compact comment controls + glass panels
// Retains only the implementations that were confirmed working:
// native bottom tab bar, top-right header glass, search glass,
// compact back buttons, and native UIKit action menus.
// Watch-page metadata/action-row experiments are intentionally excluded.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

// YTLiquidGlass v1.3 — Native tab bar + header + search + native action menus
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

static const void *kYTLGNativeBarKey = &kYTLGNativeBarKey;
static const void *kYTLGActiveIdentifiersKey = &kYTLGActiveIdentifiersKey;
static const void *kYTLGOwnerKey = &kYTLGOwnerKey;
static const void *kYTLGRefreshingKey = &kYTLGRefreshingKey;

#pragma mark - Native bar subclass

@interface YTLGNativeTabBar : UITabBar <UITabBarDelegate>
@property(nonatomic, weak) YTPivotBarViewController *youtubeController;
@property(nonatomic, weak) YTPivotBarView *youtubePivotBar;
@property(nonatomic, copy) NSArray<NSString *> *pivotIdentifiers;
@property(nonatomic, copy) NSDictionary<NSString *, UIButton *> *originalButtons;
@property(nonatomic, copy) NSDictionary<NSString *, UIView *> *originalItemViews;
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

    if (identifier.length == 0) {
        return;
    }

    // YouTube's Create/Upload pivot (FEuploads) is an action-only item rather
    // than a persistent navigation destination. Calling
    // selectItemWithPivotIdentifier: on it does not reliably open Create.
    // Forward the tap to YouTube's original hidden button instead.
    if ([identifier
            caseInsensitiveCompare:@"FEuploads"]
        == NSOrderedSame) {

        UIButton *originalButton =
            self.originalButtons[identifier];

        BOOL dispatched = NO;
        if ([originalButton isKindOfClass:UIButton.class] &&
            originalButton.allTargets.count > 0) {
            [originalButton
                sendActionsForControlEvents:
                    UIControlEventTouchUpInside];
            dispatched = YES;
        }

        // Icon-only pivots can install the tap on the item view rather than
        // on navigationButton. An empty button target list must not swallow
        // the native Create tap.
        if (!dispatched) {
            UIView *originalItem = self.originalItemViews[identifier];
            if (originalItem &&
                [originalItem respondsToSelector:@selector(accessibilityActivate)]) {
                dispatched = [originalItem accessibilityActivate];
            }
        }

        if (!dispatched && self.youtubePivotBar) {
            [self.youtubePivotBar selectItemWithPivotIdentifier:identifier];
            dispatched = YES;
        }
        if (!dispatched && self.youtubeController) {
            [self.youtubeController selectItemWithPivotIdentifier:identifier];
        }

        // Create is momentary. Return UIKit's selection lens to YouTube's
        // actual selected pivot after the Create menu is dispatched.
        dispatch_async(
            dispatch_get_main_queue(),
            ^{
                NSString *selected =
                    self.youtubeController
                        .selectedPivotIdentifier;

                NSUInteger selectedIndex =
                    [self.pivotIdentifiers
                        indexOfObject:selected];

                if (selectedIndex != NSNotFound &&
                    selectedIndex <
                        self.items.count) {

                    self.syncingSelection = YES;
                    self.selectedItem =
                        self.items[
                            selectedIndex
                        ];
                    self.syncingSelection = NO;
                }
            }
        );

        return;
    }

    if (self.youtubeController) {
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

static NSString *
YTLGIdentifierForItemView(YTPivotBarItemView *item) {
    id renderer = item.renderer;
    if ([renderer respondsToSelector:@selector(pivotIdentifier)]) {
        return [renderer pivotIdentifier];
    }
    if ([renderer respondsToSelector:@selector(pivotBarItemRenderer)] ||
        [renderer respondsToSelector:@selector(pivotBarIconOnlyItemRenderer)]) {
        return YTLGPivotIdentifierForSupportedRenderer(renderer);
    }
    return nil;
}

static NSDictionary<NSString *, YTPivotBarItemView *> *
YTLGItemViewsByIdentifier(YTPivotBarView *bar) {
    NSMutableDictionary *map =
        [NSMutableDictionary dictionary];

    for (YTPivotBarItemView *item
            in YTLGAllItemViews(bar)) {

        NSString *identifier = YTLGIdentifierForItemView(item);

        if (identifier.length > 0 &&
            !map[identifier]) {
            map[identifier] = item;
        }
    }

    return map;
}

static UIButton *
YTLGFindCreateButtonInView(
    UIView *root
) {
    if (!root) return nil;

    NSMutableArray<UIView *> *stack =
        [NSMutableArray
            arrayWithObject:root];

    while (stack.count > 0) {
        UIView *candidate =
            stack.lastObject;

        [stack removeLastObject];

        if ([candidate
                isKindOfClass:
                    UIButton.class]) {

            UIButton *button =
                (UIButton *)candidate;

            NSString *token =
                [[NSString
                    stringWithFormat:
                        @"%@ %@ %@",
                        button.accessibilityLabel ?: @"",
                        button.accessibilityIdentifier ?: @"",
                        button.currentTitle ?: @""]
                    lowercaseString];

            if ([token containsString:@"create"] ||
                [token containsString:@"upload"]) {

                return button;
            }
        }

        for (UIView *subview
                in candidate.subviews) {
            [stack addObject:subview];
        }
    }

    return nil;
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
    id renderer = item.renderer;
    id thumbnail = [renderer respondsToSelector:@selector(thumbnail)]
        ? [renderer thumbnail] : nil;
    if (thumbnail != nil) {
        return YES;
    }

    return NO;
}

static BOOL
YTLGIsYTKACETab(
    YTPivotBarItemView *item
) {
    NSString *identifier = YTLGIdentifierForItemView(item);

    return
        [identifier
            caseInsensitiveCompare:@"FEYTKACE"]
        == NSOrderedSame;
}

static UIImage *
YTLGYTKACETabImage(
    BOOL selected
) {
    UIImage *image =
        [UIImage
            systemImageNamed:
                selected
                    ? @"arrow.down.square.fill"
                    : @"arrow.down.square"];

    return [image
        imageWithRenderingMode:
            UIImageRenderingModeAlwaysTemplate];
}

static UIImage *
YTLGCustomOverlayImageForItem(
    YTPivotBarItemView *item
) {
    if (!item) {
        return nil;
    }

    // YTKACE uses 0x59414345 for its main custom tab icon and
    // 0x59414349 for extra-tab replacement icons.
    for (NSNumber *tagNumber in
            @[@(0x59414345),
              @(0x59414349)]) {

        UIView *candidate =
            [item
                viewWithTag:
                    tagNumber.integerValue];

        if ([candidate
                isKindOfClass:
                    UIImageView.class]) {

            UIImage *image =
                ((UIImageView *)candidate).image;

            if (image) {
                return [image
                    imageWithRenderingMode:
                        UIImageRenderingModeAlwaysTemplate];
            }
        }
    }

    return nil;
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
    if (YTLGIsYTKACETab(item)) {
        return YTLGYTKACETabImage(NO);
    }

    UIButton *button = item.navigationButton;

    UIImage *image = nil;

    if ([button isKindOfClass:UIButton.class]) {
        image =
            [button
                imageForState:
                    UIControlStateNormal];

        if (!image) {
            image = button.currentImage;
        }

        if (!image) {
            image = button.imageView.image;
        }
    }

    // YTKACE and similar tweaks can draw a custom tab icon as an overlay
    // UIImageView instead of putting it on navigationButton.
    if (!image) {
        image =
            YTLGCustomOverlayImageForItem(
                item
            );
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
    if (YTLGIsYTKACETab(item)) {
        return YTLGYTKACETabImage(YES);
    }

    UIButton *button = item.navigationButton;

    UIImage *image = nil;

    if ([button isKindOfClass:UIButton.class]) {
        image =
            [button
                imageForState:
                    UIControlStateSelected];

        if (!image) {
            image =
                [button
                    imageForState:
                        UIControlStateHighlighted];
        }
    }

    if (!image) {
        image =
            YTLGCustomOverlayImageForItem(
                item
            );
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
    nativeBar.youtubePivotBar = bar;

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

            NSString *identifier = YTLGIdentifierForItemView(item);

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

        NSMutableDictionary<NSString *, UIButton *> *originalButtons =
            [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, UIView *> *originalItemViews =
            [NSMutableDictionary dictionary];

        for (NSString *identifier in identifiers) {
            YTPivotBarItemView *itemView =
                views[identifier];

            BOOL isCreate =
                [identifier
                    caseInsensitiveCompare:@"FEuploads"]
                == NSOrderedSame;

            // FEuploads may be represented as an icon-only renderer and not
            // always expose a normal YTPivotBarItemView. Synthesize the native
            // Create item while still forwarding its action to YouTube.
            if (!itemView &&
                isCreate) {

                UIButton *createButton =
                    YTLGFindCreateButtonInView(
                        bar
                    );

                UIImage *normal =
                    createButton.currentImage
                    ?: [createButton
                        imageForState:
                            UIControlStateNormal]
                    ?: [UIImage
                        systemImageNamed:
                            @"plus.circle"];

                UIImage *selected =
                    [createButton
                        imageForState:
                            UIControlStateSelected]
                    ?: [UIImage
                        systemImageNamed:
                            @"plus.circle.fill"]
                    ?: normal;

                UITabBarItem *nativeItem =
                    [[UITabBarItem alloc]
                        initWithTitle:nil
                               image:
                                   YTLGNativeImage(
                                       normal,
                                       NO
                                   )
                       selectedImage:
                                   YTLGNativeImage(
                                       selected,
                                       NO
                                   )];

                nativeItem.accessibilityLabel =
                    createButton
                        .accessibilityLabel
                    ?: @"Create";

                [nativeItems
                    addObject:
                        nativeItem];

                [nativeIdentifiers
                    addObject:
                        identifier];

                if (createButton) {
                    originalButtons[identifier] =
                        createButton;
                }

                continue;
            }

            // Wait for the concrete item view before exposing ordinary tabs.
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
            originalItemViews[identifier] = itemView;

            UIButton *originalButton =
                itemView.navigationButton;

            if ([originalButton
                    isKindOfClass:
                        UIButton.class]) {

                originalButtons[identifier] =
                    originalButton;
            }
        }

        nativeBar.pivotIdentifiers =
            nativeIdentifiers;

        nativeBar.originalButtons =
            originalButtons;
        nativeBar.originalItemViews = originalItemViews;

        // Standalone UITabBar displays the supplied items directly and never
        // synthesizes UITabBarController's "More" view controller.
        [nativeBar
            setItems:nativeItems
            animated:NO];

        nativeBar.contentSignature =
            signature;
    }

    // The underlying buttons are replaced during YouTube/YTLite updates even
    // when their titles and icons (the content signature) stay identical.
    NSMutableDictionary<NSString *, UIButton *> *liveButtons =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, UIView *> *liveItems =
        [NSMutableDictionary dictionary];
    for (NSString *identifier in nativeBar.pivotIdentifiers) {
        YTPivotBarItemView *item = views[identifier];
        if (item) {
            liveItems[identifier] = item;
            if ([item.navigationButton isKindOfClass:UIButton.class]) {
                liveButtons[identifier] = item.navigationButton;
            }
        } else if ([identifier caseInsensitiveCompare:@"FEuploads"] == NSOrderedSame) {
            UIButton *create = YTLGFindCreateButtonInView(bar);
            if (create) liveButtons[identifier] = create;
        }
    }
    nativeBar.originalButtons = liveButtons;
    nativeBar.originalItemViews = liveItems;

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


#pragma mark - Experimental scoped Liquid Glass surfaces

// These modules intentionally avoid the old "glass every YTQTMButton" approach.
// Each feature is restricted to a known container, exact accessibility role,
// or tightly-scoped YouTube/YTKACE screen.
//
// Coverage in this all-in-one test build:
//   • channel/profile CTA buttons
//   • You/Profile page standalone CTA buttons
//   • Accounts/profile header action
//   • comment sort/filter/send controls
//   • compact search-filter control
//   • create/upload action rows when rendered as Elements views
//   • one-piece glass behind the top topic/category chip rail
//   • YTKACE settings standalone controls
//
// Existing stable modules continue to cover:
//   • native standalone bottom UITabBar
//   • YTLite/YTKACE tab order + custom icon compatibility
//   • top-right header controls
//   • inactive + active search glass
//   • compact back buttons
//   • native UIKit UIMenu/UIAction conversion for ordinary non-player action
//     sheets, including suitable create/bottom-sheet flows
//
// Native UIActivityViewController share sheets are deliberately left alone so
// UIKit owns their appearance end-to-end.

@interface _ASDisplayView : UIView
@end

@interface YTChipCloudCell : UIView
@end

@interface YTTabTitlesView : UIView
@end

@interface YTFeedChannelFilterHeaderView : UIView
@end

@interface YTKACERootOptionsController : UIViewController
@end

@interface YTKACETabEditorController : UIViewController
@end

@interface YTKACESearchOverlayController : UIViewController
@end

typedef NS_ENUM(NSInteger, YTLGScopedSurfaceKind) {
    YTLGScopedSurfaceNone = 0,
    YTLGScopedSurfaceRegular,
    YTLGScopedSurfaceProminent,
    YTLGScopedSurfaceCompactCircle
};

static const void *kYTLGScopedElementGlassKey =
    &kYTLGScopedElementGlassKey;

static const void *kYTLGChipRailGlassKey =
    &kYTLGChipRailGlassKey;

static const void *kYTLGYTKACEControlGlassKey =
    &kYTLGYTKACEControlGlassKey;

static UIVisualEffect *
YTLGScopedGlassEffect(BOOL prominent) {
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

            effect.interactive = prominent;

            if (prominent) {
                effect.tintColor =
                    [UIColor.labelColor
                        colorWithAlphaComponent:0.10];
            }

            return effect;
        }
    }

    return [UIBlurEffect
        effectWithStyle:
            UIBlurEffectStyleSystemChromeMaterial];
}

static NSString *
YTLGNormalizedViewToken(UIView *view) {
    if (!view) return @"";

    NSString *className =
        NSStringFromClass(view.class)
            ?: @"";

    NSString *identifier =
        view.accessibilityIdentifier
            ?: @"";

    NSString *label =
        view.accessibilityLabel
            ?: @"";

    return [[NSString
        stringWithFormat:
            @"%@ %@ %@",
            className,
            identifier,
            label]
        lowercaseString];
}

static NSString *
YTLGTrimmedLowerLabel(UIView *view) {
    NSString *label =
        view.accessibilityLabel
            ?: @"";

    return [[label
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet]
        lowercaseString];
}

static BOOL
YTLGViewOrAncestorContainsAny(
    UIView *view,
    NSArray<NSString *> *needles
) {
    UIView *cursor = view;

    for (NSUInteger depth = 0;
         cursor && depth < 22;
         depth++, cursor = cursor.superview) {

        NSString *token =
            YTLGNormalizedViewToken(cursor);

        for (NSString *needle in needles) {
            if ([token containsString:needle]) {
                return YES;
            }
        }
    }

    return NO;
}

static BOOL
YTLGInsideExcludedMediaOrShareUI(
    UIView *view
) {
    return YTLGViewOrAncestorContainsAny(
        view,
        @[
            @"reel_overlay",
            @"shortsplayer",
            @"shorts_player",
            @"fullscreen",
            @"videooverlay",
            @"video_overlay",
            @"controls_overlay",
            @"playeroverlay",
            @"watchcontroller",
            @"uiactivityviewcontroller",
            @"activityviewcontroller"
        ]
    );
}

static BOOL
YTLGViewHasCompactActionGeometry(
    UIView *view,
    CGFloat minimumWidth,
    CGFloat maximumWidth
) {
    if (!view ||
        view.hidden ||
        view.alpha <= 0.01 ||
        CGRectIsEmpty(view.bounds)) {
        return NO;
    }

    CGFloat width =
        CGRectGetWidth(view.bounds);

    CGFloat height =
        CGRectGetHeight(view.bounds);

    return
        height >= 28.0 &&
        height <= 68.0 &&
        width >= minimumWidth &&
        width <= maximumWidth;
}

static BOOL
YTLGLabelStartsWith(
    NSString *label,
    NSString *prefix
) {
    if (label.length == 0 ||
        prefix.length == 0) {
        return NO;
    }

    return
        [label hasPrefix:prefix] ||
        [label isEqualToString:prefix];
}

static YTLGScopedSurfaceKind
YTLGScopedSurfaceKindForElementsView(
    UIView *view
) {
    if (!view ||
        !view.window ||
        YTLGInsideExcludedMediaOrShareUI(view)) {
        return YTLGScopedSurfaceNone;
    }

    NSString *label =
        YTLGTrimmedLowerLabel(view);

    NSString *token =
        YTLGNormalizedViewToken(view);

    // ---- You/Profile standalone CTA buttons ----
    //
    // These labels are intentionally exact/tightly prefixed. This prevents
    // another global-pill regression.
    if (YTLGViewHasCompactActionGeometry(
            view,
            60.0,
            360.0)) {

        if ([label isEqualToString:@"create a channel"] ||
            [label isEqualToString:@"get premium"]) {

            return YTLGScopedSurfaceProminent;
        }

        if ([label isEqualToString:@"accounts"] ||
            [label isEqualToString:@"view channel"] ||
            [label isEqualToString:@"youtube music"] ||
            [label isEqualToString:@"join"] ||
            [label hasPrefix:@"join "]) {

            return YTLGScopedSurfaceRegular;
        }
    }

    // ---- Channel/profile Subscribe CTA ----
    //
    // Do not touch the normal watch-page Subscribe row. Require channel/profile
    // ancestry and explicitly reject slim/watch metadata containers.
    BOOL channelContext =
        YTLGViewOrAncestorContainsAny(
            view,
            @[
                @"channel",
                @"profile",
                @"c4",
                @"identity",
                @"creator",
                @"page_header",
                @"pageheader",
                @"browse_header",
                @"browseheader"
            ]
        );

    BOOL watchContext =
        YTLGViewOrAncestorContainsAny(
            view,
            @[
                @"slimvideo",
                @"watchmetadata",
                @"watch_metadata",
                @"action_bar",
                @"actionbar"
            ]
        );

    BOOL explicitSubscribe =
        YTLGLabelStartsWith(
            label,
            @"subscribe"
        ) ||
        [token
            containsString:
                @"subscribe_button"];

    BOOL wideChannelCTA =
        CGRectGetWidth(view.bounds) >=
            220.0 &&
        CGRectGetHeight(view.bounds) >=
            36.0 &&
        CGRectGetHeight(view.bounds) <=
            72.0;

    if (!watchContext &&
        explicitSubscribe &&
        (channelContext ||
         wideChannelCTA) &&
        YTLGViewHasCompactActionGeometry(
            view,
            64.0,
            420.0)) {

        return
            YTLGScopedSurfaceProminent;
    }

    // ---- Comment controls ----
    //
    // Only compact controls inside a comment hierarchy. Small inline "Reply"
    // text links are below the 28pt minimum and therefore remain untouched.
    BOOL commentContext =
        YTLGViewOrAncestorContainsAny(
            view,
            @[
                @"comment",
                @"comments"
            ]
        );

    if (commentContext &&
        YTLGViewHasCompactActionGeometry(
            view,
            28.0,
            180.0) &&
        ([token containsString:@"sort"] ||
         [token containsString:@"filter"] ||
         [token containsString:@"send"] ||
         [token containsString:@"reply"] ||
         [token containsString:@"dislike"] ||
         [token containsString:@"like"])) {

        // Elements may repeat a button's accessibility label on nested
        // wrappers. Style one owner, preventing multiple stacked glass discs.
        for (UIView *parent = view.superview; parent && parent != view.window;
             parent = parent.superview) {
            if (CGRectGetHeight(parent.bounds) > 68 || CGRectGetWidth(parent.bounds) > 180) break;
            if (label.length && [YTLGTrimmedLowerLabel(parent) isEqualToString:label])
                return YTLGScopedSurfaceNone;
        }
        // Preserve the action's full hit area; size the visible glass below.
        return ([token containsString:@"like"] ||
                [token containsString:@"dislike"] ||
                [token containsString:@"reply"] ||
                [token containsString:@"send"])
            ? YTLGScopedSurfaceCompactCircle
            : YTLGScopedSurfaceRegular;
    }

    // ---- Search filter button ----
    //
    // This is purposely NOT the large "Search filters" header from our failed
    // broad-pill experiment. Only compact controls inside Search qualify.
    BOOL searchContext =
        YTLGViewOrAncestorContainsAny(
            view,
            @[
                @"search"
            ]
        );

    if (searchContext &&
        YTLGViewHasCompactActionGeometry(
            view,
            28.0,
            180.0) &&
        ([token containsString:@"filter"] ||
         [label isEqualToString:@"filter"])) {

        return
            CGRectGetWidth(view.bounds) <= 56.0
                ? YTLGScopedSurfaceCompactCircle
                : YTLGScopedSurfaceRegular;
    }

    // ---- Create/upload action rows fallback ----
    //
    // Ordinary YouTube action-sheet based create menus are already translated
    // to native UIMenu/UIAction by YTLiquidGlassNativeActionMenus. This catches
    // newer Elements-backed create rows only when they are clearly inside a
    // creation flow.
    BOOL createContext =
        YTLGViewOrAncestorContainsAny(
            view,
            @[
                @"create",
                @"creation",
                @"upload"
            ]
        );

    if (createContext &&
        YTLGViewHasCompactActionGeometry(
            view,
            44.0,
            320.0) &&
        ([label containsString:@"upload"] ||
         [label containsString:@"create"] ||
         [label containsString:@"go live"] ||
         [label containsString:@"post"])) {

        return YTLGScopedSurfaceRegular;
    }

    return YTLGScopedSurfaceNone;
}

static UIVisualEffectView *
YTLGScopedGlassView(
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
                    YTLGScopedGlassEffect(
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

        objc_setAssociatedObject(
            owner,
            key,
            glass,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }

    if (glass.superview != owner) {
        [glass removeFromSuperview];
        [owner insertSubview:glass
                     atIndex:0];
    } else {
        [owner sendSubviewToBack:glass];
    }

    if (@available(iOS 26.0, *)) {
        if ([glass.effect
                isKindOfClass:
                    NSClassFromString(@"UIGlassEffect")]) {

            UIGlassEffect *effect =
                (UIGlassEffect *)glass.effect;

            effect.tintColor =
                prominent
                    ? [UIColor.labelColor
                        colorWithAlphaComponent:0.10]
                    : nil;
        }
    }

    return glass;
}

static void
YTLGHideScopedGlassIfPresent(
    UIView *owner,
    const void *key
) {
    UIVisualEffectView *glass =
        objc_getAssociatedObject(
            owner,
            key
        );

    if (glass) {
        glass.hidden = YES;
    }
}

// Measure rendered icon/text together so a like count stays inside its pill.
static CGRect YTLGCommentContentBounds(UIView *view, UIView *root, NSUInteger depth) {
    if (!view || depth > 6 || view.hidden || view.alpha <= 0.01 ||
        [view.accessibilityIdentifier hasPrefix:@"YTLiquidGlass."]) return CGRectNull;
    if (view != root && ([view isKindOfClass:UILabel.class] ||
                        [view isKindOfClass:UIImageView.class])) {
        return [view convertRect:view.bounds toView:root];
    }
    CGRect result = CGRectNull;
    for (UIView *child in view.subviews)
        result = CGRectUnion(result, YTLGCommentContentBounds(child, root, depth + 1));
    // Texture/Elements often draws glyphs without UIImageView/UILabel.
    if (CGRectIsNull(result) && view != root && view.subviews.count == 0 &&
        CGRectGetWidth(view.bounds) >= 6 && CGRectGetWidth(view.bounds) <= 80 &&
        CGRectGetHeight(view.bounds) >= 10 && CGRectGetHeight(view.bounds) <= 28)
        return [view convertRect:view.bounds toView:root];
    return result;
}

static void
YTLGApplyScopedElementsGlass(
    UIView *view
) {
    YTLGScopedSurfaceKind kind =
        YTLGScopedSurfaceKindForElementsView(
            view
        );

    if (kind == YTLGScopedSurfaceNone) {
        YTLGHideScopedGlassIfPresent(
            view,
            kYTLGScopedElementGlassKey
        );
        return;
    }

    BOOL prominent =
        kind ==
            YTLGScopedSurfaceProminent;

    UIVisualEffectView *glass =
        YTLGScopedGlassView(
            view,
            kYTLGScopedElementGlassKey,
            prominent,
            @"YTLiquidGlass.ScopedElement"
        );

    glass.hidden = NO;

    CGRect bounds =
        view.bounds;

    BOOL commentControl = YTLGViewOrAncestorContainsAny(view, @[@"comment"]);
    if (commentControl) {
        CGRect content = YTLGCommentContentBounds(view, view, 0);
        if (CGRectIsNull(content) || CGRectIsEmpty(content)) {
            // Some Elements nodes draw directly into their layer. Include the
            // complete control width rather than centering a disc over a count.
            content = CGRectInset(bounds, 4, MAX(0, (CGRectGetHeight(bounds)-20)/2));
        }
        CGFloat h = MIN(26, CGRectGetHeight(bounds));
        CGFloat w = MIN(CGRectGetWidth(bounds), MAX(h, CGRectGetWidth(content)+10));
        CGFloat x = MAX(CGRectGetMinX(bounds), MIN(CGRectGetMidX(content)-w/2,
                                                 CGRectGetMaxX(bounds)-w));
        glass.frame = CGRectMake(x, CGRectGetMidY(bounds)-h/2, w, h);
        glass.layer.cornerRadius = h/2;
    } else if (kind ==
        YTLGScopedSurfaceCompactCircle) {

        CGFloat side = MIN(42.0,
                           MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds)));

        glass.frame =
            CGRectMake(
                CGRectGetMidX(bounds) -
                    side * 0.5,
                CGRectGetMidY(bounds) -
                    side * 0.5,
                side,
                side
            );

        glass.layer.cornerRadius =
            side * 0.5;
    } else {
        CGRect frame =
            CGRectInset(
                bounds,
                0.5,
                1.0
            );

        glass.frame = frame;
        glass.layer.cornerRadius =
            CGRectGetHeight(frame) *
            0.5;
    }

    view.opaque = NO;
    view.backgroundColor =
        UIColor.clearColor;
    view.layer.backgroundColor =
        UIColor.clearColor.CGColor;

    [view sendSubviewToBack:glass];
}

static void YTLGObserveElementsSurfaces(UIView *view);

%group YTLiquidGlassScopedElements

%hook _ASDisplayView

- (void)layoutSubviews {
    %orig;

    YTLGApplyScopedElementsGlass(
        self
    );
    YTLGObserveElementsSurfaces(self);
}

- (void)didMoveToWindow {
    %orig;

    if (self.window) {
        dispatch_async(
            dispatch_get_main_queue(),
            ^{
                if (self.window) {
                    YTLGApplyScopedElementsGlass(
                        self
                    );
                }
            }
        );
    }
}

- (void)setAccessibilityIdentifier:
    (NSString *)identifier {

    %orig(identifier);

    if (self.window) {
        YTLGApplyScopedElementsGlass(
            self
        );
    }
}

- (void)setAccessibilityLabel:
    (NSString *)label {

    %orig(label);

    if (self.window) {
        YTLGApplyScopedElementsGlass(
            self
        );
    }
}

%end

%end


#pragma mark - Native secondary navigation (UIKit owns selection and tracking)

static const void *kYTLGNativeRailKey = &kYTLGNativeRailKey;
static const void *kYTLGSurfaceGlassKey = &kYTLGSurfaceGlassKey;
static const void *kYTLGSurfaceColorsKey = &kYTLGSurfaceColorsKey;

static BOOL YTLGIsOurView(UIView *view) {
    return [view.accessibilityIdentifier hasPrefix:@"YTLiquidGlass."];
}

static NSString *YTLGRailTitle(UIView *view, NSUInteger depth) {
    if (!view || depth > 5 || YTLGIsOurView(view)) return nil;
    if ([view isKindOfClass:UILabel.class]) {
        NSString *text = ((UILabel *)view).text;
        if (text.length) return text;
    }
    if ([view isKindOfClass:UIButton.class]) {
        NSString *text = ((UIButton *)view).currentTitle;
        if (text.length) return text;
    }
    for (UIView *child in view.subviews) {
        NSString *text = YTLGRailTitle(child, depth + 1);
        if (text.length) return text;
    }
    NSString *label = view.accessibilityLabel;
    return label.length && label.length < 80 ? label : nil;
}

static UIControl *YTLGRailActionControl(UIView *view) {
    if (!view || YTLGIsOurView(view)) return nil;
    if ([view isKindOfClass:UIControl.class]) {
        UIControl *control = (UIControl *)view;
        if ((control.allControlEvents & (UIControlEventTouchUpInside |
                UIControlEventPrimaryActionTriggered | UIControlEventValueChanged)) != 0)
            return control;
    }
    for (UIView *child in view.subviews) {
        UIControl *control = YTLGRailActionControl(child);
        if (control) return control;
    }
    return nil;
}

static BOOL YTLGSourceSelected(UIView *view, NSUInteger depth) {
    if (!view || depth > 4 || YTLGIsOurView(view)) return NO;
    if ((view.accessibilityTraits & UIAccessibilityTraitSelected) != 0) return YES;
    if ([view isKindOfClass:UIControl.class] && ((UIControl *)view).selected) return YES;
    if ([view isKindOfClass:UICollectionViewCell.class] &&
        ((UICollectionViewCell *)view).selected) return YES;
    for (UIView *child in view.subviews)
        if (YTLGSourceSelected(child, depth + 1)) return YES;
    return NO;
}

static UICollectionView *YTLGRailCollection(UIView *view) {
    for (UIView *v = view; v; v = v.superview)
        if ([v isKindOfClass:UICollectionView.class]) return (UICollectionView *)v;
    return nil;
}

@interface YTLGNativeSecondaryRail : UISegmentedControl
@property(nonatomic, weak) UIView *sourceRoot;
@property(nonatomic, weak) UICollectionView *sourceCollection;
@property(nonatomic, copy) NSArray<UIView *> *sourceViews;
@property(nonatomic, copy) NSArray<NSIndexPath *> *sourcePaths;
@property(nonatomic, copy) NSArray<NSString *> *sourceTitles;
@property(nonatomic, strong) NSMapTable<UIView *, NSNumber *> *suppressedViews;
@property(nonatomic, strong) NSMapTable<CALayer *, NSNumber *> *suppressedLayers;
@property(nonatomic, assign) CFTimeInterval pendingUntil;
- (void)restoreSources;
- (void)suppress:(UIView *)view;
- (void)selectionChanged;
@end

@implementation YTLGNativeSecondaryRail
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.accessibilityIdentifier = @"YTLiquidGlass.NativeSecondaryRail";
        self.apportionsSegmentWidthsByContent = YES;
        self.suppressedViews = [NSMapTable weakToStrongObjectsMapTable];
        self.suppressedLayers = [NSMapTable weakToStrongObjectsMapTable];
        [self addTarget:self action:@selector(selectionChanged)
            forControlEvents:UIControlEventValueChanged];
        // Leave background/selected tint images unset: UIKit supplies the
        // system material, selection lens and touch/drag tracking.
    }
    return self;
}
- (void)suppress:(UIView *)view {
    if (!view || view == self || YTLGIsOurView(view)) return;
    if (![self.suppressedViews objectForKey:view])
        [self.suppressedViews setObject:@(view.alpha) forKey:view];
    view.alpha = 0;
}
- (void)restoreSources {
    for (UIView *view in self.suppressedViews.keyEnumerator)
        view.alpha = [[self.suppressedViews objectForKey:view] doubleValue];
    [self.suppressedViews removeAllObjects];
    for (CALayer *layer in self.suppressedLayers.keyEnumerator)
        layer.opacity = [[self.suppressedLayers objectForKey:layer] floatValue];
    [self.suppressedLayers removeAllObjects];
}
- (void)selectionChanged {
    NSInteger index = self.selectedSegmentIndex;
    if (index < 0 || index >= (NSInteger)self.sourceViews.count) return;
    UIView *source = self.sourceViews[index];
    BOOL sent = NO;
    self.pendingUntil = CACurrentMediaTime() + 0.45;
    // Collection delegates are the source of truth for chip selection; a
    // reusable cell's index is captured when the native segments are built.
    UICollectionView *collection = self.sourceCollection;
    if (collection && index < (NSInteger)self.sourcePaths.count) {
        NSIndexPath *path = self.sourcePaths[index];
        id<UICollectionViewDelegate> delegate = collection.delegate;
        if (path.section < [collection numberOfSections] &&
            path.item < [collection numberOfItemsInSection:path.section] &&
            [delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
            BOOL allowed = ![delegate respondsToSelector:@selector(collectionView:shouldSelectItemAtIndexPath:)] ||
                [delegate collectionView:collection shouldSelectItemAtIndexPath:path];
            if (allowed) {
                [collection selectItemAtIndexPath:path animated:NO
                    scrollPosition:UICollectionViewScrollPositionNone];
                [delegate collectionView:collection didSelectItemAtIndexPath:path];
                sent = YES;
            }
        }
    } else {
        UIControl *control = YTLGRailActionControl(source);
        if (control) {
            UIControlEvents events = control.allControlEvents;
            UIControlEvents event = (events & UIControlEventTouchUpInside)
                ? UIControlEventTouchUpInside : ((events & UIControlEventPrimaryActionTriggered)
                ? UIControlEventPrimaryActionTriggered : UIControlEventValueChanged);
            [control sendActionsForControlEvents:event];
            sent = YES;
        } else {
            sent = [source accessibilityActivate];
        }
    }
    if (!sent) {
        // A changed YouTube hierarchy must leave the original controls usable.
        [self restoreSources];
        self.hidden = YES;
    }
    __weak UIView *root = self.sourceRoot;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ [root setNeedsLayout]; });
}
@end

static void YTLGCollectTabSources(UIView *view, NSMutableArray<UIView *> *items) {
    if (!view || YTLGIsOurView(view) || view.hidden) return;
    if ([NSStringFromClass(view.class) containsString:@"YTTabButton"] &&
        !CGRectIsEmpty(view.bounds)) { [items addObject:view]; return; }
    for (UIView *child in view.subviews) YTLGCollectTabSources(child, items);
}

// YouTube sometimes leaves isSelected on Home while moving its underline.
// Read the real indicator geometry before removing that duplicate chrome.
static void YTLGCollectIndicators(UIView *view, UIView *root,
                                NSMutableArray<UIView *> *indicators) {
    if (!view || YTLGIsOurView(view) || view.hidden) return;
    CGFloat height = CGRectGetHeight(view.bounds), width = CGRectGetWidth(view.bounds);
    NSString *token = NSStringFromClass(view.class).lowercaseString;
    BOOL named = [token containsString:@"indicator"] || [token containsString:@"underline"];
    BOOL thin = height > 0 && height <= 4 && width >= 8 &&
        width < CGRectGetWidth(root.bounds) * 0.85;
    if (view != root && thin && (named || (view.backgroundColor && CGColorGetAlpha(view.backgroundColor.CGColor) > 0.05)))
        [indicators addObject:view];
    for (UIView *child in view.subviews) YTLGCollectIndicators(child, root, indicators);
}

static void YTLGCollectIndicatorLayers(UIView *view, UIView *root,
                                      NSMutableArray<CALayer *> *layers) {
    if (YTLGIsOurView(view) || view.hidden) return;
    for (CALayer *layer in view.layer.sublayers) {
        if ([layer.delegate isKindOfClass:UIView.class] || layer.hidden) continue;
        CGFloat w = CGRectGetWidth(layer.bounds), h = CGRectGetHeight(layer.bounds);
        NSString *name = layer.name.lowercaseString;
        BOOL named = [name containsString:@"indicator"] || [name containsString:@"underline"];
        BOOL colored = layer.backgroundColor && CGColorGetAlpha(layer.backgroundColor) > 0.05;
        if (h > 0 && h <= 4 && w >= 8 && w < CGRectGetWidth(root.bounds)*0.85 && (named || colored))
            [layers addObject:layer];
    }
    for (UIView *child in view.subviews) YTLGCollectIndicatorLayers(child, root, layers);
}

static void YTLGUpdateNativeRailNow(UIView *root, NSArray<UIView *> *sources,
                               UICollectionView *collection) {
    YTLGNativeSecondaryRail *rail = objc_getAssociatedObject(root, kYTLGNativeRailKey);
    if (!root.window || CGRectIsEmpty(root.bounds)) return;
    if (rail.tracking) return;
    if (sources.count < 2) {
        [rail restoreSources]; rail.hidden = YES; return;
    }
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableArray<NSIndexPath *> *paths = [NSMutableArray array];
    CGRect unionFrame = CGRectNull;
    NSInteger selected = UISegmentedControlNoSegment;
    for (UIView *source in sources) {
        NSString *title = YTLGRailTitle(source, 0);
        if (!title.length) { [rail restoreSources]; rail.hidden = YES; return; }
        [titles addObject:title];
        unionFrame = CGRectUnion(unionFrame, [source convertRect:source.bounds toView:root]);
        if (YTLGSourceSelected(source, 0)) selected = titles.count - 1;
        if (collection) {
            NSIndexPath *path = [source isKindOfClass:UICollectionViewCell.class]
                ? [collection indexPathForCell:(UICollectionViewCell *)source] : nil;
            if (!path) { [rail restoreSources]; rail.hidden = YES; return; }
            [paths addObject:path];
        } else if (!YTLGRailActionControl(source) &&
            class_getMethodImplementation(source.class, @selector(accessibilityActivate)) ==
            class_getMethodImplementation(UIView.class, @selector(accessibilityActivate))) {
            [rail restoreSources]; rail.hidden = YES; return;
        }
    }
    NSMutableArray<UIView *> *indicators = [NSMutableArray array];
    NSMutableArray<CALayer *> *indicatorLayers = [NSMutableArray array];
    if (!collection) {
        YTLGCollectIndicatorLayers(root, root, indicatorLayers);
        YTLGCollectIndicators(root, root, indicators);
        for (UIView *indicator in indicators) {
            CGRect line = [indicator convertRect:indicator.bounds toView:root];
            CGFloat nearest = CGFLOAT_MAX;
            for (NSUInteger i = 0; i < sources.count; i++) {
                CGRect f = [sources[i] convertRect:sources[i].bounds toView:root];
                CGFloat distance = fabs(CGRectGetMidX(line) - CGRectGetMidX(f));
                if (distance < nearest) { nearest = distance; selected = i; }
            }
            if (selected != UISegmentedControlNoSegment) break;
        }
    }
    if (indicatorLayers.count && !indicators.count) {
        CALayer *lineLayer = indicatorLayers.firstObject;
        CGRect line = [lineLayer convertRect:lineLayer.bounds toLayer:root.layer];
        CGFloat nearest = CGFLOAT_MAX;
        for (NSUInteger i = 0; i < sources.count; i++) {
            CGRect f = [sources[i] convertRect:sources[i].bounds toView:root];
            CGFloat distance = fabs(CGRectGetMidX(line) - CGRectGetMidX(f));
            if (distance < nearest) { nearest = distance; selected = i; }
        }
    }
    if (!rail) {
        rail = [[YTLGNativeSecondaryRail alloc] initWithFrame:CGRectZero];
        rail.sourceRoot = root;
        [root addSubview:rail];
        objc_setAssociatedObject(root, kYTLGNativeRailKey, rail, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL changed = ![rail.sourceTitles isEqualToArray:titles];
    [rail restoreSources];
    rail.sourceViews = sources; rail.sourcePaths = paths; rail.sourceCollection = collection;
    if (changed) {
        [rail removeAllSegments];
        for (NSUInteger i = 0; i < titles.count; i++)
            [rail insertSegmentWithTitle:titles[i] atIndex:i animated:NO];
        rail.sourceTitles = titles;
    }
    if (changed || CACurrentMediaTime() >= rail.pendingUntil)
        rail.selectedSegmentIndex = selected;
    CGFloat height = MIN(36.0, CGRectGetHeight(root.bounds) - 4.0);
    if (height < 24.0) { rail.hidden = YES; return; }
    // A collection owns its scrolling/content coordinates. Its visible cells
    // become a native segment strip; offscreen cells are never dequeued by us.
    CGRect frame = CGRectMake(CGRectGetMinX(unionFrame),
        CGRectGetMidY(unionFrame) - height / 2.0, CGRectGetWidth(unionFrame), height);
    if (!collection) {
        frame.origin.x = MAX(CGRectGetMinX(root.bounds) + 4, frame.origin.x);
        frame.size.width = MIN(frame.size.width, CGRectGetMaxX(root.bounds) - frame.origin.x - 4);
    }
    if (!CGRectEqualToRect(rail.frame, frame)) rail.frame = frame;
    for (NSUInteger i = 0; i < sources.count; i++) {
        CGRect f = [sources[i] convertRect:sources[i].bounds toView:root];
        // Preserve each source's geometry in the virtualized collection.
        if (collection) [rail setWidth:CGRectGetWidth(f) forSegmentAtIndex:i];
        UIControl *action = collection ? nil : YTLGRailActionControl(sources[i]);
        BOOL enabled = action ? action.enabled :
            ((sources[i].accessibilityTraits & UIAccessibilityTraitNotEnabled) == 0);
        [rail setEnabled:enabled forSegmentAtIndex:i];
        [rail suppress:sources[i]];
    }
    for (UIView *indicator in indicators) [rail suppress:indicator];
    for (CALayer *layer in indicatorLayers) {
        [rail.suppressedLayers setObject:@(layer.opacity) forKey:layer];
        layer.opacity = 0;
    }
    rail.hidden = NO;
    root.opaque = NO; root.backgroundColor = UIColor.clearColor;
    [root bringSubviewToFront:rail];
}

static const void *kYTLGNativeRailUpdatingKey = &kYTLGNativeRailUpdatingKey;
static void YTLGUpdateNativeRail(UIView *root, NSArray<UIView *> *sources,
                               UICollectionView *collection) {
    if (!root || [objc_getAssociatedObject(root, kYTLGNativeRailUpdatingKey) boolValue]) return;
    objc_setAssociatedObject(root, kYTLGNativeRailUpdatingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try { YTLGUpdateNativeRailNow(root, sources, collection); }
    @finally { objc_setAssociatedObject(root, kYTLGNativeRailUpdatingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
}

static void YTLGUpdateTopTabTitlesGlass(UIView *root) {
    NSMutableArray<UIView *> *sources = [NSMutableArray array];
    YTLGCollectTabSources(root, sources);
    [sources sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ax = CGRectGetMinX([a convertRect:a.bounds toView:root]);
        CGFloat bx = CGRectGetMinX([b convertRect:b.bounds toView:root]);
        return ax < bx ? NSOrderedAscending : ax > bx ? NSOrderedDescending : NSOrderedSame;
    }];
    YTLGUpdateNativeRail(root, sources, nil);
}

static BOOL YTLGContainsLargeImage(UIView *view, NSUInteger depth) {
    if (depth > 5 || YTLGIsOurView(view)) return NO;
    if ([view isKindOfClass:UIImageView.class] &&
        CGRectGetWidth(view.bounds) > 30 && CGRectGetHeight(view.bounds) > 30) return YES;
    CGFloat w = CGRectGetWidth(view.bounds), h = CGRectGetHeight(view.bounds);
    // Texture also draws channel avatars into a layer without UIImageView.
    if (view.layer.contents && w > 40 && w <= 100 && h > 40 && h <= 100 && fabs(w-h) < 8)
        return YES;
    for (UIView *child in view.subviews)
        if (YTLGContainsLargeImage(child, depth + 1)) return YES;
    return NO;
}

static BOOL YTLGSubscriptionContext(UIView *view) {
    if (YTLGViewOrAncestorContainsAny(view,
            @[@"subscription", @"channelfilter", @"channel_filter"])) return YES;
    UIResponder *responder = view;
    for (NSUInteger depth = 0; responder && depth < 35; depth++, responder = responder.nextResponder) {
        NSString *name = NSStringFromClass(responder.class).lowercaseString;
        if ([name containsString:@"subscription"] || [name containsString:@"channelfilter"])
            return YES;
    }
    return NO;
}

static void YTLGResetNativeRail(UIView *root) {
    YTLGNativeSecondaryRail *rail = objc_getAssociatedObject(root, kYTLGNativeRailKey);
    [rail restoreSources]; rail.hidden = YES;
}

static void YTLGUpdateChipCollection(UICollectionView *collection, BOOL knownChip) {
    if (!collection.window || collection.hidden) return;
    CGFloat height = CGRectGetHeight(collection.bounds);
    if (height < 26 || height > 70) { YTLGResetNativeRail(collection); return; }
    BOOL context = knownChip || YTLGViewOrAncestorContainsAny(collection,
        @[@"chip", @"topic", @"feedfilter", @"feed_filter", @"subscription", @"channelfilter"]);
    context = context || YTLGSubscriptionContext(collection);
    NSArray<UICollectionViewCell *> *cells = [collection.visibleCells
        sortedArrayUsingComparator:^NSComparisonResult(UICollectionViewCell *a, UICollectionViewCell *b) {
            return [ [collection indexPathForCell:a] compare:[collection indexPathForCell:b] ];
        }];
    if (!context) {
        // Recent YouTube builds render the subscriptions chips in generic
        // Texture classes. Recognize the compact row from multiple labels.
        NSSet *filterTitles = [NSSet setWithArray:@[@"all", @"today", @"videos", @"shorts", @"live", @"podcasts"]];
        NSUInteger matches = 0;
        for (UIView *cell in cells)
            if ([filterTitles containsObject:(YTLGRailTitle(cell, 0).lowercaseString ?: @"")]) matches++;
        context = matches >= 3;
    }
    if (!context) { YTLGResetNativeRail(collection); return; }
    for (UIView *cell in cells) if (YTLGContainsLargeImage(cell, 0)) {
        YTLGResetNativeRail(collection); return;
    }
    if (![collection.delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
        YTLGResetNativeRail(collection); return;
    }
    YTLGUpdateNativeRail(collection, cells, collection);
}

// Clear only neutral surface fills. Images, text, controls and native material
// keep their own rendering. Store original colors so recycled views restore.
static BOOL YTLGNeutralSurface(UIColor *color) {
    CGFloat r, g, b, a;
    return color && [color getRed:&r green:&g blue:&b alpha:&a] && a > 0.5 &&
        fabs(r-g) < 0.035 && fabs(g-b) < 0.035;
}
static void YTLGClearSurfaceFills(UIView *view, UIView *root, NSUInteger depth,
                                NSMapTable<UIView *, UIColor *> *colors) {
    if (depth > 10 || YTLGIsOurView(view) || [view isKindOfClass:UIVisualEffectView.class] ||
        [view isKindOfClass:UIImageView.class] || [view isKindOfClass:UIControl.class]) return;
    if (view == root || (CGRectGetWidth(view.bounds) > CGRectGetWidth(root.bounds)*0.65 &&
                        CGRectGetHeight(view.bounds) > 24)) {
        if (YTLGNeutralSurface(view.backgroundColor)) {
            if (![colors objectForKey:view]) [colors setObject:view.backgroundColor forKey:view];
            view.backgroundColor = UIColor.clearColor;
        }
    }
    for (UIView *child in view.subviews) YTLGClearSurfaceFills(child, root, depth+1, colors);
}
static void YTLGRestoreSurface(UIView *view) {
    YTLGHideScopedGlassIfPresent(view, kYTLGSurfaceGlassKey);
    NSMapTable *colors = objc_getAssociatedObject(view, kYTLGSurfaceColorsKey);
    for (UIView *child in colors.keyEnumerator) child.backgroundColor = [colors objectForKey:child];
    [colors removeAllObjects];
}
static void YTLGApplyPanelGlass(UIView *view, CGFloat radius) {
    NSMapTable *colors = objc_getAssociatedObject(view, kYTLGSurfaceColorsKey);
    if (!colors) {
        colors = [NSMapTable weakToStrongObjectsMapTable];
        objc_setAssociatedObject(view, kYTLGSurfaceColorsKey, colors, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    YTLGClearSurfaceFills(view, view, 0, colors);
    UIVisualEffectView *glass = YTLGScopedGlassView(view, kYTLGSurfaceGlassKey,
        NO, @"YTLiquidGlass.CommentsOrSubscriptionSurface");
    glass.frame = view.bounds; glass.layer.cornerRadius = radius; glass.hidden = NO;
    [view sendSubviewToBack:glass];
}

static void YTLGUpdateSubscriptionFilterHeaderGlass(UIView *header) {
    if (!header.window || CGRectGetHeight(header.bounds) < 55 ||
        CGRectGetHeight(header.bounds) > 240) return;
    YTLGApplyPanelGlass(header, 20);
}

static BOOL YTLGHasCommentsHeading(UIView *view, NSUInteger depth) {
    if (depth > 4 || YTLGIsOurView(view)) return NO;
    NSString *text = [view isKindOfClass:UILabel.class] ? ((UILabel *)view).text : view.accessibilityLabel;
    if ([text.lowercaseString hasPrefix:@"comments"]) return YES;
    for (UIView *child in view.subviews)
        if (YTLGHasCommentsHeading(child, depth + 1)) return YES;
    return NO;
}

static void YTLGObserveElementsSurfaces(UIView *view) {
    if (!view.window) return;
    CGFloat w = CGRectGetWidth(view.bounds), h = CGRectGetHeight(view.bounds);
    NSString *token = YTLGNormalizedViewToken(view);
    BOOL commentCard = w > CGRectGetWidth(view.window.bounds)*0.65 && h >= 48 && h <= 180 &&
        (([token containsString:@"comment"] &&
          ([token containsString:@"teaser"] || [token containsString:@"entry"] ||
           [token containsString:@"preview"] || [token containsString:@"carousel"])) ||
         YTLGHasCommentsHeading(view, 0));
    if (commentCard) {
        // Prefer one enclosing preview card over nested header/text wrappers.
        UIView *parent = view.superview;
        for (NSUInteger depth = 0; parent && depth < 3; depth++, parent = parent.superview) {
            CGFloat ph = CGRectGetHeight(parent.bounds);
            if (ph > 180) break;
            if (ph >= h && CGRectGetWidth(parent.bounds) >= w &&
                [parent isKindOfClass:NSClassFromString(@"_ASDisplayView")] &&
                YTLGHasCommentsHeading(parent, 0)) { commentCard = NO; break; }
        }
    }
    if (commentCard) YTLGApplyPanelGlass(view, MAX(16, view.layer.cornerRadius));
    else if (objc_getAssociatedObject(view, kYTLGSurfaceGlassKey)) YTLGRestoreSurface(view);
    if ([token containsString:@"chip"] || [token containsString:@"filter_chip"]) {
        UICollectionView *collection = YTLGRailCollection(view);
        if (collection) YTLGUpdateChipCollection(collection, YES);
    }
}

%group YTLiquidGlassTopTabTitles
%hook YTTabTitlesView
- (void)layoutSubviews { %orig; YTLGUpdateTopTabTitlesGlass(self); }
- (void)didMoveToWindow { %orig; if (self.window) [self setNeedsLayout]; }
%end
%end

%group YTLiquidGlassTopicRail
%hook YTChipCloudCell
- (void)layoutSubviews { %orig; YTLGUpdateChipCollection(YTLGRailCollection(self), YES); }
- (void)didMoveToWindow { %orig; if (self.window) [self setNeedsLayout]; }
%end
%end

%group YTLiquidGlassSubscriptionFilterHeader
%hook YTFeedChannelFilterHeaderView
- (void)layoutSubviews { %orig; YTLGUpdateSubscriptionFilterHeaderGlass(self); }
%end
%end

%group YTLiquidGlassSurfaceDiscovery
%hook UICollectionView
- (void)layoutSubviews {
    %orig;
    YTLGUpdateChipCollection(self, NO);
    CGFloat height = CGRectGetHeight(self.bounds);
    BOOL avatars = NO;
    if (self.window && height >= 70 && height <= 180) {
        NSUInteger images = 0;
        CGFloat minY = CGFLOAT_MAX, maxY = -CGFLOAT_MAX;
        for (UIView *cell in self.visibleCells) {
            if (YTLGContainsLargeImage(cell, 0)) images++;
            minY = MIN(minY, CGRectGetMidY(cell.frame));
            maxY = MAX(maxY, CGRectGetMidY(cell.frame));
        }
        CGRect onScreen = [self convertRect:self.bounds toView:self.window];
        BOOL topAvatarRow = images >= 3 && maxY-minY < 20 &&
            CGRectGetWidth(self.bounds) > CGRectGetWidth(self.window.bounds)*0.7 &&
            CGRectGetMinY(onScreen) >= 0 &&
            CGRectGetMinY(onScreen) < CGRectGetHeight(self.window.bounds)*0.4;
        avatars = (images >= 2 && YTLGSubscriptionContext(self)) || topAvatarRow;
    }
    if (avatars) YTLGApplyPanelGlass(self, 20);
    else if (objc_getAssociatedObject(self, kYTLGSurfaceGlassKey)) YTLGRestoreSurface(self);
}
%end
%hook UIViewController
- (void)viewDidLayoutSubviews {
    %orig;
    NSString *name = NSStringFromClass(self.class).lowercaseString;
    BOOL comment = [name containsString:@"comment"];
    BOOL panel = [name containsString:@"engagementpanel"] || [name containsString:@"engagement_panel"];
    if ((!comment && !panel) || !self.isViewLoaded || !self.view.window) return;
    UIView *view = self.view;
    if (CGRectGetHeight(view.bounds) < 220 ||
        CGRectGetWidth(view.bounds) < CGRectGetWidth(view.window.bounds)*0.65) return;
    BOOL matches = comment || YTLGHasCommentsHeading(view, 0);
    // Apply once at the outermost matching controller, avoiding stacked glass.
    for (UIView *parent = view.superview; parent; parent = parent.superview) {
        UIVisualEffectView *ancestorGlass = objc_getAssociatedObject(parent, kYTLGSurfaceGlassKey);
        if (ancestorGlass && !ancestorGlass.hidden) { matches = NO; break; }
    }
    if (matches) YTLGApplyPanelGlass(view, 24);
    else if (objc_getAssociatedObject(view, kYTLGSurfaceGlassKey)) YTLGRestoreSurface(view);
}
%end
%end


#pragma mark - YTKACE settings standalone control glass

static BOOL
YTLGViewIsInsideTableCell(
    UIView *view
) {
    for (UIView *cursor = view.superview;
         cursor;
         cursor = cursor.superview) {

        if ([cursor
                isKindOfClass:
                    UITableViewCell.class] ||
            [cursor
                isKindOfClass:
                    UICollectionViewCell.class]) {

            return YES;
        }
    }

    return NO;
}

static void
YTLGApplyYTKACEButtonGlass(
    UIButton *button
) {
    if (!button ||
        !button.window ||
        button.hidden ||
        button.alpha <= 0.01 ||
        CGRectIsEmpty(button.bounds) ||
        YTLGViewIsInsideTableCell(button)) {
        return;
    }

    CGFloat width =
        CGRectGetWidth(
            button.bounds
        );

    CGFloat height =
        CGRectGetHeight(
            button.bounds
        );

    if (height < 28.0 ||
        height > 60.0 ||
        width < 28.0 ||
        width > 260.0) {
        return;
    }

    UIVisualEffectView *glass =
        YTLGScopedGlassView(
            button,
            kYTLGYTKACEControlGlassKey,
            NO,
            @"YTLiquidGlass.YTKACEControl"
        );

    glass.hidden = NO;
    glass.frame =
        button.bounds;

    glass.layer.cornerRadius =
        width <= height * 1.25
            ? MIN(width, height) * 0.5
            : height * 0.5;

    button.opaque = NO;
    button.backgroundColor =
        UIColor.clearColor;

    [button sendSubviewToBack:glass];
}

static void
YTLGStyleYTKACEStandaloneControls(
    UIView *root
) {
    if (!root) return;

    NSMutableArray<UIView *> *stack =
        [NSMutableArray
            arrayWithObject:root];

    NSUInteger visited = 0;

    while (stack.count > 0 &&
           visited < 500) {

        UIView *view =
            stack.lastObject;

        [stack removeLastObject];
        visited++;

        if ([view
                isKindOfClass:
                    UIButton.class]) {

            YTLGApplyYTKACEButtonGlass(
                (UIButton *)view
            );
        }

        for (UIView *subview
                in view.subviews) {
            [stack addObject:subview];
        }
    }
}

%group YTLiquidGlassYTKACERootSettings

%hook YTKACERootOptionsController

- (void)viewDidLayoutSubviews {
    %orig;

    YTLGStyleYTKACEStandaloneControls(
        self.view
    );
}

%end

%end


%group YTLiquidGlassYTKACETabEditor

%hook YTKACETabEditorController

- (void)viewDidLayoutSubviews {
    %orig;

    YTLGStyleYTKACEStandaloneControls(
        self.view
    );
}

%end

%end


%group YTLiquidGlassYTKACESearchOverlay

%hook YTKACESearchOverlayController

- (void)viewDidLayoutSubviews {
    %orig;

    YTLGStyleYTKACEStandaloneControls(
        self.view
    );
}

%end

%end


%ctor {
    if (@available(iOS 26.0, *)) {
        %init(YTLiquidGlassSurfaceDiscovery);
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
            NSClassFromString(@"_ASDisplayView")) {

            %init(YTLiquidGlassScopedElements);
        }

        if (NSClassFromString(@"UIGlassEffect") &&
            NSClassFromString(@"YTChipCloudCell")) {

            %init(YTLiquidGlassTopicRail);
        }

        if (NSClassFromString(@"UIGlassEffect") &&
            NSClassFromString(@"YTTabTitlesView")) {

            %init(YTLiquidGlassTopTabTitles);
        }

        if (NSClassFromString(@"UIGlassEffect") &&
            NSClassFromString(@"YTFeedChannelFilterHeaderView")) {

            %init(YTLiquidGlassSubscriptionFilterHeader);
        }

        if (NSClassFromString(@"UIGlassEffect") &&
            NSClassFromString(@"YTKACERootOptionsController")) {

            %init(YTLiquidGlassYTKACERootSettings);
        }

        if (NSClassFromString(@"UIGlassEffect") &&
            NSClassFromString(@"YTKACETabEditorController")) {

            %init(YTLiquidGlassYTKACETabEditor);
        }

        if (NSClassFromString(@"UIGlassEffect") &&
            NSClassFromString(@"YTKACESearchOverlayController")) {

            %init(YTLiquidGlassYTKACESearchOverlay);
        }
    }
}
