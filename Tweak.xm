#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// YTLiquidGlass v0.3
//
// Robust floating Liquid Glass presentation for YouTube/YTLite's pivot bar.
//
// IMPORTANT:
// This tweak never replaces YouTube/YTLite's tab model, controller,
// identifiers, actions, order, or custom-tab logic. It only styles the
// existing runtime tab views.
//
// v0.3 deliberately keeps UIGlassEffect views directly inside YTPivotBarView.
// This avoids the extra UIGlassContainerEffect compositor layer that could
// prevent the glass hierarchy from appearing on some YouTube/iOS builds.

@interface YTIPivotBarItemRenderer : NSObject
@property(nonatomic, copy, readonly) NSString *pivotIdentifier;
@end

@interface YTPivotBarViewController : UIViewController
@property(nonatomic, copy, readonly) NSString *selectedPivotIdentifier;
- (UIView *)pivotBarView;
- (void)selectItemWithPivotIdentifier:(id)identifier;
@end

@interface YTPivotBarView : UIView
- (void)selectItemWithPivotIdentifier:(id)identifier;
@end

@interface YTPivotBarItemView : UIView
@property(nonatomic, strong, readonly) YTIPivotBarItemRenderer *renderer;
@property(nonatomic, weak, readonly) YTPivotBarViewController *delegate;
@end

static const void *kYTLGBackgroundKey = &kYTLGBackgroundKey;
static const void *kYTLGLensKey = &kYTLGLensKey;

#pragma mark - Glass

static UIVisualEffect *YTLGGlassEffect(BOOL selectedLens) {
    if (@available(iOS 26.0, *)) {
        Class glassClass = NSClassFromString(@"UIGlassEffect");

        if (glassClass &&
            [glassClass respondsToSelector:@selector(effectWithStyle:)]) {

            // Use regular glass for both elements so the material remains
            // clearly visible on YouTube's dark and video-backed surfaces.
            UIGlassEffect *effect =
                [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];

            effect.interactive = NO;

            if (selectedLens) {
                // Stronger selected lens, similar to native floating controls.
                effect.tintColor =
                    [UIColor.blackColor colorWithAlphaComponent:0.18];
            }

            return effect;
        }
    }

    return [UIBlurEffect
        effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
}

static void YTLGPrepareGlassView(UIVisualEffectView *view) {
    view.userInteractionEnabled = NO;
    view.opaque = NO;
    view.backgroundColor = UIColor.clearColor;
    view.clipsToBounds = YES;
    view.layer.cornerCurve = kCACornerCurveContinuous;
}

static UIVisualEffectView *YTLGBackgroundGlass(YTPivotBarView *bar) {
    UIVisualEffectView *glass =
        objc_getAssociatedObject(bar, kYTLGBackgroundKey);

    if (!glass) {
        glass = [[UIVisualEffectView alloc]
            initWithEffect:YTLGGlassEffect(NO)];

        YTLGPrepareGlassView(glass);

        glass.accessibilityIdentifier =
            @"YTLiquidGlass.FloatingTabBar";

        [bar addSubview:glass];

        objc_setAssociatedObject(
            bar,
            kYTLGBackgroundKey,
            glass,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }

    return glass;
}

static UIVisualEffectView *YTLGSelectionLens(YTPivotBarView *bar) {
    UIVisualEffectView *lens =
        objc_getAssociatedObject(bar, kYTLGLensKey);

    if (!lens) {
        lens = [[UIVisualEffectView alloc]
            initWithEffect:YTLGGlassEffect(YES)];

        YTLGPrepareGlassView(lens);

        lens.hidden = YES;
        lens.accessibilityIdentifier =
            @"YTLiquidGlass.SelectedLens";

        [bar addSubview:lens];

        objc_setAssociatedObject(
            bar,
            kYTLGLensKey,
            lens,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }

    return lens;
}

#pragma mark - Runtime tab discovery

static BOOL YTLGItemIsSelected(YTPivotBarItemView *item) {
    if (!item) return NO;

    NSString *itemIdentifier = item.renderer.pivotIdentifier;
    NSString *selectedIdentifier =
        item.delegate.selectedPivotIdentifier;

    if (itemIdentifier.length == 0 ||
        selectedIdentifier.length == 0) {
        return NO;
    }

    return [itemIdentifier
        isEqualToString:selectedIdentifier];
}

static void YTLGCollectItems(
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
        NSString *identifier =
            subview.accessibilityIdentifier;

        if ([identifier hasPrefix:@"YTLiquidGlass."]) {
            continue;
        }

        YTLGCollectItems(subview, items);
    }
}

static NSArray<YTPivotBarItemView *> *
YTLGCurrentItems(YTPivotBarView *bar) {
    NSMutableArray<YTPivotBarItemView *> *items =
        [NSMutableArray array];

    YTLGCollectItems(bar, items);

    [items sortUsingComparator:
        ^NSComparisonResult(
            YTPivotBarItemView *a,
            YTPivotBarItemView *b
        ) {
            CGRect aFrame =
                [a convertRect:a.bounds toView:bar];

            CGRect bFrame =
                [b convertRect:b.bounds toView:bar];

            CGFloat aX = CGRectGetMidX(aFrame);
            CGFloat bX = CGRectGetMidX(bFrame);

            if (aX < bX) return NSOrderedAscending;
            if (aX > bX) return NSOrderedDescending;
            return NSOrderedSame;
        }];

    return items;
}

#pragma mark - Geometry

static CGRect YTLGCapsuleFrame(
    YTPivotBarView *bar,
    NSArray<YTPivotBarItemView *> *items
) {
    CGRect bounds = bar.bounds;

    // Approximate native floating-tab proportions:
    // ~20pt side inset on a 440pt-wide Pro Max screen,
    // ~60pt glass height.
    CGFloat sideInset =
        MAX(16.0, MIN(22.0, bounds.size.width * 0.045));

    CGFloat safeBottom = bar.safeAreaInsets.bottom;

    CGFloat usableHeight =
        bounds.size.height - safeBottom;

    if (usableHeight < 44.0) {
        usableHeight = bounds.size.height;
    }

    CGFloat height =
        MIN(62.0, MAX(54.0, usableHeight - 6.0));

    CGFloat centerY = usableHeight * 0.5;

    // If YouTube's actual items provide a more reliable vertical center,
    // follow them instead of assuming a fixed bar layout.
    if (items.count > 0) {
        CGFloat totalMidY = 0.0;
        NSUInteger validCount = 0;

        for (YTPivotBarItemView *item in items) {
            CGRect frame =
                [item convertRect:item.bounds toView:bar];

            if (!CGRectIsEmpty(frame)) {
                totalMidY += CGRectGetMidY(frame);
                validCount += 1;
            }
        }

        if (validCount > 0) {
            centerY = totalMidY / (CGFloat)validCount;
        }
    }

    CGFloat y = centerY - height * 0.5;

    y = MAX(2.0, y);

    if (y + height > bounds.size.height - 2.0) {
        y = MAX(2.0, bounds.size.height - height - 2.0);
    }

    return CGRectMake(
        sideInset,
        y,
        MAX(1.0, bounds.size.width - sideInset * 2.0),
        height
    );
}

static CGRect YTLGLensFrame(
    YTPivotBarView *bar,
    YTPivotBarItemView *item,
    CGRect capsuleFrame
) {
    CGRect itemFrame =
        [item convertRect:item.bounds toView:bar];

    CGFloat width =
        MAX(58.0, itemFrame.size.width - 8.0);

    // Do not allow an unusually wide custom tab title to consume
    // most of the floating capsule.
    width =
        MIN(width, capsuleFrame.size.width * 0.28);

    CGFloat height =
        MAX(46.0, capsuleFrame.size.height - 6.0);

    height =
        MIN(height, capsuleFrame.size.height - 2.0);

    CGFloat x =
        CGRectGetMidX(itemFrame) - width * 0.5;

    CGFloat y =
        CGRectGetMidY(capsuleFrame) - height * 0.5;

    CGFloat minX =
        CGRectGetMinX(capsuleFrame) + 3.0;

    CGFloat maxX =
        CGRectGetMaxX(capsuleFrame) - 3.0 - width;

    if (maxX < minX) {
        maxX = minX;
    }

    x = MIN(MAX(x, minX), maxX);

    return CGRectMake(x, y, width, height);
}

static BOOL YTLGFramesNearlyEqual(CGRect a, CGRect b) {
    const CGFloat epsilon = 0.5;

    return fabs(a.origin.x - b.origin.x) < epsilon &&
           fabs(a.origin.y - b.origin.y) < epsilon &&
           fabs(a.size.width - b.size.width) < epsilon &&
           fabs(a.size.height - b.size.height) < epsilon;
}

#pragma mark - Layer ordering / old chrome

static void YTLGClearBarChrome(YTPivotBarView *bar) {
    bar.opaque = NO;
    bar.backgroundColor = UIColor.clearColor;
    bar.layer.backgroundColor = UIColor.clearColor.CGColor;

    // Allow the capsule's natural rounded edge to remain visible.
    bar.clipsToBounds = NO;
    bar.layer.masksToBounds = NO;
}

static void YTLGPlaceGlassBehindItems(
    YTPivotBarView *bar,
    UIVisualEffectView *background,
    UIVisualEffectView *lens,
    NSArray<YTPivotBarItemView *> *items
) {
    // Bring the glass above YouTube's original background chrome so it cannot
    // disappear underneath a private full-width background subview.
    [bar bringSubviewToFront:background];
    [bar bringSubviewToFront:lens];

    // Then put every real tab item back above the glass. Touch handling and
    // all YTLite navigation behavior stay on the original item views.
    for (YTPivotBarItemView *item in items) {
        [bar bringSubviewToFront:item];
    }
}

#pragma mark - Update

static void YTLGUpdateGlass(
    YTPivotBarView *bar,
    BOOL animated
) {
    if (!bar ||
        CGRectIsEmpty(bar.bounds) ||
        !bar.window) {
        return;
    }

    YTLGClearBarChrome(bar);

    NSArray<YTPivotBarItemView *> *items =
        YTLGCurrentItems(bar);

    UIVisualEffectView *background =
        YTLGBackgroundGlass(bar);

    UIVisualEffectView *lens =
        YTLGSelectionLens(bar);

    CGRect capsuleFrame =
        YTLGCapsuleFrame(bar, items);

    background.frame = capsuleFrame;
    background.layer.cornerRadius =
        capsuleFrame.size.height * 0.5;

    YTPivotBarItemView *selectedItem = nil;

    for (YTPivotBarItemView *item in items) {
        item.opaque = NO;
        item.backgroundColor = UIColor.clearColor;

        if (YTLGItemIsSelected(item)) {
            selectedItem = item;
        }
    }

    YTLGPlaceGlassBehindItems(
        bar,
        background,
        lens,
        items
    );

    if (!selectedItem) {
        lens.hidden = YES;
        return;
    }

    CGRect target =
        YTLGLensFrame(
            bar,
            selectedItem,
            capsuleFrame
        );

    lens.layer.cornerRadius =
        target.size.height * 0.5;

    if (lens.hidden ||
        CGRectIsEmpty(lens.frame) ||
        !animated) {

        lens.hidden = NO;
        lens.frame = target;

        YTLGPlaceGlassBehindItems(
            bar,
            background,
            lens,
            items
        );

        return;
    }

    lens.hidden = NO;

    if (YTLGFramesNearlyEqual(
            lens.frame,
            target)) {
        return;
    }

    [UIView animateWithDuration:0.36
                          delay:0.0
         usingSpringWithDamping:0.86
          initialSpringVelocity:0.20
                        options:
                            UIViewAnimationOptionBeginFromCurrentState |
                            UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         lens.frame = target;
                         lens.layer.cornerRadius =
                             target.size.height * 0.5;
                     }
                     completion:^(BOOL finished) {
                         YTLGPlaceGlassBehindItems(
                             bar,
                             background,
                             lens,
                             YTLGCurrentItems(bar)
                         );
                     }];
}

static void YTLGRefreshSoon(
    YTPivotBarView *bar,
    BOOL animated
) {
    if (!bar) return;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            [bar setNeedsLayout];
            [bar layoutIfNeeded];
            YTLGUpdateGlass(bar, animated);
        }
    );
}

static void YTLGRefreshController(
    YTPivotBarViewController *controller,
    BOOL animated
) {
    UIView *barView =
        [controller pivotBarView];

    Class barClass =
        NSClassFromString(@"YTPivotBarView");

    if (!barView ||
        !barClass ||
        ![barView isKindOfClass:barClass]) {
        return;
    }

    YTLGRefreshSoon(
        (YTPivotBarView *)barView,
        animated
    );
}

#pragma mark - Hooks

%group YTLiquidGlass

%hook YTPivotBarView

- (void)layoutSubviews {
    %orig;

    YTLGUpdateGlass(self, NO);
}

- (void)didMoveToWindow {
    %orig;

    if (self.window) {
        YTLGRefreshSoon(self, NO);
    }
}

- (void)safeAreaInsetsDidChange {
    %orig;

    YTLGRefreshSoon(self, NO);
}

- (void)selectItemWithPivotIdentifier:(id)identifier {
    %orig(identifier);

    YTLGRefreshSoon(self, YES);
}

%end

%hook YTPivotBarItemView

- (void)didMoveToWindow {
    %orig;

    if (self.window) {
        self.opaque = NO;
        self.backgroundColor = UIColor.clearColor;
    }
}

%end

%hook YTPivotBarViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);

    YTLGRefreshController(self, NO);
}

- (void)selectItemWithPivotIdentifier:(id)identifier {
    %orig(identifier);

    YTLGRefreshController(self, YES);
}

%end

%end

%ctor {
    if (@available(iOS 26.0, *)) {
        // Do NOT require UIGlassContainerEffect here.
        // Only the glass API actually used by this implementation is required.
        if (NSClassFromString(@"UIGlassEffect") &&
            NSClassFromString(@"YTPivotBarView") &&
            NSClassFromString(@"YTPivotBarItemView") &&
            NSClassFromString(@"YTPivotBarViewController")) {

            %init(YTLiquidGlass);
        }
    }
}
