# Changelog

All notable changes to RememberMyWindows will be documented here.

## [v13.0] — 2026-09-01

### 🧠💨 "The App Was Thinking, It Just Needed a Coffee"

#### 🚀 Performance
- **Instant launch, no more frozen beach ball**: App now shows the menu bar icon and main window immediately at startup. AX observer registration for all running apps is deferred to a cooperative background task instead of blocking the main thread.
- **150ms AX IPC timeout everywhere**: All Accessibility API calls now have a hard 150ms timeout (`AXUIElementSetMessagingTimeout`). If any app is slow or unresponsive, we move on instead of hanging for macOS's default 6-second wait — eliminating the `(Not Responding)` state seen in Activity Monitor on cold launches.
- **Safe AX element factory**: Centralised `WindowManager.createAXElement(for:)` helper ensures every AX handle is timeout-guarded across `WindowManager`, `DesktopToggleManager`, `CommandOverlayManager`, and `WebAppDetector`.

#### 🎵 Meme & Fun Sounds
- **21 new notification sounds** in a brand-new "Meme & Fun" category: Vine Boom, Bruh, OOF (Roblox), Windows Error, Emotional Damage, Wilhelm Scream, What The Dog Doin, Mario 1-Up / Power-Up / Jump / Pipe, Illuminati (X-Files), Directed by (Curb Your Enthusiasm), Huh? (Cat), Taco Bell Bong, Quack, Sheesh, Yeet, Anime Wow, Ta-Da, and more.
- **Sound picker redesign**: Stepper chevrons (‹ ›) + searchable dropdown menu + shuffle button for every notification sound slot in Settings. No more scrolling an infinite flat list.
- **Full Hebrew translations** for all new sounds and picker UI strings.

#### 🎯 Menu Bar Polish
- **App icon on the single-app action item**: The "Update 'App' position" / "Add 'App' to session" item now shows the frontmost app's real 16×16 icon instead of a generic SF Symbol.
- **Smarter "Open RememberMyWindows" title**: The app name is only appended (e.g. `Open RememberMyWindows (Antigravity IDE)`) when that app is actually saved in the current session — no more misleading labels when the frontmost app isn't tracked.
- **Window activation fix**: `showMainWindow()` now brings an existing window to front directly (`makeKeyAndOrderFront`) instead of routing through the LaunchServices URL dispatch, shaving off extra IPC latency on every open.

---

## [v12.0] — 2026-09-01

### 🎨✨ The "Lookin' Sharp & SF-licious" Menu Glow-Up

- **Iconic Visuals**: Top-level status menu actions now sport native SF Symbols (`macwindow.on.rectangle`, `arrow.counterclockwise`, `arrow.triangle.2.circlepath`, `plus`, `arrow.clockwise`, `square.stack`, `folder`, `power`) with pixel-perfect template rendering so your menu looks like a million bucks.
- **Context-Aware App Targeting**: The main menu entry now dynamically tells you which app is in focus (e.g. `Open RememberMyWindows (Finder)`) so you always know what you're tweaking in one glance.
- **Bilingual Polish**: Seamless English & Hebrew translations for all dynamic menu actions.
- **Slick Single-App Actions**: Crisp `+` icon when adding new apps to your saved layout, and refresh `⟳` when updating existing window coordinates.

---

## [v11.0] — 2026-08-31

### 🚀 The Open Source & Automation Release

- **GPLv3 Licensing**: Project is now fully open-source under the GNU General Public License v3.
- **Automated Cloud Releases**: Added GitHub Actions workflow to build, package DMG, and release automatically.
- **Cleaned Compiler Warnings**: Replaced deprecated `activateIgnoringOtherApps` and updated SwiftUI `.onChange` handlers.
- **Improved Packaging**: DMG packaging script now includes all sound assets and localized strings automatically.
- **Repository Structure**: Cleaned up build files and established standard project hierarchy.

---

## [v10.0] — 2026-08-30

- Look Ma, No Hands! automation and window management updates.
