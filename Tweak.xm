#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// Minimal declarations only. We deliberately do not replace YouTube/YTLite's
// tab model or controller; YTLite remains the source of truth for tab order,
// visibility, custom tabs, and selection.

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

static const void *kYTLGBarGlassKey = &kYTLGBarGlassKey;
static const void *kYTLGItemGlassKey = &kYTLGItemGlassKey;

// Keep the tweak loadable with the existing iOS 15 deployment target.
// iOS 26-only enum types and constants are referenced only inside the
// availability-guarded block so Clang does not emit unguarded-availability
// errors when building against the iOS 27 SDK.
static UIVisualEffect *YTLGGlassEffect(BOOL clearStyle) {
    if (@available(iOS 26.0, *)) {
        Class glassClass = NSClassFromString(@"UIGlassEffect");
        if (glassClass && [glassClass respondsToSelector:@selector(effectWithStyle:)]) {
            UIGlassEffectStyle style =
                clearStyle ? UIGlassEffectStyleClear : UIGlassEffectStyleRegular;
            return [UIGlassEffect effectWithStyle:style];
        }
    }

    // Fallback keeps the tweak harmless if it is ever run below iOS 26.
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
}

static void YTLGConfigureGlassView(UIVisualEffectView *view) {
    view.userInteractionEnabled = NO;
    view.clipsToBounds = YES;
    view.layer.cornerCurve = kCACornerCurveContinuous;
}

static UIVisualEffectView *YTLGBarGlassView(UIView *bar) {
    UIVisualEffectView *glass = objc_getAssociatedObject(bar, kYTLGBarGlassKey);
    if (!glass) {
        glass = [[UIVisualEffectView alloc] initWithEffect:YTLGGlassEffect(NO)];
        YTLGConfigureGlassView(glass);
        glass.accessibilityIdentifier = @"YTLiquidGlass.TabBarBackground";
        [bar insertSubview:glass atIndex:0];
        objc_setAssociatedObject(bar, kYTLGBarGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return glass;
}

static UIVisualEffectView *YTLGItemGlassView(UIView *item) {
    UIVisualEffectView *glass = objc_getAssociatedObject(item, kYTLGItemGlassKey);
    if (!glass) {
        glass = [[UIVisualEffectView alloc] initWithEffect:YTLGGlassEffect(YES)];
        YTLGConfigureGlassView(glass);
        glass.accessibilityIdentifier = @"YTLiquidGlass.SelectedTab";

        if (@available(iOS 26.0, *)) {
            UIGlassEffect *effect = (UIGlassEffect *)glass.effect;
            if ([effect isKindOfClass:NSClassFromString(@"UIGlassEffect")]) {
                effect.interactive = NO;
                effect.tintColor = [UIColor.secondaryLabelColor colorWithAlphaComponent:0.08];
            }
        }

        [item insertSubview:glass atIndex:0];
        objc_setAssociatedObject(item, kYTLGItemGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return glass;
}

static void YTLGStyleBar(YTPivotBarView *bar) {
    if (!bar || CGRectIsEmpty(bar.bounds)) return;

    // Visual-only changes. Do not touch the pivot renderer, item array,
    // identifiers, actions, delegates, or navigation controller.
    bar.opaque = NO;
    bar.backgroundColor = UIColor.clearColor;

    UIVisualEffectView *glass = YTLGBarGlassView(bar);

    CGFloat horizontalInset = 8.0;
    CGFloat verticalInset = 4.0;
    CGRect frame = CGRectInset(bar.bounds, horizontalInset, verticalInset);

    // Avoid invalid geometry during transient layout passes.
    if (frame.size.width < 1.0 || frame.size.height < 1.0) {
        frame = bar.bounds;
    }

    glass.frame = frame;
    glass.layer.cornerRadius = MAX(0.0, frame.size.height * 0.5);

    // Keep the glass behind whatever tab items YTLite/YouTube currently owns.
    [bar sendSubviewToBack:glass];
}

static BOOL YTLGItemIsSelected(YTPivotBarItemView *item) {
    NSString *itemIdentifier = item.renderer.pivotIdentifier;
    NSString *selectedIdentifier = item.delegate.selectedPivotIdentifier;

    if (itemIdentifier.length == 0 || selectedIdentifier.length == 0) {
        return NO;
    }

    return [itemIdentifier isEqualToString:selectedIdentifier];
}

static void YTLGStyleItem(YTPivotBarItemView *item) {
    if (!item || CGRectIsEmpty(item.bounds)) return;

    UIVisualEffectView *glass = YTLGItemGlassView(item);
    BOOL selected = YTLGItemIsSelected(item);

    glass.hidden = !selected;
    if (!selected) return;

    CGFloat horizontalInset = MAX(3.0, item.bounds.size.width * 0.10);
    CGFloat verticalInset = 5.0;
    CGRect frame = CGRectInset(item.bounds, horizontalInset, verticalInset);

    if (frame.size.width < 1.0 || frame.size.height < 1.0) {
        frame = item.bounds;
    }

    glass.frame = frame;
    glass.layer.cornerRadius = MAX(0.0, frame.size.height * 0.5);
    [item sendSubviewToBack:glass];
}

static void YTLGRefreshItems(UIView *view) {
    if (!view) return;

    Class itemClass = NSClassFromString(@"YTPivotBarItemView");
    if (itemClass && [view isKindOfClass:itemClass]) {
        YTLGStyleItem((YTPivotBarItemView *)view);
    }

    for (UIView *subview in view.subviews) {
        YTLGRefreshItems(subview);
    }
}

static void YTLGRefreshPivotBar(YTPivotBarViewController *controller) {
    UIView *bar = [controller pivotBarView];
    if (!bar) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        [bar setNeedsLayout];
        [bar layoutIfNeeded];
        YTLGRefreshItems(bar);
    });
}

%group YTLiquidGlass

%hook YTPivotBarView

- (void)layoutSubviews {
    %orig;
    YTLGStyleBar(self);
    YTLGRefreshItems(self);
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        YTLGStyleBar(self);
        YTLGRefreshItems(self);
    }
}

- (void)selectItemWithPivotIdentifier:(id)identifier {
    %orig(identifier);
    [self setNeedsLayout];

    dispatch_async(dispatch_get_main_queue(), ^{
        YTLGRefreshItems(self);
    });
}

%end

%hook YTPivotBarItemView

- (void)layoutSubviews {
    %orig;
    YTLGStyleItem(self);
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        YTLGStyleItem(self);
    }
}

%end

%hook YTPivotBarViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    YTLGRefreshPivotBar(self);
}

- (void)selectItemWithPivotIdentifier:(id)identifier {
    %orig(identifier);
    YTLGRefreshPivotBar(self);
}

%end

%end

%ctor {
    if (@available(iOS 26.0, *)) {
        if (NSClassFromString(@"YTPivotBarView") &&
            NSClassFromString(@"YTPivotBarItemView") &&
            NSClassFromString(@"YTPivotBarViewController")) {
            %init(YTLiquidGlass);
        }
    }
}
