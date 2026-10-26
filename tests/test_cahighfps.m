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

        // TEST 1: NSBundle Hook Verification
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
        printf("\n[Test 2] Testing CAAnimation Dynamic Rate Enforcement...\n");
        CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"opacity"];
        if ([anim respondsToSelector:@selector(setPreferredFrameRateRange:)]) {
            [anim setValue:[NSValue valueWithBytes:&(CAFrameRateRange){30.0f, 60.0f, 60.0f}
                                          objCType:@encode(CAFrameRateRange)]
                    forKey:@"preferredFrameRateRange"];
            
            CAFrameRateRange range = {0};
            [[anim valueForKey:@"preferredFrameRateRange"] getValue:&range];
            // Must not be 30 or 80 or 90
            assert(range.minimum == 120.0f || range.minimum == 1.0f);
            assert(range.maximum == range.minimum);
            assert(range.preferred == range.minimum);
            printf("  ✓ CAAnimation preferredFrameRateRange locked (no 80/90Hz allowed, strictly %gHz)\n", range.minimum);
        } else {
            printf("  - CAAnimation does not support preferredFrameRateRange on this OS SDK\n");
        }

        // TEST 3: CALayer Animation Interception
        printf("\n[Test 3] Testing CALayer addAnimation:forKey: Enforcement...\n");
        CALayer *testLayer = [[CALayer alloc] init];
        CABasicAnimation *scrollAnim = [CABasicAnimation animationWithKeyPath:@"bounds.origin"];
        [testLayer addAnimation:scrollAnim forKey:@"scrollDecel"];
        if ([scrollAnim respondsToSelector:@selector(preferredFrameRateRange)]) {
            CAFrameRateRange range = {0};
            [[scrollAnim valueForKey:@"preferredFrameRateRange"] getValue:&range];
            assert(range.minimum == 120.0f || range.minimum == 1.0f);
            printf("  ✓ CALayer addAnimation:forKey: successfully locks frame rate on added animations\n");
        }

        // TEST 4: HighFPSDriver Lifecycle
        printf("\n[Test 4] Testing HighFPSDriver Lifecycle...\n");
        HighFPSDriver *driver = [HighFPSDriver sharedInstance];
        assert(driver != nil);
        [driver start];
        [driver pause];
        [driver resume];
        [driver stop];
        printf("  ✓ HighFPSDriver start/pause/resume/stop executed cleanly without crash\n");

        // TEST 5: CAMetalLayer Triple Buffering
        printf("\n[Test 5] Testing CAMetalLayer Maximum Drawable Count...\n");
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
