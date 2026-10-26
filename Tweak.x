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
#define FPS_LOW 1.0f
#define FPS_HIGH_INT 120
#define FPS_LOW_INT 1

typedef NS_ENUM(NSInteger, FPSModeTheos) {
    FPSModeTheosAuto = 0,
    FPSModeTheosLock120 = 1
};

static FPSModeTheos s_theosMode = FPSModeTheosAuto;
static const CFTimeInterval s_theosCooldownOptions[] = { 0.45, 0.15, 0.25, 0.01 };
static const int s_theosNumCooldownOptions = 4;
static int s_theosCooldownIndex = 0;
static CFTimeInterval s_theosLastInteraction = 0.0;
static BOOL s_theosIsInteracting = NO;

static inline BOOL IsTheosScrollActive(void) {
    if (s_theosMode == FPSModeTheosLock120) return YES;
    if (s_theosIsInteracting) return YES;
    return (CACurrentMediaTime() - s_theosLastInteraction) < s_theosCooldownOptions[s_theosCooldownIndex];
}

static inline float GetTheosTargetFPS(void) {
    if (s_theosMode == FPSModeTheosLock120) return FPS_HIGH;
    return IsTheosScrollActive() ? FPS_HIGH : FPS_LOW;
}

static inline CAFrameRateRange GetTheosRange(void) {
    float fps = GetTheosTargetFPS();
    return CAFrameRateRangeMake(fps, fps, fps);
}

@interface CAMetalLayer (Private)
@property (assign) CGFloat drawableTimeoutSeconds;
@end

#pragma mark - Floating Dual-Meter (FPS + Cooldown) HUD Overlay (Theos)

@interface FPSOverlayWindowTheos : UIWindow
@property (nonatomic, strong) UILabel *fpsLabel;
@property (nonatomic, strong) UILabel *cooldownLabel;
@property (nonatomic, strong) UIView *separatorView;
@property (nonatomic, strong) UIPanGestureRecognizer *panGesture;
@property (nonatomic, strong) UITapGestureRecognizer *tapGesture;
@property (nonatomic, assign) CFTimeInterval lastFlashTime;
+ (instancetype)sharedInstance;
- (void)updateFPS:(int)fps;
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
    CGRect frame = CGRectMake(16, 60, 72, 24);
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 1000.0f;
        self.backgroundColor = [UIColor colorWithWhite:0.05f alpha:0.85f];
        self.layer.cornerRadius = 12.0f;
        self.layer.borderWidth = 1.5f;
        self.layer.borderColor = [UIColor colorWithRed:0.0f green:0.9f blue:0.4f alpha:1.0f].CGColor;
        self.layer.masksToBounds = YES;
        self.clipsToBounds = YES;

        _fpsLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 32, 24)];
        _fpsLabel.textAlignment = NSTextAlignmentCenter;
        _fpsLabel.font = [UIFont monospacedDigitSystemFontOfSize:9.0 weight:UIFontWeightBold];
        _fpsLabel.textColor = [UIColor whiteColor];
        _fpsLabel.text = @"120";
        _fpsLabel.adjustsFontSizeToFitWidth = YES;
        _fpsLabel.minimumScaleFactor = 0.5;
        [self addSubview:_fpsLabel];

        _separatorView = [[UIView alloc] initWithFrame:CGRectMake(32, 4, 1, 16)];
        _separatorView.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.25f];
        [self addSubview:_separatorView];

        _cooldownLabel = [[UILabel alloc] initWithFrame:CGRectMake(33, 0, 39, 24)];
        _cooldownLabel.textAlignment = NSTextAlignmentCenter;
        _cooldownLabel.font = [UIFont monospacedDigitSystemFontOfSize:8.5 weight:UIFontWeightBold];
        _cooldownLabel.textColor = [UIColor colorWithRed:1.0f green:0.82f blue:0.2f alpha:1.0f];
        _cooldownLabel.text = @"0.45s";
        _cooldownLabel.adjustsFontSizeToFitWidth = YES;
        _cooldownLabel.minimumScaleFactor = 0.5;
        [self addSubview:_cooldownLabel];

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
    CGPoint loc = [tap locationInView:self];
    if (loc.x <= 32.0f) {
        // Toggle FPS mode: Auto (0) <-> Locked 120 (1)
        s_theosMode = (s_theosMode + 1) % 2;

        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [haptic impactOccurred];
        }

        _lastFlashTime = CACurrentMediaTime();
        NSString *modeText = @"A";
        UIColor *borderColor = [UIColor colorWithRed:0.2f green:0.75f blue:1.0f alpha:1.0f]; // Blue for Auto
        if (s_theosMode == FPSModeTheosLock120) {
            modeText = @"120";
            borderColor = [UIColor colorWithRed:0.0f green:0.9f blue:0.4f alpha:1.0f]; // Green
        }
        self.fpsLabel.text = modeText;
        self.layer.borderColor = borderColor.CGColor;
    } else {
        // Toggle Cooldown meter: 0.45s -> 0.15s -> 0.25s -> 0.01s
        s_theosCooldownIndex = (s_theosCooldownIndex + 1) % s_theosNumCooldownOptions;

        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [haptic impactOccurred];
        }

        CFTimeInterval cd = s_theosCooldownOptions[s_theosCooldownIndex];
        self.cooldownLabel.text = [NSString stringWithFormat:@"%.2fs", cd];
    }
}

- (void)updateFPS:(int)fps {
    [self ensureSceneAttachment];

    if (CACurrentMediaTime() - _lastFlashTime < 0.6) return;
    self.fpsLabel.text = [NSString stringWithFormat:@"%d", fps];
    if (fps >= 100) {
        self.layer.borderColor = [UIColor colorWithRed:0.0f green:0.9f blue:0.4f alpha:1.0f].CGColor;
    } else {
        self.layer.borderColor = [UIColor colorWithRed:1.0f green:0.55f blue:0.0f alpha:1.0f].CGColor;
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
    if (now - _lastHUDTime >= 0.1) {
        _lastHUDTime = now;
        CFTimeInterval duration = link.targetTimestamp - link.timestamp;
        int currentFPS = (duration > 0.001) ? (int)lround(1.0 / duration) : 120;
        [[FPSOverlayWindowTheos sharedInstance] updateFPS:currentFPS];
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
        s_theosLastInteraction = CACurrentMediaTime();
    }
    %orig(contentOffset);
}

- (void)_setFrameRateRange:(CAFrameRateRange)range {
    s_theosLastInteraction = CACurrentMediaTime();
    %orig(GetTheosRange());
}

- (CAFrameRateRange)_frameRateRange {
    return GetTheosRange();
}

%end

%hook UIGestureRecognizer

- (void)_setFrameRateRange:(CAFrameRateRange)range {
    s_theosLastInteraction = CACurrentMediaTime();
    %orig(GetTheosRange());
}

- (CAFrameRateRange)_frameRateRange {
    return GetTheosRange();
}

%end

%hook UIWindow

- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches) {
        s_theosLastInteraction = CACurrentMediaTime();
        NSSet *touches = [event allTouches];
        for (UITouch *touch in touches) {
            if (touch.phase == UITouchPhaseBegan || touch.phase == UITouchPhaseMoved) {
                s_theosIsInteracting = YES;
                break;
            } else if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                s_theosIsInteracting = NO;
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
    return (1.0 / GetTheosTargetFPS());
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
    %orig(1.0 / GetTheosTargetFPS());
}

%end

%hook MTLCommandBuffer

- (void)presentDrawable:(id)drawable afterMinimumDuration:(CFTimeInterval)minimumDuration {
    %orig(drawable, 1.0 / GetTheosTargetFPS());
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
