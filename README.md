# CAHighFPS (Pixel-Style 120Hz/60Hz Refresh Rate Governor & HUD)

Forces iOS applications (such as Instagram) to adopt **Google Pixel-style Smooth Display management**:
- **Active Scrolling & Touching**: Strictly forced to **120 FPS / 120 Hz** without dropping or fluctuating to 80Hz/90Hz, even during very fast, aggressive flings.
- **Still / Idle View**: Drops down to **60 FPS / 60 Hz** when content is static to save battery.
- **Completely Eliminates Intermediate 80Hz/90Hz Tiers**: Bypasses Apple's conservative power-saving downclocks during scroll deceleration.
- **Includes a 24px x 24px Draggable FPS Picker & Live HUD**: Displays the instantaneous refresh rate live as you scroll and allows tapping to lock between **Pixel Auto**, **Locked 120**, or **Locked 60**.

---

## Google Pixel-Style Refresh Behavior

| State | Target Refresh Rate | Behavior |
|---|---|---|
| **Active Scroll / Swipe** | **120 Hz** | Strictly locked to `120/120/120` across `UIScrollView`, `UIGestureRecognizer`, and `CADisplayLink`. |
| **Scroll Deceleration (Ending)** | **120 Hz** | Smoothly glides to zero velocity without dropping to 80Hz/60Hz mid-deceleration. |
| **Still / Idle UI (Reading feed)** | **60 Hz** | Automatically scales down to 60Hz to conserve battery. |
| **Locked 120 (Manual)** | **120 Hz** | Tapping the HUD locks 120Hz constantly, even when idle. |
| **Locked 60 (Manual)** | **60 Hz** | Tapping the HUD locks 60Hz for maximum battery savings. |

---

## 24px x 24px Draggable FPS Picker & Live HUD

A tiny 24px x 24px circular badge floats over the UI:
- **Live Counter**: Continuously updates and displays the actual screen refresh rate in real-time as you scroll.
- **Visual Feedback**:
  - **Green Border**: Running at **120 Hz**.
  - **Orange Border**: Running at **60 Hz**.
  - **Blue Flash ("A")**: Switched to **Pixel Auto** mode.
- **Tap to Toggle Modes**:
  1. `Pixel Auto` (120Hz scroll / 60Hz idle)
  2. `Locked 120` (Always 120Hz)
  3. `Locked 60` (Always 60Hz)
- **Draggable**: Drag the 24x24 HUD with your finger anywhere on screen to place it wherever you prefer.

---

## How It Eliminates the 80Hz / 90Hz Drops

1. **`UIScrollView` & `UIGestureRecognizer` Interception**:
   iOS dynamically lowers `_setFrameRateRange:` as scroll velocity drops. CAHighFPS intercepts this and clamps all scrolling updates to `CAFrameRateRangeMake(120, 120, 120)`.
2. **`CADisplayLink` Lifecycle Enforcement**:
   Overrides `+displayLinkWithTarget:selector:` and `-addToRunLoop:forMode:` so that all internal display links are created and registered with explicit 120Hz ranges.
3. **`CALayer addAnimation:forKey:` Interception**:
   Forces all UIKit deceleration, spring, and offset animations to 120Hz.
4. **Metal Triple Buffering**:
   Forces `CAMetalLayer.maximumDrawableCount = 3` to prevent GPU frame pipeline hitches at 120Hz.
5. **Read-Only Info.plist Interception**:
   Guarantees `CADisableMinimumFrameDurationOnPhone` returns `@YES` without modifying frozen bundle dictionaries.

---

## Building the .dylib with GitHub Actions

The repository includes [`.github/workflows/build.yml`](.github/workflows/build.yml):
- Automatically triggers on every push to any branch.
- Runs runtime test suite (`tests/test_cahighfps.m`) to verify stability.
- Builds universal `arm64` + `arm64e` iOS dylib.
- Attaches **only `CAHighFPS.dylib`** directly to GitHub Releases.

---

## Injecting into Instagram IPA

- **Sideloadly**: Select `Instagram.ipa` -> **Advanced Options** -> **Inject dylibs/frameworks** -> Select `CAHighFPS.dylib` (Standalone / no Substrate).
- **TrollStore / Esign / Feather**: Import `Instagram.ipa` and `CAHighFPS.dylib` -> Add dylib -> Sign and install.
- **Azule (CLI)**:
  ```bash
  azule -i Instagram.ipa -o Instagram_Pixel120.ipa -f CAHighFPS.dylib
  ```
