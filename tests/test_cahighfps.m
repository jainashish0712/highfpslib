#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <assert.h>
#include <stdio.h>

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

// Forward declarations from CAHighFPS
@interface HighFPSDriver : NSObject
+ (instancetype)sharedInstance;
- (void)start;
- (void)pause;
- (void)resume;
- (void)stop;
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        printf("========================================\n");
        printf("Running CAHighFPS Runtime Verification Tests\n");
        printf("========================================\n\n");

        // TEST 1: NSBundle Hook Verification (The crash culprit)
        printf("[Test 1] Testing NSBundle ProMotion Keys & Info Dictionary...\n");
        NSBundle *bundle = [NSBundle mainBundle];
        id val1 = [bundle objectForInfoDictionaryKey:@"CADisableMinimumFrameDurationOnPhone"];
        assert(val1 != nil && [val1 boolValue] == YES);
        printf("  ✓ CADisableMinimumFrameDurationOnPhone returns YES\n");

        id val2 = [bundle objectForInfoDictionaryKey:@"CADisableMinimumFrameDuration"];
        assert(val2 != nil && [val2 boolValue] == YES);
        printf("  ✓ CADisableMinimumFrameDuration returns YES\n");

        // CRITICAL CHECK: infoDictionary must NOT crash with __NSFrozenDictionaryM unrecognized selector!
        NSDictionary *dict = [bundle infoDictionary];
        printf("  ✓ [NSBundle infoDictionary] called successfully without crash (returned class: %s)\n",
               dict ? object_getClassName(dict) : "nil");

        // TEST 2: CAAnimation Hook Verification
        printf("\n[Test 2] Testing CAAnimation 120Hz Lock...\n");
        CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"opacity"];
        if ([anim respondsToSelector:@selector(setPreferredFrameRateRange:)]) {
            [anim setValue:[NSValue valueWithBytes:&(CAFrameRateRange){30.0f, 60.0f, 60.0f}
                                          objCType:@encode(CAFrameRateRange)]
                    forKey:@"preferredFrameRateRange"];
            
            CAFrameRateRange range = {0};
            [[anim valueForKey:@"preferredFrameRateRange"] getValue:&range];
            assert(range.minimum == 120.0f);
            assert(range.maximum == 120.0f);
            assert(range.preferred == 120.0f);
            printf("  ✓ CAAnimation preferredFrameRateRange locked to 120/120/120\n");
        } else {
            printf("  - CAAnimation does not support preferredFrameRateRange on this OS SDK\n");
        }

        // TEST 3: HighFPSDriver Lifecycle
        printf("\n[Test 3] Testing HighFPSDriver Lifecycle...\n");
        HighFPSDriver *driver = [HighFPSDriver sharedInstance];
        assert(driver != nil);
        [driver start];
        [driver pause];
        [driver resume];
        [driver stop];
        printf("  ✓ HighFPSDriver start/pause/resume/stop executed cleanly without crash\n");

        // TEST 4: CAMetalLayer Triple Buffering
        printf("\n[Test 4] Testing CAMetalLayer Maximum Drawable Count...\n");
        Class metalClass = objc_getClass("CAMetalLayer");
        if (metalClass) {
            id metalLayer = [[metalClass alloc] init];
            if ([metalLayer respondsToSelector:@selector(maximumDrawableCount)]) {
                NSUInteger (*msgSendFunc)(id, SEL) = (NSUInteger (*)(id, SEL))objc_msgSend;
                NSUInteger count = msgSendFunc(metalLayer, @selector(maximumDrawableCount));
                assert(count == 3);
                printf("  ✓ CAMetalLayer maximumDrawableCount correctly returns 3 (triple buffering)\n");
            }
        } else {
            printf("  - CAMetalLayer not present on this host environment\n");
        }

        printf("\n========================================\n");
        printf("ALL TESTS PASSED SUCCESSFULLY! No crashes detected.\n");
        printf("========================================\n");
    }
    return 0;
}
