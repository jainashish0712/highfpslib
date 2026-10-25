#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#ifndef CAFrameRateRange_DEFINED
typedef struct CAFrameRateRange {
    float minimum;
    float maximum;
    float preferred;
} CAFrameRateRange;
#endif

#ifndef CAFrameRateRangeMake
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

#define domain CFSTR("com.apple.UIKit")
#define whitelistKey CFSTR("CAHighFPS")
#define systemWideKey CFSTR("CAHighFPSSystemWide")
#define blacklistKey CFSTR("CAHighFPSBlacklist")
#define customFPSKey CFSTR("CAHighFPSCustomFPS")

@interface CAMetalLayer (Private)
@property (assign) CGFloat drawableTimeoutSeconds;
@end

static NSInteger maxFPS = -1;
static NSInteger customFPS = 0;
static BOOL systemWide = YES; // Default to YES so injected apps automatically work
static NSArray<NSString *> *whitelist;
static NSArray<NSString *> *blacklist;

static id copyPrefValue(CFStringRef prefKey) {
    CFTypeRef value = CFPreferencesCopyAppValue(prefKey, domain);
    if (value == NULL)
        value = CFPreferencesCopyValue(prefKey, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    return value ? (__bridge_transfer id)value : nil;
}

static void loadPreferences() {
    id systemWideValue = copyPrefValue(systemWideKey);
    if (systemWideValue && [systemWideValue isKindOfClass:[NSNumber class]]) {
        systemWide = [systemWideValue boolValue];
    } else {
        systemWide = YES; // Sandboxed/injected fallback
    }

    id whitelistValue = copyPrefValue(whitelistKey);
    whitelist = [whitelistValue isKindOfClass:[NSArray class]] ? whitelistValue : nil;

    id blacklistValue = copyPrefValue(blacklistKey);
    blacklist = [blacklistValue isKindOfClass:[NSArray class]] ? blacklistValue : nil;

    id customFPSValue = copyPrefValue(customFPSKey);
    customFPS = [customFPSValue isKindOfClass:[NSNumber class]] ? (NSInteger)lround([customFPSValue doubleValue]) : 0;
}

static NSInteger getMaxFPS() {
    if (maxFPS == -1) {
        NSInteger screenMax = [UIScreen mainScreen].maximumFramesPerSecond;
        maxFPS = (screenMax >= TARGET_FPS_INT) ? screenMax : TARGET_FPS_INT;
    }
    return maxFPS;
}

static NSInteger getTargetFPS() {
    NSInteger max = getMaxFPS();
    if (customFPS <= 0 || customFPS >= max)
        return max;
    return customFPS;
}

static BOOL usesCustomFPS() {
    NSInteger max = getMaxFPS();
    return customFPS > 0 && customFPS < max;
}

static BOOL shouldEnableForBundleIdentifier(NSString *bundleIdentifier) {
    if (!bundleIdentifier) return YES;
    if ([bundleIdentifier isEqualToString:@"com.apple.springboard"])
        return NO;
    if (systemWide)
        return ![blacklist containsObject:bundleIdentifier];
    if (whitelist && whitelist.count > 0)
        return [whitelist containsObject:bundleIdentifier];
    return YES; // Default enabled when injected into an IPA
}

#pragma mark - Info.plist Injection

static void injectPlistKeys(void) {
    CFBundleRef mainBundle = CFBundleGetMainBundle();
    if (mainBundle) {
        CFMutableDictionaryRef infoDict = (CFMutableDictionaryRef)CFBundleGetInfoDictionary(mainBundle);
        if (infoDict) {
            CFDictionarySetValue(infoDict, CFSTR("CADisableMinimumFrameDurationOnPhone"), kCFBooleanTrue);
            CFDictionarySetValue(infoDict, CFSTR("CADisableMinimumFrameDuration"), kCFBooleanTrue);
        }
    }
}

#pragma mark - Heartbeat DisplayLink Driver

@interface HighFPSDriverTheos : NSObject
@property (nonatomic, strong) CADisplayLink *displayLink;
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

- (void)onDisplayLinkTick:(CADisplayLink *)link {}

- (void)start {
    if (self.displayLink) {
        self.displayLink.paused = NO;
        return;
    }
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayLinkTick:)];
    NSInteger target = getTargetFPS();
    if (@available(iOS 15.0, *)) {
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(target, target, target);
    }
    if ([self.displayLink respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        self.displayLink.preferredFramesPerSecond = target;
    }
    if ([self.displayLink respondsToSelector:@selector(setFrameInterval:)]) {
        self.displayLink.frameInterval = 1;
    }
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

@end

#pragma mark - CADisplayLink Hooks

%hook CADisplayLink

- (void)setFrameInterval:(NSInteger)interval {
    %orig(1);
    if ([self respondsToSelector:@selector(setPreferredFramesPerSecond:)])
        self.preferredFramesPerSecond = getTargetFPS();
}

- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    %orig(getTargetFPS());
}

- (NSInteger)preferredFramesPerSecond {
    return getTargetFPS();
}

- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    NSInteger target = getTargetFPS();
    // Force minimum = target (120) so iOS ProMotion cannot downclock to 80Hz/90Hz
    range.minimum = target;
    range.preferred = target;
    range.maximum = target;
    %orig(range);
}

- (CAFrameRateRange)preferredFrameRateRange {
    NSInteger target = getTargetFPS();
    return CAFrameRateRangeMake(target, target, target);
}

%end

#pragma mark - CAAnimation Hooks

%hook CAAnimation

- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    NSInteger target = getTargetFPS();
    range.minimum = target;
    range.preferred = target;
    range.maximum = target;
    %orig(range);
}

- (CAFrameRateRange)preferredFrameRateRange {
    NSInteger target = getTargetFPS();
    return CAFrameRateRangeMake(target, target, target);
}

%end

#pragma mark - UIScreen Hooks

%hook UIScreen

- (NSInteger)maximumFramesPerSecond {
    NSInteger orig = %orig;
    return (orig > TARGET_FPS_INT) ? orig : TARGET_FPS_INT;
}

- (CFTimeInterval)minimumFrameDuration {
    return (1.0 / getTargetFPS());
}

%end

#pragma mark - CAMetalLayer Hooks

%hook CAMetalLayer

- (NSUInteger)maximumDrawableCount {
    return 3;
}

- (void)setMaximumDrawableCount:(NSUInteger)count {
    %orig(3);
}

%end

#pragma mark - Metal Presentation Hooks

%hook CAMetalDrawable

- (void)presentAfterMinimumDuration:(CFTimeInterval)duration {
    %orig(1.0 / getTargetFPS());
}

%end

%hook MTLCommandBuffer

- (void)presentDrawable:(id)drawable afterMinimumDuration:(CFTimeInterval)minimumDuration {
    %orig(drawable, 1.0 / getTargetFPS());
}

%end

#pragma mark - NSBundle Hooks

%hook NSBundle

- (id)objectForInfoDictionaryKey:(NSString *)key {
    if ([key isEqualToString:@"CADisableMinimumFrameDurationOnPhone"] ||
        [key isEqualToString:@"CADisableMinimumFrameDuration"]) {
        return @YES;
    }
    return %orig(key);
}

- (NSDictionary *)infoDictionary {
    NSDictionary *dict = %orig;
    if (dict && (!dict[@"CADisableMinimumFrameDurationOnPhone"] || !dict[@"CADisableMinimumFrameDuration"])) {
        NSMutableDictionary *mDict = [dict mutableCopy];
        mDict[@"CADisableMinimumFrameDurationOnPhone"] = @YES;
        mDict[@"CADisableMinimumFrameDuration"] = @YES;
        return [mDict copy];
    }
    return dict;
}

%end

#pragma mark - Constructor

%ctor {
    injectPlistKeys();
    loadPreferences();
    if (shouldEnableForBundleIdentifier(NSBundle.mainBundle.bundleIdentifier)) {
        %init;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[HighFPSDriverTheos sharedInstance] start];
        });
    }
}
