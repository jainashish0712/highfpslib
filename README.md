# CAHighFPS (Force 120 FPS / 120 Hz ProMotion)

Forces iOS applications (such as Instagram) to run at a continuous, locked **120 FPS / 120 Hz** on ProMotion-enabled devices (iPhone 13 Pro, 14 Pro, 15 Pro, 16 Pro, iPad Pro) without fluctuating or dropping down to 80Hz/90Hz during scrolling, inertial deceleration, or idle feed reading.

---

## Why Instagram Fluctuated to 80Hz / 90Hz (Root Cause)

1. **Adaptive Power-Saving Governor:**
   By default, Apple's ProMotion compositor (`backboardd` / `QuartzCore`) aggressively drops display refresh rates down to 80Hz or 90Hz when scrolling at regular speeds, during scroll deceleration, or during subtle UI transitions.

2. **The `minimum` Frame Rate Flaw:**
   When apps or generic tweaks request ProMotion via `CAFrameRateRange`, they often set:
   ```objc
   CAFrameRateRange range = CAFrameRateRangeMake(30, 120, 120); // or (80, 120, 120)
   ```
   Because `minimum` is set to 30 or 80, the iOS compositor is explicitly allowed to downclock the display to 80Hz or 90Hz whenever it perceives low motion or deceleration.

3. **DisplayLink Inactivity / Gaps:**
   When scrolling stops or when Instagram pauses its internal render callbacks, no active `CADisplayLink` is voting for 120Hz, causing the system compositor to immediately drop the refresh rate.

4. **Double Buffering Bottlenecks in Metal:**
   Using `maximumDrawableCount = 2` (double buffering) causes frame drops and pipeline hitches at 120Hz if GPU rendering slightly exceeds 8.33ms. Triple buffering (`maximumDrawableCount = 3`) is required for fluid 120Hz ProMotion pacing.

5. **`CADisableMinimumFrameDurationOnPhone` Missing:**
   Third-party IPAs default to a 60Hz limit unless `CADisableMinimumFrameDurationOnPhone` is explicitly injected into `Info.plist`.

---

## How This Implementation Locks 120Hz Always

- **Zero-Dependency Native Swizzling (`CAHighFPS.m`):**
  Uses pure Objective-C runtime method swizzling (`objc/runtime.h`). It does **not** link against CydiaSubstrate or ElleKit, meaning the `.dylib` can be injected directly into any sideloaded IPA without crashing on launch.
- **Strict `minimum = 120.0f` Enforcement:**
  All calls to `-[CADisplayLink setPreferredFrameRateRange:]` and `-[CAAnimation setPreferredFrameRateRange:]` are locked to `CAFrameRateRangeMake(120.0f, 120.0f, 120.0f)`. The compositor is never permitted to drop below 120Hz.
- **Dedicated Keep-Alive Heartbeat Driver:**
  A dedicated background `CADisplayLink` runs on `[NSRunLoop mainRunLoop]` for `NSRunLoopCommonModes` (covering both default and tracking/scrolling modes). This permanently asserts a 120Hz minimum request to `backboardd`, preventing any downclocking during slow scroll or deceleration.
- **Auto-Paused in Background:**
  The heartbeat driver pauses when the app goes into the background (`UIApplicationDidEnterBackgroundNotification` / `UIApplicationWillResignActiveNotification`) and resumes when active, preventing background battery drain.
- **Dynamic Bundle Info Interception (Safe, Read-Only):**
  Intercepts `-[NSBundle objectForInfoDictionaryKey:]` in a read-only, thread-safe manner to report `CADisableMinimumFrameDurationOnPhone = YES` without mutating the bundle's internal frozen dictionary.
- **Metal Triple Buffering:**
  Forces `CAMetalLayer.maximumDrawableCount = 3` and clamps minimum presentation intervals to `1.0 / 120.0s`.

---

## Building the .dylib with GitHub Actions

This repository includes a pre-configured GitHub Actions workflow in [`.github/workflows/build.yml`](.github/workflows/build.yml).

### Automated Workflow:
- Triggers automatically on **every push to any branch**, pull request, and tag.
- Automatically compiles and executes runtime verification tests (`tests/test_cahighfps.m`) to catch regressions and prevent runtime crashes.
- Compiles a universal `arm64` + `arm64e` binary for iOS 15.0+.
- Automatically attaches **`CAHighFPS.dylib`** directly to the GitHub Release.

---

## Injecting into Instagram IPA

You can inject `CAHighFPS.dylib` into your Instagram `.ipa` using any standard injection tool:

### Method 1: Using Sideloadly
1. Open Sideloadly and select your `Instagram.ipa`.
2. Click **Advanced Options**.
3. Under **Inject dylibs/frameworks**, click **+** and select `CAHighFPS.dylib`.
4. Choose **Cydia Substrate / Substitute: No (Standalone)** or default.
5. Click **Start** to sign and install.

### Method 2: Using TrollStore / Esign / Feather
1. Import `Instagram.ipa` and `CAHighFPS.dylib` into Esign or Feather.
2. Select the IPA -> **Signature / More** -> **Add Dylib** -> Select `CAHighFPS.dylib`.
3. Sign and install with TrollStore or your certificate.

### Method 3: Using Azule (macOS / Linux / CLI)
```bash
azule -i Instagram.ipa -o Instagram_120Hz.ipa -f CAHighFPS.dylib
```
