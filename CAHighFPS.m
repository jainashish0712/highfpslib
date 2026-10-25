#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <TargetConditionals.h>

#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

#if !__has_include(<QuartzCore/CAFrameRateRange.h>)
typedef struct CAFrameRateRange {
    float minimum;
    float maximum;
    float preferred;
} CAFrameRateRange;

static inline CAFrameRateRange CAFrameRateRangeMake(float minimum, float maximum, float preferred) {
    CAFrameRateRange range;
    range.minimum = minimum;
    range.maximum = maximum;
    range.preferred = preferred;
    return range;
}
#endif

#define FPS_HIGH 120.0f
#define FPS_LOW 60.0f
#define FPS_HIGH_INT 120
#define FPS_LOW_INT 60

typedef NS_ENUM(NSInteger, FPSMode) {
    FPSModeAuto = 0,    // Pixel style: 120Hz active scrolling, 60Hz still view
    FPSModeLock120 = 1, // Locked 120Hz constantly
    FPSModeLock60 = 2   // Locked 60Hz constantly
};

static FPSMode s_fpsMode = FPSModeAuto;
static CFTimeInterval s_lastInteractionTime = 0.0;
static BOOL s_isInteracting = NO;

#pragma mark - Pixel Style Refresh Governor

static inline BOOL IsScrollActive(void) {
    if (s_fpsMode == FPSModeLock120) return YES;
    if (s_fpsMode == FPSModeLock60) return NO;

    if (s_isInteracting) return YES;
    CFTimeInterval now = CACurrentMediaTime();
    // 0.45s coasting window to ensure low-velocity deceleration glides to a stop at 120Hz
    return (now - s_lastInteractionTime) < 0.45;
}

static inline float GetEffectiveTargetFPS(void) {
    if (s_fpsMode == FPSModeLock60) return FPS_LOW;
    if (s_fpsMode == FPSModeLock120) return FPS_HIGH;
    return IsScrollActive() ? FPS_HIGH : FPS_LOW;
}

static inline CAFrameRateRange GetCurrentFrameRateRange(void) {
    float fps = GetEffectiveTargetFPS();
    // Force minimum, maximum, and preferred to the exact same rate.
    // This physically prevents iOS compositor from dropping to 80Hz or 90Hz during scrolling.
    return CAFrameRateRangeMake(fps, fps, fps);
}

#pragma mark - Method Swizzling Utilities

static void SwizzleInstanceMethod(Class cls, SEL origSEL, SEL swizzledSEL) {
    if (!cls) return;
    Method origMethod = class_getInstanceMethod(cls, origSEL);
    Method swizzledMethod = class_getInstanceMethod(cls, swizzledSEL);
    if (!origMethod || !swizzledMethod) return;

    BOOL didAddMethod = class_addMethod(cls,
                                        origSEL,
                                        method_getImplementation(swizzledMethod),
                                        method_getTypeEncoding(swizzledMethod));
    if (didAddMethod) {
        class_replaceMethod(cls,
                            swizzledSEL,
                            method_getImplementation(origMethod),
                            method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, swizzledMethod);
    }
}

static void SwizzleClassMethod(Class cls, SEL origSEL, SEL swizzledSEL) {
    if (!cls) return;
    Class metaCls = object_getClass((id)cls);
    if (!metaCls) return;
    SwizzleInstanceMethod(metaCls, origSEL, swizzledSEL);
}

#if TARGET_OS_IOS
#pragma mark - 24x24 Floating FPS Picker & HUD Overlay

@interface FPSOverlayWindow : UIWindow
@property (nonatomic, strong) UILabel *fpsLabel;
@property (nonatomic, strong) UIPanGestureRecognizer *panGesture;
@property (nonatomic, strong) UITapGestureRecognizer *tapGesture;
@property (nonatomic, assign) CFTimeInterval lastFlashTime;
+ (instancetype)sharedInstance;
- (void)updateFPS:(int)fps;
@end

@implementation FPSOverlayWindow

+ (instancetype)sharedInstance {
    static FPSOverlayWindow *overlay = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        overlay = [[FPSOverlayWindow alloc] init];
    });
    return overlay;
}

- (instancetype)init {
    // 24px x 24px compact modal as requested
    CGRect frame = CGRectMake(16, 60, 24, 24);
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelStatusBar + 100;
        self.backgroundColor = [UIColor colorWithWhite:0.05f alpha:0.85f];
        self.layer.cornerRadius = 12.0f; // circular pill
        self.layer.borderWidth = 1.5f;
        self.layer.borderColor = [UIColor colorWithRed:0.0f green:0.9f blue:0.4f alpha:1.0f].CGColor;
        self.layer.masksToBounds = YES;
        self.clipsToBounds = YES;

        _fpsLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 24, 24)];
        _fpsLabel.textAlignment = NSTextAlignmentCenter;
        _fpsLabel.font = [UIFont monospacedDigitSystemFontOfSize:9.0 weight:UIFontWeightBold];
        _fpsLabel.textColor = [UIColor whiteColor];
        _fpsLabel.text = @"120";
        _fpsLabel.adjustsFontSizeToFitWidth = YES;
        _fpsLabel.minimumScaleFactor = 0.5;
        [self addSubview:_fpsLabel];

        _panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self selector:@selector(handlePan:)];
        [self addGestureRecognizer:_panGesture];

        _tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self selector:@selector(handleTap:)];
        [self addGestureRecognizer:_tapGesture];

        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        self.rootViewController = vc;

        self.hidden = NO;
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.superview];
}

- (void)handleTap:(UITapGestureRecognizer *)tap {
    // Cycle: Auto (Pixel 120/60) -> Locked 120 -> Locked 60 -> Auto
    s_fpsMode = (s_fpsMode + 1) % 3;

    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [haptic impactOccurred];
    }

    _lastFlashTime = CACurrentMediaTime();
    NSString *modeText = @"A";
    UIColor *borderColor = [UIColor colorWithRed:0.2f green:0.75f blue:1.0f alpha:1.0f]; // Blue for Auto
    if (s_fpsMode == FPSModeLock120) {
        modeText = @"120";
        borderColor = [UIColor colorWithRed:0.0f green:0.9f blue:0.4f alpha:1.0f]; // Green
    } else if (s_fpsMode == FPSModeLock60) {
        modeText = @"60";
        borderColor = [UIColor colorWithRed:1.0f green:0.55f blue:0.0f alpha:1.0f]; // Orange
    }
    self.fpsLabel.text = modeText;
    self.layer.borderColor = borderColor.CGColor;
}

- (void)updateFPS:(int)fps {
    // Only update label if not currently flashing mode text from a tap
    if (CACurrentMediaTime() - _lastFlashTime < 0.6) return;

    self.fpsLabel.text = [NSString stringWithFormat:@"%d", fps];
    if (fps >= 100) {
        self.layer.borderColor = [UIColor colorWithRed:0.0f green:0.9f blue:0.4f alpha:1.0f].CGColor;
    } else {
        self.layer.borderColor = [UIColor colorWithRed:1.0f green:0.55f blue:0.0f alpha:1.0f].CGColor;
    }
}

@end
#endif

#pragma mark - Heartbeat DisplayLink Driver

@interface HighFPSDriver : NSObject
#if TARGET_OS_IOS
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval lastHUDUpdateTime;
#endif
+ (instancetype)sharedInstance;
- (void)start;
- (void)stop;
- (void)resume;
- (void)pause;
@end

@implementation HighFPSDriver

+ (instancetype)sharedInstance {
    static HighFPSDriver *driver = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        driver = [[HighFPSDriver alloc] init];
    });
    return driver;
}

- (instancetype)init {
    self = [super init];
    if (self) {
#if TARGET_OS_IOS
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(start) name:UIApplicationDidFinishLaunchingNotification object:nil];
        [nc addObserver:self selector:@selector(resume) name:UIApplicationDidBecomeActiveNotification object:nil];
        [nc addObserver:self selector:@selector(pause) name:UIApplicationWillResignActiveNotification object:nil];
        [nc addObserver:self selector:@selector(pause) name:UIApplicationDidEnterBackgroundNotification object:nil];
#endif
    }
    return self;
}

#if TARGET_OS_IOS
- (void)onDisplayLinkTick:(CADisplayLink *)link {
    // Dynamically adjust frame rate range: 120Hz while scrolling, 60Hz when still
    CAFrameRateRange range = GetCurrentFrameRateRange();
    if (@available(iOS 15.0, *)) {
        link.preferredFrameRateRange = range;
    }

    CFTimeInterval now = CACurrentMediaTime();
    if (now - _lastHUDUpdateTime >= 0.1) {
        _lastHUDUpdateTime = now;
        CFTimeInterval duration = link.targetTimestamp - link.timestamp;
        int currentFPS = (duration > 0.001) ? (int)lround(1.0 / duration) : 120;
        [[FPSOverlayWindow sharedInstance] updateFPS:currentFPS];
    }
}
#endif

- (void)start {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self start];
        });
        return;
    }

#if TARGET_OS_IOS
    // Initialize 24px x 24px HUD Overlay
    [FPSOverlayWindow sharedInstance];

    if (self.displayLink) {
        self.displayLink.paused = NO;
        return;
    }

    @try {
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayLinkTick:)];

        if (@available(iOS 15.0, *)) {
            self.displayLink.preferredFrameRateRange = GetCurrentFrameRateRange();
        }

        if ([self.displayLink respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
            self.displayLink.preferredFramesPerSecond = FPS_HIGH_INT;
        }
        if ([self.displayLink respondsToSelector:@selector(setFrameInterval:)]) {
            self.displayLink.frameInterval = 1;
        }

        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    } @catch (NSException *exception) {
        NSLog(@"[CAHighFPS] Warning: Failed to initialize display link: %@", exception);
    }
#endif
}

- (void)resume {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self resume];
        });
        return;
    }

#if TARGET_OS_IOS
    if (self.displayLink) {
        self.displayLink.paused = NO;
    } else {
        [self start];
    }
#endif
}

- (void)pause {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self pause];
        });
        return;
    }

#if TARGET_OS_IOS
    if (self.displayLink) {
        self.displayLink.paused = YES;
    }
#endif
}

- (void)stop {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stop];
        });
        return;
    }

#if TARGET_OS_IOS
    if (self.displayLink) {
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
#endif
}

@end

#if TARGET_OS_IOS
#pragma mark - CADisplayLink Hooks

@interface CADisplayLink (HighFPS)
@end

@implementation CADisplayLink (HighFPS)

+ (CADisplayLink *)highfps_displayLinkWithTarget:(id)target selector:(SEL)sel {
    CADisplayLink *link = [self highfps_displayLinkWithTarget:target selector:sel];
    if (link) {
        if (@available(iOS 15.0, *)) {
            link.preferredFrameRateRange = GetCurrentFrameRateRange();
        }
        if ([link respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
            link.preferredFramesPerSecond = (NSInteger)GetEffectiveTargetFPS();
        }
        if ([link respondsToSelector:@selector(setFrameInterval:)]) {
            link.frameInterval = 1;
        }
    }
    return link;
}

- (void)highfps_addToRunLoop:(NSRunLoop *)runloop forMode:(NSRunLoopMode)mode {
    if (@available(iOS 15.0, *)) {
        self.preferredFrameRateRange = GetCurrentFrameRateRange();
    }
    if ([self respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        self.preferredFramesPerSecond = (NSInteger)GetEffectiveTargetFPS();
    }
    if ([self respondsToSelector:@selector(setFrameInterval:)]) {
        self.frameInterval = 1;
    }
    [self highfps_addToRunLoop:runloop forMode:mode];
}

- (void)highfps_setPreferredFrameRateRange:(CAFrameRateRange)range {
    [self highfps_setPreferredFrameRateRange:GetCurrentFrameRateRange()];
}

- (CAFrameRateRange)highfps_preferredFrameRateRange {
    return GetCurrentFrameRateRange();
}

- (void)highfps_setPreferredFramesPerSecond:(NSInteger)fps {
    [self highfps_setPreferredFramesPerSecond:(NSInteger)GetEffectiveTargetFPS()];
}

- (NSInteger)highfps_preferredFramesPerSecond {
    return (NSInteger)GetEffectiveTargetFPS();
}

- (void)highfps_setFrameInterval:(NSInteger)interval {
    [self highfps_setFrameInterval:1];
}

- (NSInteger)highfps_frameInterval {
    return 1;
}

@end

#pragma mark - UIScrollView Tracking & Deceleration Hooks

@interface UIScrollView (HighFPS)
@end

@implementation UIScrollView (HighFPS)

- (void)highfps_setContentOffset:(CGPoint)contentOffset {
    if (self.isDragging || self.isDecelerating) {
        s_lastInteractionTime = CACurrentMediaTime();
    }
    [self highfps_setContentOffset:contentOffset];
}

- (void)highfps_setFrameRateRange:(CAFrameRateRange)range {
    s_lastInteractionTime = CACurrentMediaTime();
    [self highfps_setFrameRateRange:GetCurrentFrameRateRange()];
}

- (CAFrameRateRange)highfps_frameRateRange {
    return GetCurrentFrameRateRange();
}

@end

#pragma mark - UIGestureRecognizer Touch Interaction Hooks

@interface UIGestureRecognizer (HighFPS)
@end

@implementation UIGestureRecognizer (HighFPS)

- (void)highfps_setFrameRateRange:(CAFrameRateRange)range {
    s_lastInteractionTime = CACurrentMediaTime();
    [self highfps_setFrameRateRange:GetCurrentFrameRateRange()];
}

- (CAFrameRateRange)highfps_frameRateRange {
    return GetCurrentFrameRateRange();
}

@end

#pragma mark - UIWindow Touch Event Interception

@interface UIWindow (HighFPS)
@end

@implementation UIWindow (HighFPS)

- (void)highfps_sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches) {
        s_lastInteractionTime = CACurrentMediaTime();
        NSSet *touches = [event allTouches];
        for (UITouch *touch in touches) {
            if (touch.phase == UITouchPhaseBegan || touch.phase == UITouchPhaseMoved) {
                s_isInteracting = YES;
                break;
            } else if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                s_isInteracting = NO;
            }
        }
    }
    [self highfps_sendEvent:event];
}

@end

#pragma mark - UIScreen Hooks

@interface UIScreen (HighFPS)
@end

@implementation UIScreen (HighFPS)

- (NSInteger)highfps_maximumFramesPerSecond {
    NSInteger orig = [self highfps_maximumFramesPerSecond];
    return (orig > FPS_HIGH_INT) ? orig : FPS_HIGH_INT;
}

- (CFTimeInterval)highfps_minimumFrameDuration {
    return (1.0 / GetEffectiveTargetFPS());
}

@end
#endif

#pragma mark - CAAnimation Hooks

@interface CAAnimation (HighFPS)
@end

@implementation CAAnimation (HighFPS)

- (void)highfps_setPreferredFrameRateRange:(CAFrameRateRange)range {
    [self highfps_setPreferredFrameRateRange:GetCurrentFrameRateRange()];
}

- (CAFrameRateRange)highfps_preferredFrameRateRange {
    return GetCurrentFrameRateRange();
}

@end

#pragma mark - CALayer Hooks

@interface CALayer (HighFPS)
@end

@implementation CALayer (HighFPS)

- (void)highfps_addAnimation:(CAAnimation *)anim forKey:(NSString *)key {
    if (anim && [anim respondsToSelector:@selector(setPreferredFrameRateRange:)]) {
        anim.preferredFrameRateRange = GetCurrentFrameRateRange();
    }
    [self highfps_addAnimation:anim forKey:key];
}

- (void)highfps_setFrameRateRange:(CAFrameRateRange)range {
    [self highfps_setFrameRateRange:GetCurrentFrameRateRange()];
}

- (CAFrameRateRange)highfps_frameRateRange {
    return GetCurrentFrameRateRange();
}

@end

#pragma mark - CAMetalLayer Hooks

@interface CAMetalLayer (HighFPS)
@end

@implementation CAMetalLayer (HighFPS)

- (NSUInteger)highfps_maximumDrawableCount {
    return 3;
}

- (void)highfps_setMaximumDrawableCount:(NSUInteger)count {
    [self highfps_setMaximumDrawableCount:3];
}

@end

#pragma mark - NSBundle Hooks (Safe Read-Only)

@interface NSBundle (HighFPS)
@end

@implementation NSBundle (HighFPS)

- (id)highfps_objectForInfoDictionaryKey:(NSString *)key {
    if ([key isEqualToString:@"CADisableMinimumFrameDurationOnPhone"] ||
        [key isEqualToString:@"CADisableMinimumFrameDuration"]) {
        return (id)kCFBooleanTrue;
    }
    return [self highfps_objectForInfoDictionaryKey:key];
}

@end

#pragma mark - Metal Presentation Hooks

static void (*orig_presentAfterMinimumDuration)(id self, SEL _cmd, CFTimeInterval duration);
static void highfps_presentAfterMinimumDuration(id self, SEL _cmd, CFTimeInterval duration) {
    if (orig_presentAfterMinimumDuration) {
        orig_presentAfterMinimumDuration(self, _cmd, 1.0 / GetEffectiveTargetFPS());
    }
}

static void (*orig_presentDrawable_afterMinimumDuration)(id self, SEL _cmd, id drawable, CFTimeInterval duration);
static void highfps_presentDrawable_afterMinimumDuration(id self, SEL _cmd, id drawable, CFTimeInterval duration) {
    if (orig_presentDrawable_afterMinimumDuration) {
        orig_presentDrawable_afterMinimumDuration(self, _cmd, drawable, 1.0 / GetEffectiveTargetFPS());
    }
}

#pragma mark - Initialization

static void InitSwizzling(void) {
    @try {
#if TARGET_OS_IOS
        // 1. CADisplayLink
        Class dlClass = [CADisplayLink class];
        if (dlClass) {
            Method mCreate = class_getClassMethod(dlClass, @selector(displayLinkWithTarget:selector:));
            if (mCreate) {
                SwizzleClassMethod(dlClass, @selector(displayLinkWithTarget:selector:), @selector(highfps_displayLinkWithTarget:selector:));
            }
            if (class_getInstanceMethod(dlClass, @selector(addToRunLoop:forMode:))) {
                SwizzleInstanceMethod(dlClass, @selector(addToRunLoop:forMode:), @selector(highfps_addToRunLoop:forMode:));
            }
            if (class_getInstanceMethod(dlClass, @selector(setPreferredFrameRateRange:))) {
                SwizzleInstanceMethod(dlClass, @selector(setPreferredFrameRateRange:), @selector(highfps_setPreferredFrameRateRange:));
                SwizzleInstanceMethod(dlClass, @selector(preferredFrameRateRange), @selector(highfps_preferredFrameRateRange));
            }
            if (class_getInstanceMethod(dlClass, @selector(setPreferredFramesPerSecond:))) {
                SwizzleInstanceMethod(dlClass, @selector(setPreferredFramesPerSecond:), @selector(highfps_setPreferredFramesPerSecond:));
                SwizzleInstanceMethod(dlClass, @selector(preferredFramesPerSecond), @selector(highfps_preferredFramesPerSecond));
            }
            if (class_getInstanceMethod(dlClass, @selector(setFrameInterval:))) {
                SwizzleInstanceMethod(dlClass, @selector(setFrameInterval:), @selector(highfps_setFrameInterval:));
                SwizzleInstanceMethod(dlClass, @selector(frameInterval), @selector(highfps_frameInterval));
            }
        }

        // 2. UIScrollView (Content offset & internal frame rate range)
        Class svClass = [UIScrollView class];
        if (svClass) {
            if (class_getInstanceMethod(svClass, @selector(setContentOffset:))) {
                SwizzleInstanceMethod(svClass, @selector(setContentOffset:), @selector(highfps_setContentOffset:));
            }
            SEL setRangeSEL = sel_registerName("_setFrameRateRange:");
            SEL getRangeSEL = sel_registerName("_frameRateRange");
            if (class_getInstanceMethod(svClass, setRangeSEL)) {
                SwizzleInstanceMethod(svClass, setRangeSEL, @selector(highfps_setFrameRateRange:));
            }
            if (class_getInstanceMethod(svClass, getRangeSEL)) {
                SwizzleInstanceMethod(svClass, getRangeSEL, @selector(highfps_frameRateRange));
            }
        }

        // 3. UIGestureRecognizer
        Class grClass = [UIGestureRecognizer class];
        if (grClass) {
            SEL setRangeSEL = sel_registerName("_setFrameRateRange:");
            SEL getRangeSEL = sel_registerName("_frameRateRange");
            if (class_getInstanceMethod(grClass, setRangeSEL)) {
                SwizzleInstanceMethod(grClass, setRangeSEL, @selector(highfps_setFrameRateRange:));
            }
            if (class_getInstanceMethod(grClass, getRangeSEL)) {
                SwizzleInstanceMethod(grClass, getRangeSEL, @selector(highfps_frameRateRange));
            }
        }

        // 4. UIWindow (Touch events)
        Class winClass = [UIWindow class];
        if (winClass) {
            if (class_getInstanceMethod(winClass, @selector(sendEvent:))) {
                SwizzleInstanceMethod(winClass, @selector(sendEvent:), @selector(highfps_sendEvent:));
            }
        }

        // 5. UIScreen
        Class screenClass = [UIScreen class];
        if (screenClass) {
            if (class_getInstanceMethod(screenClass, @selector(maximumFramesPerSecond))) {
                SwizzleInstanceMethod(screenClass, @selector(maximumFramesPerSecond), @selector(highfps_maximumFramesPerSecond));
            }
            if (class_getInstanceMethod(screenClass, @selector(minimumFrameDuration))) {
                SwizzleInstanceMethod(screenClass, @selector(minimumFrameDuration), @selector(highfps_minimumFrameDuration));
            }
        }
#endif

        // 6. CAAnimation
        Class animClass = [CAAnimation class];
        if (animClass) {
            if (class_getInstanceMethod(animClass, @selector(setPreferredFrameRateRange:))) {
                SwizzleInstanceMethod(animClass, @selector(setPreferredFrameRateRange:), @selector(highfps_setPreferredFrameRateRange:));
                SwizzleInstanceMethod(animClass, @selector(preferredFrameRateRange), @selector(highfps_preferredFrameRateRange));
            }
        }

        // 7. CALayer
        Class layerClass = [CALayer class];
        if (layerClass) {
            if (class_getInstanceMethod(layerClass, @selector(addAnimation:forKey:))) {
                SwizzleInstanceMethod(layerClass, @selector(addAnimation:forKey:), @selector(highfps_addAnimation:forKey:));
            }
            SEL setRangeSEL = sel_registerName("_setFrameRateRange:");
            SEL getRangeSEL = sel_registerName("_frameRateRange");
            if (class_getInstanceMethod(layerClass, setRangeSEL)) {
                SwizzleInstanceMethod(layerClass, setRangeSEL, @selector(highfps_setFrameRateRange:));
            }
            if (class_getInstanceMethod(layerClass, getRangeSEL)) {
                SwizzleInstanceMethod(layerClass, getRangeSEL, @selector(highfps_frameRateRange));
            }
        }

        // 8. CAMetalLayer
        Class metalLayerClass = objc_getClass("CAMetalLayer");
        if (metalLayerClass) {
            if (class_getInstanceMethod(metalLayerClass, @selector(maximumDrawableCount))) {
                SwizzleInstanceMethod(metalLayerClass, @selector(maximumDrawableCount), @selector(highfps_maximumDrawableCount));
            }
            if (class_getInstanceMethod(metalLayerClass, @selector(setMaximumDrawableCount:))) {
                SwizzleInstanceMethod(metalLayerClass, @selector(setMaximumDrawableCount:), @selector(highfps_setMaximumDrawableCount:));
            }
        }

        // 9. Metal Presentation Functions
        Class metalDrawableClass = objc_getClass("CAMetalDrawable");
        if (metalDrawableClass) {
            Method m = class_getInstanceMethod(metalDrawableClass, @selector(presentAfterMinimumDuration:));
            if (m) {
                orig_presentAfterMinimumDuration = (void (*)(id, SEL, CFTimeInterval))method_getImplementation(m);
                method_setImplementation(m, (IMP)highfps_presentAfterMinimumDuration);
            }
        }

        Class cmdBufferClass = objc_getClass("_MTLCommandBuffer") ?: objc_getClass("MTLCommandBuffer");
        if (cmdBufferClass) {
            Method m = class_getInstanceMethod(cmdBufferClass, @selector(presentDrawable:afterMinimumDuration:));
            if (m) {
                orig_presentDrawable_afterMinimumDuration = (void (*)(id, SEL, id, CFTimeInterval))method_getImplementation(m);
                method_setImplementation(m, (IMP)highfps_presentDrawable_afterMinimumDuration);
            }
        }

        // 10. NSBundle
        Class bundleClass = [NSBundle class];
        if (bundleClass) {
            if (class_getInstanceMethod(bundleClass, @selector(objectForInfoDictionaryKey:))) {
                SwizzleInstanceMethod(bundleClass, @selector(objectForInfoDictionaryKey:), @selector(highfps_objectForInfoDictionaryKey:));
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[CAHighFPS] Warning during InitSwizzling: %@", e);
    }
}

__attribute__((constructor))
static void CAHighFPS_Init(void) {
    @autoreleasepool {
        InitSwizzling();

        dispatch_async(dispatch_get_main_queue(), ^{
            [[HighFPSDriver sharedInstance] start];
        });

        NSLog(@"[CAHighFPS] Successfully loaded into %@ - Pixel mode active (120Hz scroll / 60Hz still).", [NSBundle mainBundle].bundleIdentifier);
    }
}

#pragma clang diagnostic pop
