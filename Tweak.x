#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

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
#define FPS_LOW 30.0f
#define FPS_HIGH_INT 120
#define FPS_LOW_INT 30

typedef NS_ENUM(NSInteger, FPSModeTheos) {
    FPSModeTheosAuto = 0,    // Dynamic 120Hz active / 30FPS idle
    FPSModeTheosLock120 = 1  // Force 120Hz constant
};

typedef NS_ENUM(NSInteger, GovernorStateTheos) {
    GovernorStateTheosIdle = 0,   // 30FPS Deep Sleep
    GovernorStateTheosActive = 1  // 120Hz Active Motion
};

static FPSModeTheos s_theosMode = FPSModeTheosAuto;
static GovernorStateTheos s_theosCurrentState = GovernorStateTheosIdle;
static CFTimeInterval s_theosLastMovementTime = 0.0;
static BOOL s_theosIsInteracting = NO;

#pragma mark - Zero-Stutter Kinematic Refresh Governor (Theos)

static inline BOOL IsTheosMotionActive(void) {
    if (s_theosMode == FPSModeTheosLock120) return YES;
    if (s_theosIsInteracting) return YES;
    CFTimeInterval now = CACurrentMediaTime();
    // 1000ms (1.0s) settling delay before dropping from 120fps to 30fps
    return (now - s_theosLastMovementTime) < 1.0;
}

static inline float GetTheosTargetFPS(void) {
    if (s_theosMode == FPSModeTheosLock120) {
        s_theosCurrentState = GovernorStateTheosActive;
        return FPS_HIGH;
    }
    if (IsTheosMotionActive()) {
        s_theosCurrentState = GovernorStateTheosActive;
        return FPS_HIGH;
    } else {
        s_theosCurrentState = GovernorStateTheosIdle;
        return FPS_LOW;
    }
}

static inline CAFrameRateRange GetTheosRange(void) {
    float fps = GetTheosTargetFPS();
    return CAFrameRateRangeMake(fps, fps, fps);
}

@interface CAMetalLayer (Private)
@property (assign) CGFloat drawableTimeoutSeconds;
@end

#pragma mark - Real-Time Live Tracker HUD Modal (Rich Debug Display Theos)

@interface FPSOverlayWindowTheos : UIWindow
@property (nonatomic, strong) UILabel *fpsLabel;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIView *separatorLine;
@property (nonatomic, strong) UIPanGestureRecognizer *panGesture;
@property (nonatomic, strong) UITapGestureRecognizer *tapGesture;
@property (nonatomic, assign) CFTimeInterval lastFlashTime;
+ (instancetype)sharedInstance;
- (void)updateDebugWithFPS:(int)fps durationMs:(double)ms state:(GovernorStateTheos)state;
- (void)ensureSceneAttachment;
@end

@implementation FPSOverlayWindowTheos

+ (instancetype)sharedInstance {
    static FPSOverlayWindowTheos *overlay = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        overlay = [[FPSOverlayWindowTheos alloc] init];
    });
    return overlay;
}

- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (void)ensureSceneAttachment {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *currentScene = self.windowScene;
        if (!currentScene || currentScene.activationState != UISceneActivationStateForegroundActive) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]] &&
                    scene.activationState == UISceneActivationStateForegroundActive) {
                    self.windowScene = (UIWindowScene *)scene;
                    break;
                }
            }
        }
    }
    if (self.hidden) {
        self.hidden = NO;
    }
}

- (instancetype)init {
    CGRect frame = CGRectMake(16, 60, 144, 36);
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 1000.0f;
        self.backgroundColor = [UIColor colorWithWhite:0.04f alpha:0.92f];
        self.layer.cornerRadius = 8.0f;
        self.layer.borderWidth = 1.5f;
        self.layer.borderColor = [UIColor colorWithRed:0.0f green:0.9f blue:0.46f alpha:1.0f].CGColor;
        self.layer.masksToBounds = YES;
        self.clipsToBounds = YES;

        _fpsLabel = [[UILabel alloc] initWithFrame:CGRectMake(6, 2, 92, 16)];
        _fpsLabel.textAlignment = NSTextAlignmentLeft;
        _fpsLabel.font = [UIFont monospacedDigitSystemFontOfSize:8.5 weight:UIFontWeightBold];
        _fpsLabel.textColor = [UIColor whiteColor];
        _fpsLabel.text = @"120 FPS (8.3ms)";
        _fpsLabel.adjustsFontSizeToFitWidth = YES;
        _fpsLabel.minimumScaleFactor = 0.6;
        [self addSubview:_fpsLabel];

        _stateLabel = [[UILabel alloc] initWithFrame:CGRectMake(100, 2, 38, 16)];
        _stateLabel.textAlignment = NSTextAlignmentRight;
        _stateLabel.font = [UIFont monospacedDigitSystemFontOfSize:8.5 weight:UIFontWeightBold];
        _stateLabel.textColor = [UIColor colorWithRed:0.0f green:0.9f blue:0.46f alpha:1.0f];
        _stateLabel.text = @"[ACT]";
        _stateLabel.adjustsFontSizeToFitWidth = YES;
        _stateLabel.minimumScaleFactor = 0.6;
        [self addSubview:_stateLabel];

        _separatorLine = [[UIView alloc] initWithFrame:CGRectMake(4, 18, 136, 1)];
        _separatorLine.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.18f];
        [self addSubview:_separatorLine];

        _detailLabel = [[UILabel alloc] initWithFrame:CGRectMake(6, 19, 132, 15)];
        _detailLabel.textAlignment = NSTextAlignmentLeft;
        _detailLabel.font = [UIFont monospacedDigitSystemFontOfSize:7.5 weight:UIFontWeightMedium];
        _detailLabel.textColor = [UIColor colorWithWhite:0.82f alpha:1.0f];
        _detailLabel.text = @"MODE:AUTO | TOUCH:1";
        _detailLabel.adjustsFontSizeToFitWidth = YES;
        _detailLabel.minimumScaleFactor = 0.5;
        [self addSubview:_detailLabel];

        _panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:_panGesture];

        _tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [self addGestureRecognizer:_tapGesture];

        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        self.rootViewController = vc;

        [self ensureSceneAttachment];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(ensureSceneAttachment)
                                                     name:UISceneDidActivateNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(ensureSceneAttachment)
                                                     name:UIWindowDidBecomeVisibleNotification
                                                   object:nil];

        self.hidden = NO;
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self];
    CGRect frame = self.frame;
    frame.origin.x += translation.x;
    frame.origin.y += translation.y;

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat minX = 4.0f;
    CGFloat maxX = screenBounds.size.width - frame.size.width - 4.0f;
    CGFloat minY = 28.0f;
    CGFloat maxY = screenBounds.size.height - frame.size.height - 28.0f;

    if (frame.origin.x < minX) frame.origin.x = minX;
    if (frame.origin.x > maxX) frame.origin.x = maxX;
    if (frame.origin.y < minY) frame.origin.y = minY;
    if (frame.origin.y > maxY) frame.origin.y = maxY;

    self.frame = frame;
    [pan setTranslation:CGPointMake(0, 0) inView:self];
}

- (void)handleTap:(UITapGestureRecognizer *)tap {
    s_theosMode = (s_theosMode + 1) % 2;

    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [haptic impactOccurred];
    }

    _lastFlashTime = CACurrentMediaTime();
    if (s_theosMode == FPSModeTheosLock120) {
        self.fpsLabel.text = @"MODE: LOCK 120";
        self.stateLabel.text = @"[LCK]";
        UIColor *purpleColor = [UIColor colorWithRed:0.88f green:0.25f blue:0.98f alpha:1.0f];
        self.stateLabel.textColor = purpleColor;
        self.layer.borderColor = purpleColor.CGColor;
        self.detailLabel.text = @"LOCKED TO CONSTANT 120Hz";
        self.detailLabel.textColor = purpleColor;
    } else {
        self.fpsLabel.text = @"MODE: AUTO DYNAMIC";
        self.stateLabel.text = (s_theosCurrentState == GovernorStateTheosActive) ? @"[ACT]" : @"[IDL]";
        UIColor *blueColor = [UIColor colorWithRed:0.0f green:0.75f blue:1.0f alpha:1.0f];
        self.stateLabel.textColor = blueColor;
        self.layer.borderColor = blueColor.CGColor;
        self.detailLabel.text = @"120Hz MOTION ↔ 30FPS SLEEP";
        self.detailLabel.textColor = blueColor;
    }
}

- (void)updateDebugWithFPS:(int)fps durationMs:(double)ms state:(GovernorStateTheos)state {
    [self ensureSceneAttachment];

    if (CACurrentMediaTime() - _lastFlashTime < 0.5) return;

    CFTimeInterval now = CACurrentMediaTime();
    self.fpsLabel.text = [NSString stringWithFormat:@"%d FPS (%.1fms)", fps, ms];

    if (s_theosMode == FPSModeTheosLock120) {
        self.stateLabel.text = @"[LCK]";
        UIColor *purpleColor = [UIColor colorWithRed:0.88f green:0.25f blue:0.98f alpha:1.0f];
        self.stateLabel.textColor = purpleColor;
        self.layer.borderColor = purpleColor.CGColor;
        self.detailLabel.text = @"MODE:LOCK120 | CONSTANT 120";
        self.detailLabel.textColor = purpleColor;
    } else if (state == GovernorStateTheosActive) {
        UIColor *greenColor = [UIColor colorWithRed:0.0f green:0.9f blue:0.46f alpha:1.0f];
        self.stateLabel.text = @"[ACT]";
        self.stateLabel.textColor = greenColor;
        self.layer.borderColor = greenColor.CGColor;

        if (s_theosIsInteracting) {
            self.detailLabel.text = @"MODE:AUTO | TOUCH CONTACT (120Hz)";
        } else {
            double remaining = (1.0 - (now - s_theosLastMovementTime)) * 1000.0;
            if (remaining < 0) remaining = 0;
            self.detailLabel.text = [NSString stringWithFormat:@"MODE:AUTO | SETTLING (%.0fms)", remaining];
        }
        self.detailLabel.textColor = [UIColor colorWithWhite:0.85f alpha:1.0f];
    } else {
        UIColor *blueColor = [UIColor colorWithRed:0.0f green:0.75f blue:1.0f alpha:1.0f];
        self.stateLabel.text = @"[IDL]";
        self.stateLabel.textColor = blueColor;
        self.layer.borderColor = blueColor.CGColor;

        double idleSeconds = now - s_theosLastMovementTime;
        self.detailLabel.text = [NSString stringWithFormat:@"MODE:AUTO | 30FPS SLEEP (IDLE %.1fs)", idleSeconds];
        self.detailLabel.textColor = blueColor;
    }
}

@end

#pragma mark - Heartbeat DisplayLink Driver (Theos)

@interface HighFPSDriverTheos : NSObject
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval lastHUDTime;
+ (instancetype)sharedInstance;
- (void)start;
- (void)resume;
- (void)pause;
@end

@implementation HighFPSDriverTheos

+ (instancetype)sharedInstance {
    static HighFPSDriverTheos *driver = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        driver = [[HighFPSDriverTheos alloc] init];
    });
    return driver;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(start) name:UIApplicationDidFinishLaunchingNotification object:nil];
        [nc addObserver:self selector:@selector(resume) name:UIApplicationDidBecomeActiveNotification object:nil];
        [nc addObserver:self selector:@selector(pause) name:UIApplicationWillResignActiveNotification object:nil];
        [nc addObserver:self selector:@selector(pause) name:UIApplicationDidEnterBackgroundNotification object:nil];
    }
    return self;
}

- (void)onDisplayLinkTick:(CADisplayLink *)link {
    if (@available(iOS 15.0, *)) {
        link.preferredFrameRateRange = GetTheosRange();
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _lastHUDTime >= 0.05) {
        _lastHUDTime = now;
        CFTimeInterval duration = link.targetTimestamp - link.timestamp;
        double ms = (duration > 0.0001) ? (duration * 1000.0) : 8.33;
        int currentFPS = (duration > 0.001) ? (int)lround(1.0 / duration) : 120;
        [[FPSOverlayWindowTheos sharedInstance] updateDebugWithFPS:currentFPS durationMs:ms state:s_theosCurrentState];
    }
}

- (void)start {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self start];
        });
        return;
    }
    [FPSOverlayWindowTheos sharedInstance];
    if (self.displayLink) {
        self.displayLink.paused = NO;
        return;
    }
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayLinkTick:)];
    if (@available(iOS 15.0, *)) {
        self.displayLink.preferredFrameRateRange = GetTheosRange();
    }
    if ([self.displayLink respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        self.displayLink.preferredFramesPerSecond = FPS_HIGH_INT;
    }
    if ([self.displayLink respondsToSelector:@selector(setFrameInterval:)]) {
        self.displayLink.frameInterval = 1;
    }
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)resume {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self resume];
        });
        return;
    }
    if (self.displayLink) {
        self.displayLink.paused = NO;
    } else {
        [self start];
    }
}

- (void)pause {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self pause];
        });
        return;
    }
    if (self.displayLink) {
        self.displayLink.paused = YES;
    }
}

@end

#pragma mark - Hooks

%hook CADisplayLink

+ (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)sel {
    CADisplayLink *link = %orig(target, sel);
    if (link) {
        if (@available(iOS 15.0, *)) {
            link.preferredFrameRateRange = GetTheosRange();
        }
        if ([link respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
            link.preferredFramesPerSecond = (NSInteger)GetTheosTargetFPS();
        }
        if ([link respondsToSelector:@selector(setFrameInterval:)]) {
            link.frameInterval = 1;
        }
    }
    return link;
}

- (void)addToRunLoop:(NSRunLoop *)runloop forMode:(NSRunLoopMode)mode {
    if (@available(iOS 15.0, *)) {
        self.preferredFrameRateRange = GetTheosRange();
    }
    if ([self respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        self.preferredFramesPerSecond = (NSInteger)GetTheosTargetFPS();
    }
    if ([self respondsToSelector:@selector(setFrameInterval:)]) {
        self.frameInterval = 1;
    }
    %orig(runloop, mode);
}

- (void)setFrameInterval:(NSInteger)interval {
    %orig(1);
    if ([self respondsToSelector:@selector(setPreferredFramesPerSecond:)])
        self.preferredFramesPerSecond = (NSInteger)GetTheosTargetFPS();
}

- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    %orig((NSInteger)GetTheosTargetFPS());
}

- (NSInteger)preferredFramesPerSecond {
    return (NSInteger)GetTheosTargetFPS();
}

- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    %orig(GetTheosRange());
}

- (CAFrameRateRange)preferredFrameRateRange {
    return GetTheosRange();
}

%end

%hook UIScrollView

- (void)setContentOffset:(CGPoint)contentOffset {
    if (self.isDragging || self.isDecelerating) {
        s_theosLastMovementTime = CACurrentMediaTime();
    }
    %orig(contentOffset);
}

- (void)_setFrameRateRange:(CAFrameRateRange)range {
    s_theosLastMovementTime = CACurrentMediaTime();
    %orig(GetTheosRange());
}

- (CAFrameRateRange)_frameRateRange {
    return GetTheosRange();
}

%end

%hook UIGestureRecognizer

- (void)_setFrameRateRange:(CAFrameRateRange)range {
    s_theosLastMovementTime = CACurrentMediaTime();
    %orig(GetTheosRange());
}

- (CAFrameRateRange)_frameRateRange {
    return GetTheosRange();
}

%end

%hook UIWindow

- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches) {
        NSSet *touches = [event allTouches];
        for (UITouch *touch in touches) {
            if (touch.phase == UITouchPhaseBegan) {
                // Way 2: Pre-emptive 120Hz trigger the microsecond skin touches glass
                s_theosIsInteracting = YES;
                s_theosLastMovementTime = CACurrentMediaTime();
                break;
            } else if (touch.phase == UITouchPhaseMoved) {
                s_theosIsInteracting = YES;
                s_theosLastMovementTime = CACurrentMediaTime();
                break;
            } else if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                s_theosIsInteracting = NO;
                s_theosLastMovementTime = CACurrentMediaTime();
            }
        }
    }
    %orig(event);
}

%end

%hook CAAnimation

- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    @try {
        %orig(GetTheosRange());
    } @catch (NSException *e) {
    }
}

- (CAFrameRateRange)preferredFrameRateRange {
    return GetTheosRange();
}

%end

%hook CALayer

- (void)addAnimation:(CAAnimation *)anim forKey:(NSString *)key {
    if (anim && [anim respondsToSelector:@selector(setPreferredFrameRateRange:)]) {
        @try {
            anim.preferredFrameRateRange = GetTheosRange();
            %orig(anim, key);
            return;
        } @catch (NSException *exception) {
            @try {
                CAAnimation *mutableAnim = [anim copy];
                if (mutableAnim && [mutableAnim respondsToSelector:@selector(setPreferredFrameRateRange:)]) {
                    mutableAnim.preferredFrameRateRange = GetTheosRange();
                    %orig(mutableAnim, key);
                    return;
                }
            } @catch (NSException *copyEx) {
            }
        }
    }
    %orig(anim, key);
}

- (void)_setFrameRateRange:(CAFrameRateRange)range {
    @try {
        %orig(GetTheosRange());
    } @catch (NSException *e) {
    }
}

- (CAFrameRateRange)_frameRateRange {
    return GetTheosRange();
}

%end

%hook UIScreen

- (NSInteger)maximumFramesPerSecond {
    NSInteger orig = %orig;
    return (orig > FPS_HIGH_INT) ? orig : FPS_HIGH_INT;
}

- (CFTimeInterval)minimumFrameDuration {
    return (1.0 / FPS_HIGH);
}

%end

%hook CAMetalLayer

- (NSUInteger)maximumDrawableCount {
    return 3;
}

- (void)setMaximumDrawableCount:(NSUInteger)count {
    %orig(3);
}

%end

%hook CAMetalDrawable

- (void)presentAfterMinimumDuration:(CFTimeInterval)duration {
    %orig(1.0 / FPS_HIGH);
}

%end

%hook MTLCommandBuffer

- (void)presentDrawable:(id)drawable afterMinimumDuration:(CFTimeInterval)minimumDuration {
    %orig(drawable, 1.0 / FPS_HIGH);
}

%end

%hook NSBundle

- (id)objectForInfoDictionaryKey:(NSString *)key {
    if ([key isEqualToString:@"CADisableMinimumFrameDurationOnPhone"] ||
        [key isEqualToString:@"CADisableMinimumFrameDuration"]) {
        return @YES;
    }
    return %orig(key);
}

%end

#pragma mark - Constructor

%ctor {
    %init;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[HighFPSDriverTheos sharedInstance] start];
    });
}

#pragma clang diagnostic pop
