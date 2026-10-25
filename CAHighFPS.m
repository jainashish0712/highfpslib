#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <objc/message.h>

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

#define TARGET_FPS 120.0f
#define TARGET_FPS_INT 120
#define TARGET_DURATION (1.0 / TARGET_FPS)

#pragma mark - Method Swizzling Utility

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

#pragma mark - Info.plist ProMotion Injection

static void InjectPlistKeys(void) {
    CFBundleRef mainBundle = CFBundleGetMainBundle();
    if (mainBundle) {
        CFMutableDictionaryRef infoDict = (CFMutableDictionaryRef)CFBundleGetInfoDictionary(mainBundle);
        if (infoDict) {
            CFDictionarySetValue(infoDict, CFSTR("CADisableMinimumFrameDurationOnPhone"), kCFBooleanTrue);
            CFDictionarySetValue(infoDict, CFSTR("CADisableMinimumFrameDuration"), kCFBooleanTrue);
        }
    }
}

#pragma mark - Heartbeat DisplayLink Driver (Prevents 80Hz/90Hz Fluctuation)

@interface HighFPSDriver : NSObject
@property (nonatomic, strong) CADisplayLink *displayLink;
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
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self
               selector:@selector(start)
                   name:UIApplicationDidFinishLaunchingNotification
                 object:nil];
        [nc addObserver:self
               selector:@selector(resume)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];
        [nc addObserver:self
               selector:@selector(pause)
                   name:UIApplicationWillResignActiveNotification
                 object:nil];
        [nc addObserver:self
               selector:@selector(pause)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
    }
    return self;
}

- (void)onDisplayLinkTick:(CADisplayLink *)link {
    // Keep-alive heartbeat: an active CADisplayLink with min=120, max=120, pref=120
    // on NSRunLoopCommonModes ensures backboardd/QuartzCore never throttles down to 80Hz/90Hz.
}

- (void)start {
    if (self.displayLink) {
        self.displayLink.paused = NO;
        return;
    }

    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayLinkTick:)];

    if (@available(iOS 15.0, *)) {
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(TARGET_FPS, TARGET_FPS, TARGET_FPS);
    }

    if ([self.displayLink respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        self.displayLink.preferredFramesPerSecond = TARGET_FPS_INT;
    }
    if ([self.displayLink respondsToSelector:@selector(setFrameInterval:)]) {
        self.displayLink.frameInterval = 1;
    }

    // Adding to NSRunLoopCommonModes covers both NSDefaultRunLoopMode and UITrackingRunLoopMode (scrolling)
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)resume {
    if (self.displayLink) {
        self.displayLink.paused = NO;
    } else {
        [self start];
    }
}

- (void)pause {
    if (self.displayLink) {
        self.displayLink.paused = YES;
    }
}

- (void)stop {
    if (self.displayLink) {
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
}

@end

#pragma mark - CADisplayLink Hooks

@interface CADisplayLink (HighFPS)
@end

@implementation CADisplayLink (HighFPS)

- (void)highfps_setPreferredFrameRateRange:(CAFrameRateRange)range {
    // Force minimum, maximum, and preferred to 120 so the compositor cannot downclock
    CAFrameRateRange lockedRange = CAFrameRateRangeMake(TARGET_FPS, TARGET_FPS, TARGET_FPS);
    [self highfps_setPreferredFrameRateRange:lockedRange];
}

- (CAFrameRateRange)highfps_preferredFrameRateRange {
    return CAFrameRateRangeMake(TARGET_FPS, TARGET_FPS, TARGET_FPS);
}

- (void)highfps_setPreferredFramesPerSecond:(NSInteger)fps {
    [self highfps_setPreferredFramesPerSecond:TARGET_FPS_INT];
}

- (NSInteger)highfps_preferredFramesPerSecond {
    return TARGET_FPS_INT;
}

- (void)highfps_setFrameInterval:(NSInteger)interval {
    [self highfps_setFrameInterval:1];
}

- (NSInteger)highfps_frameInterval {
    return 1;
}

@end

#pragma mark - CAAnimation Hooks

@interface CAAnimation (HighFPS)
@end

@implementation CAAnimation (HighFPS)

- (void)highfps_setPreferredFrameRateRange:(CAFrameRateRange)range {
    CAFrameRateRange lockedRange = CAFrameRateRangeMake(TARGET_FPS, TARGET_FPS, TARGET_FPS);
    [self highfps_setPreferredFrameRateRange:lockedRange];
}

- (CAFrameRateRange)highfps_preferredFrameRateRange {
    return CAFrameRateRangeMake(TARGET_FPS, TARGET_FPS, TARGET_FPS);
}

@end

#pragma mark - UIScreen Hooks

@interface UIScreen (HighFPS)
@end

@implementation UIScreen (HighFPS)

- (NSInteger)highfps_maximumFramesPerSecond {
    NSInteger orig = [self highfps_maximumFramesPerSecond];
    return (orig > TARGET_FPS_INT) ? orig : TARGET_FPS_INT;
}

- (CFTimeInterval)highfps_minimumFrameDuration {
    return TARGET_DURATION;
}

@end

#pragma mark - CAMetalLayer Hooks

@interface CAMetalLayer (HighFPS)
@end

@implementation CAMetalLayer (HighFPS)

- (NSUInteger)highfps_maximumDrawableCount {
    // Triple buffering (3 drawables) is required at 120Hz to prevent GPU pipeline stalls
    // that cause drops to 80/90Hz.
    return 3;
}

- (void)highfps_setMaximumDrawableCount:(NSUInteger)count {
    [self highfps_setMaximumDrawableCount:3];
}

@end

#pragma mark - NSBundle Hooks

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

- (NSDictionary *)highfps_infoDictionary {
    NSDictionary *dict = [self highfps_infoDictionary];
    if (dict && (!dict[@"CADisableMinimumFrameDurationOnPhone"] || !dict[@"CADisableMinimumFrameDuration"])) {
        NSMutableDictionary *mDict = [dict mutableCopy];
        mDict[@"CADisableMinimumFrameDurationOnPhone"] = (id)kCFBooleanTrue;
        mDict[@"CADisableMinimumFrameDuration"] = (id)kCFBooleanTrue;
        return [mDict copy];
    }
    return dict;
}

@end

#pragma mark - Metal Presentation Hooks

static void (*orig_presentAfterMinimumDuration)(id self, SEL _cmd, CFTimeInterval duration);
static void highfps_presentAfterMinimumDuration(id self, SEL _cmd, CFTimeInterval duration) {
    if (orig_presentAfterMinimumDuration) {
        orig_presentAfterMinimumDuration(self, _cmd, TARGET_DURATION);
    }
}

static void (*orig_presentDrawable_afterMinimumDuration)(id self, SEL _cmd, id drawable, CFTimeInterval duration);
static void highfps_presentDrawable_afterMinimumDuration(id self, SEL _cmd, id drawable, CFTimeInterval duration) {
    if (orig_presentDrawable_afterMinimumDuration) {
        orig_presentDrawable_afterMinimumDuration(self, _cmd, drawable, TARGET_DURATION);
    }
}

#pragma mark - Initialization

static void InitSwizzling(void) {
    // 1. CADisplayLink
    Class dlClass = [CADisplayLink class];
    if (dlClass) {
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

    // 2. CAAnimation
    Class animClass = [CAAnimation class];
    if (animClass) {
        if (class_getInstanceMethod(animClass, @selector(setPreferredFrameRateRange:))) {
            SwizzleInstanceMethod(animClass, @selector(setPreferredFrameRateRange:), @selector(highfps_setPreferredFrameRateRange:));
            SwizzleInstanceMethod(animClass, @selector(preferredFrameRateRange), @selector(highfps_preferredFrameRateRange));
        }
    }

    // 3. UIScreen
    Class screenClass = [UIScreen class];
    if (screenClass) {
        if (class_getInstanceMethod(screenClass, @selector(maximumFramesPerSecond))) {
            SwizzleInstanceMethod(screenClass, @selector(maximumFramesPerSecond), @selector(highfps_maximumFramesPerSecond));
        }
        if (class_getInstanceMethod(screenClass, @selector(minimumFrameDuration))) {
            SwizzleInstanceMethod(screenClass, @selector(minimumFrameDuration), @selector(highfps_minimumFrameDuration));
        }
    }

    // 4. CAMetalLayer
    Class metalLayerClass = objc_getClass("CAMetalLayer");
    if (metalLayerClass) {
        if (class_getInstanceMethod(metalLayerClass, @selector(maximumDrawableCount))) {
            SwizzleInstanceMethod(metalLayerClass, @selector(maximumDrawableCount), @selector(highfps_maximumDrawableCount));
        }
        if (class_getInstanceMethod(metalLayerClass, @selector(setMaximumDrawableCount:))) {
            SwizzleInstanceMethod(metalLayerClass, @selector(setMaximumDrawableCount:), @selector(highfps_setMaximumDrawableCount:));
        }
    }

    // 5. Metal Presentation Functions
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

    // 6. NSBundle
    Class bundleClass = [NSBundle class];
    if (bundleClass) {
        if (class_getInstanceMethod(bundleClass, @selector(objectForInfoDictionaryKey:))) {
            SwizzleInstanceMethod(bundleClass, @selector(objectForInfoDictionaryKey:), @selector(highfps_objectForInfoDictionaryKey:));
        }
        if (class_getInstanceMethod(bundleClass, @selector(infoDictionary))) {
            SwizzleInstanceMethod(bundleClass, @selector(infoDictionary), @selector(highfps_infoDictionary));
        }
    }
}

__attribute__((constructor))
static void CAHighFPS_Init(void) {
    // 1. Inject CADisableMinimumFrameDurationOnPhone into main bundle Info.plist dictionary
    InjectPlistKeys();

    // 2. Swizzle display, animation, and screen methods
    InitSwizzling();

    // 3. Start heartbeat driver on main runloop
    dispatch_async(dispatch_get_main_queue(), ^{
        [[HighFPSDriver sharedInstance] start];
    });

    NSLog(@"[CAHighFPS] Successfully loaded into %@ - 120Hz locked.", [NSBundle mainBundle].bundleIdentifier);
}

#pragma clang diagnostic pop
