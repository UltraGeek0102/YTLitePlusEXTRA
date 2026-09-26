#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// YTLiquidGlass v0.2
//
// Visual-only integration for YouTube/YTLite's existing pivot bar.
// YTLite/YouTube remain the source of truth for:
//   - active tabs
//   - tab order
//   - custom tabs
//   - selection
//   - navigation/actions
//
// This tweak only supplies the floating Liquid Glass presentation.

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

static const void *kYTLGCompositorKey = &kYTLGCompositorKey;
static const void *kYTLGBackgroundKey = &kYTLGBackgroundKey;
static const void *kYTLGLensKey = &kYTLGLensKey;

#pragma mark - Liquid Glass effects

// Keep the dylib loadable with the existing iOS 15 deployment target.
// iOS 26+ symbols only appear inside availability-guarded blocks.

static UIVisualEffect *YTLGGlassEffect(BOOL clearStyle, BOOL selectedLens) {
    if (@available(iOS 26.0, *)) {
        Class glassClass = NSClassFromString(@"UIGlassEffect");

        if (glassClass &&
            [glassClass respondsToSelector:@selector(effectWithStyle:)]) {

            UIGlassEffectStyle style =
                clearStyle ? UIGlassEffectStyleClear
                           : UIGlassEffectStyleRegular;

            UIGlassEffect *effect = [UIGlassEffect effectWithStyle:style];
            effect.interactive = NO;

            // A subtle dark tint gives the selected lens the stronger,
            // separated appearance of the native floating controls.
            if (selectedLens) {
                effect.tintColor =
                    [UIColor.blackColor colorWithAlphaComponent:0.18];
            }

            return effect;
        }
    }

    return [UIBlurEffect
        effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
}

static UIVisualEffect *YTLGContainerEffect(void) {
    if (@available(iOS 26.0, *)) {
        Class containerClass = NSClassFromString(@"UIGlassContainerEffect");

        if (containerClass) {
            UIGlassContainerEffect *effect =
                [[UIGlassContainerEffect alloc] init];

            // Allows the moving selected lens and the main capsule to
            // visually interact/merge instead of looking like unrelated
            // blur rectangles.
            effect.spacing = 12.0;
            return effect;
        }
    }

    return nil;
}

static void YTLGPrepareGlassView(UIVisualEffectView *view) {
    view.userInteractionEnabled = NO;
    view.opaque = NO;
    view.backgroundColor = UIColor.clearColor;
    view.clipsToBounds = YES;
    view.layer.cornerCurve = kCACornerCurveContinuous;
}

#pragma mark - Glass hierarchy

static UIVisualEffectView *YTLGCompositor(YTPivotBarView *bar) {
    UIVisualEffectView *view =
        objc_getAssociatedObject(bar, kYTLGCompositorKey);

    if (!view) {
        view = [[UIVisualEffectView alloc]
            initWithEffect:YTLGContainerEffect()];

        view.userInteractionEnabled = NO;
        view.opaque = NO;
        view.backgroundColor = UIColor.clearColor;
        view.clipsToBounds = NO;
        view.contentView.clipsToBounds = NO;
        view.accessibilityIdentifier =
            @"YTLiquidGlass.GlassContainer";

        [bar insertSubview:view atIndex:0];

        objc_setAssociatedObject(
            bar,
            kYTLGCompositorKey,
            view,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }

    return view;
}

static UIVisualEffectView *YTLGBackgroundGlass(YTPivotBarView *bar) {
    UIVisualEffectView *glass =
        objc_getAssociatedObject(bar, kYTLGBackgroundKey);

    if (!glass) {
        UIVisualEffectView *compositor = YTLGCompositor(bar);

        glass = [[UIVisualEffectView alloc]
            initWithEffect:YTLGGlassEffect(NO, NO)];

        YTLGPrepareGlassView(glass);

        glass.accessibilityIdentifier =
            @"YTLiquidGlass.FloatingTabBar";

        [compositor.contentView addSubview:glass];

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
        UIVisualEffectView *compositor = YTLGCompositor(bar);

        lens = [[UIVisualEffectView alloc]
            initWithEffect:YTLGGlassEffect(YES, YES)];

        YTLGPrepareGlassView(lens);

        lens.hidden = YES;
        lens.accessibilityIdentifier =
            @"YTLiquidGlass.SelectedLens";

        [compositor.contentView addSubview:lens];

        objc_setAssociatedObject(
            bar,
            kYTLGLensKey,
            lens,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }

    return lens;
}

#pragma mark - YouTube/YTLite items

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
        // Do not walk our own visual-effect hierarchy.
        if ([subview.accessibilityIdentifier
                hasPrefix:@"YTLiquidGlass."]) {
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
            CGRect frameA =
                [a convertRect:a.bounds toView:bar];
            CGRect frameB =
                [b convertRect:b.bounds toView:bar];

            if (CGRectGetMinX(frameA) <
                CGRectGetMinX(frameB)) {
                return NSOrderedAscending;
            }

            if (CGRectGetMinX(frameA) >
                CGRectGetMinX(frameB)) {
                return NSOrderedDescending;
            }

            return NSOrderedSame;
        }];

    return items;
}

#pragma mark - Geometry

static CGRect YTLGCapsuleFrame(YTPivotBarView *bar) {
    CGRect bounds = bar.bounds;

    CGFloat safeBottom = bar.safeAreaInsets.bottom;

    // Keep the floating material around the actual tab content instead
    // of extending through the entire home-indicator/safe-area region.
    CGFloat usableHeight =
        MAX(44.0, bounds.size.height - safeBottom);

    CGFloat horizontalInset =
        MAX(14.0, bounds.size.width * 0.04);

    CGFloat capsuleHeight =
        MIN(60.0, MAX(50.0, usableHeight - 4.0));

    CGFloat y =
        MAX(2.0, (usableHeight - capsuleHeight) * 0.5);

    CGFloat width =
        MAX(1.0,
            bounds.size.width - horizontalInset * 2.0);

    return CGRectMake(
        horizontalInset,
        y,
        width,
        capsuleHeight
    );
}

static CGRect YTLGLensFrame(
    YTPivotBarView *bar,
    YTPivotBarItemView *item,
    CGRect capsuleFrame
) {
    CGRect itemFrame =
        [item convertRect:item.bounds toView:bar];

    // Use the tab's real runtime width so YTLite custom tabs,
    // removals and reordered layouts are followed automatically.
    CGFloat sideInset =
        MAX(3.0, itemFrame.size.width * 0.055);

    CGFloat desiredWidth =
        MAX(44.0, itemFrame.size.width - sideInset * 2.0);

    CGFloat lensHeight =
        MAX(42.0, capsuleFrame.size.height - 6.0);

    lensHeight =
        MIN(lensHeight, capsuleFrame.size.height - 2.0);

    CGFloat x =
        CGRectGetMidX(itemFrame) - desiredWidth * 0.5;

    CGFloat y =
        CGRectGetMidY(capsuleFrame) - lensHeight * 0.5;

    CGFloat minX =
        CGRectGetMinX(capsuleFrame) + 2.0;

    CGFloat maxX =
        CGRectGetMaxX(capsuleFrame) - 2.0 - desiredWidth;

    if (maxX < minX) {
        maxX = minX;
    }

    x = MIN(MAX(x, minX), maxX);

    return CGRectMake(
        x,
        y,
        desiredWidth,
        lensHeight
    );
}

static BOOL YTLGFramesNearlyEqual(
    CGRect a,
    CGRect b
) {
    const CGFloat epsilon = 0.5;

    return fabs(a.origin.x - b.origin.x) < epsilon &&
           fabs(a.origin.y - b.origin.y) < epsilon &&
           fabs(a.size.width - b.size.width) < epsilon &&
           fabs(a.size.height - b.size.height) < epsilon;
}

#pragma mark - Styling

static void YTLGClearOriginalBarChrome(
    YTPivotBarView *bar
) {
    // Remove the old full-width slab. Do not hide or replace the
    // item views themselves, so navigation and YTLite behavior stay intact.
    bar.opaque = NO;
    bar.backgroundColor = UIColor.clearColor;
    bar.layer.backgroundColor =
        UIColor.clearColor.CGColor;
    bar.clipsToBounds = NO;
    bar.layer.masksToBounds = NO;
}

static void YTLGUpdateGlass(
    YTPivotBarView *bar,
    BOOL animated
) {
    if (!bar ||
        CGRectIsEmpty(bar.bounds) ||
        !bar.window) {
        return;
    }

    YTLGClearOriginalBarChrome(bar);

    UIVisualEffectView *compositor =
        YTLGCompositor(bar);

    UIVisualEffectView *background =
        YTLGBackgroundGlass(bar);

    UIVisualEffectView *lens =
        YTLGSelectionLens(bar);

    compositor.frame = bar.bounds;

    CGRect capsuleFrame =
        YTLGCapsuleFrame(bar);

    background.frame = capsuleFrame;
    background.layer.cornerRadius =
        capsuleFrame.size.height * 0.5;

    // Keep our effect hierarchy underneath YouTube's actual tab controls.
    [bar sendSubviewToBack:compositor];

    NSArray<YTPivotBarItemView *> *items =
        YTLGCurrentItems(bar);

    YTPivotBarItemView *selectedItem = nil;

    for (YTPivotBarItemView *item in items) {
        // Remove any item-level background color without touching
        // its image/title hierarchy or interaction.
        item.opaque = NO;
        item.backgroundColor = UIColor.clearColor;

        if (YTLGItemIsSelected(item)) {
            selectedItem = item;
        }
    }

    if (!selectedItem) {
        lens.hidden = YES;
        return;
    }

    CGRect targetFrame =
        YTLGLensFrame(
            bar,
            selectedItem,
            capsuleFrame
        );

    lens.layer.cornerRadius =
        targetFrame.size.height * 0.5;

    if (lens.hidden ||
        !animated ||
        CGRectIsEmpty(lens.frame)) {

        lens.hidden = NO;
        lens.frame = targetFrame;
        return;
    }

    if (YTLGFramesNearlyEqual(
            lens.frame,
            targetFrame)) {
        return;
    }

    [UIView animateWithDuration:0.34
                          delay:0.0
         usingSpringWithDamping:0.88
          initialSpringVelocity:0.18
                        options:
                            UIViewAnimationOptionBeginFromCurrentState |
                            UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         lens.frame = targetFrame;
                         lens.layer.cornerRadius =
                             targetFrame.size.height * 0.5;
                     }
                     completion:nil];
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
    UIView *view = [controller pivotBarView];

    if (!view ||
        ![view isKindOfClass:
            NSClassFromString(@"YTPivotBarView")]) {
        return;
    }

    YTLGRefreshSoon(
        (YTPivotBarView *)view,
        animated
    );
}

#pragma mark - Hooks

%group YTLiquidGlass

%hook YTPivotBarView

- (void)layoutSubviews {
    %orig;

    // No animation during ordinary layout passes.
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

    // The selected item is already owned/changed by YouTube/YTLite.
    // We only move the single glass lens to its new runtime frame.
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
        if (NSClassFromString(@"UIGlassEffect") &&
            NSClassFromString(@"UIGlassContainerEffect") &&
            NSClassFromString(@"YTPivotBarView") &&
            NSClassFromString(@"YTPivotBarItemView") &&
            NSClassFromString(@"YTPivotBarViewController")) {

            %init(YTLiquidGlass);
        }
    }
}
