# Changelog

All notable changes to RememberMyWindows will be documented here.

## [v13.4] — 2026-09-03

### 🚀 "Rise and Shine, Windows In Line"

#### 🔄 Automatic Full Layout Restore at Launch
- **First Scan, Full Restore**: Whenever RememberMyWindows launches—whether started manually by you or triggered at system login—it now automatically initiates a full layout restore as soon as the live layout tracking server finishes its initial window capture.
- **Login Settle Buffer**: Built-in 1.75-second settling delay ensures other login applications finishing their startup sequences have their windows captured and aligned precisely without racing.
- **Zero-Friction Reliability**: Works seamlessly with your active screen fingerprint, preserving the saved foreground app focus and firing the standard Notch overlay notification with window counts.

---

## [v13.3] — 2026-09-02

### 🪟 "The Multiverse of Multitasking"

#### 📺 The Multi-Window Miracle (Full & Single Restore)
- **Leave No Window Behind (Not Even Your 14th YouTube Tab)**: It turns out people open more than one browser window! Fixed a bug where opening 5 YouTube windows or multiple browser/app windows would only restore *one* lonely window while leaving the others wandering the desktop abyss.
- **Broadcast Stacking**: *Sorry Window #2, we swear we didn't mean to ghost you.* When you have more open windows than saved in your snapshot, we now broadcast the layout coordinates to all extra windows and stack them neatly at the saved position so you can slide them apart like a fresh deck of cards.
- **Lightning Verification**: Rewrote the WindowServer verification loop to check and correct each window directly via nonisolated Accessibility handles. Gone is the awkward 3.6-second stall where the app stared at Window 1 trying to fix Window 2.

#### 🎛️ Menu Bar Icon Cha-Cha Elimination
- **1-Pixel Shift Evicted**: Centered all SF Symbols and custom icons inside a fixed 18×18 point canvas. Clicking the status bar icon no longer causes a microscopic 1-pixel jump to the right when transitioning into the action state.

---

## [v13.2] — 2026-09-01

### 🔕 "When I Turn Off Notifications, I Mean Disappear"

#### 🔔 Master Notification Disappearing Act
- **Total Eclipse of the Settings**: When you switch off the master **Notifications** toggle, the app takes the hint and vaporizes the **Notification Sounds** toggle, **Sound Library**, and all channel navigation rows into thin air. No ghost toggles left behind!
- **Sound Library Jukebox**: Replaced the redundant "Default Sound" row with a new **Sound Library** browser right in the notification panel. Now you can spam-click *Vine Boom*, *Anime Wow*, and *Wilhelm Scream* to your heart's content without messing up individual event sounds.
- **Bilingual Euphoria**: English & Hebrew translations (`ספריית צלילים`) for all fresh sound library copy.

#### ⌨️ Configurable Desktop Hotkey & Stability
- **Carbon-Powered Shortcut**: Swapped the fickle event-tap for a rock-solid Carbon `RegisterEventHotKey`. Customize your Desktop Toggle hotkey to any key combination you like (defaulting to `⌃⌥D`).
- **No More Safari Drama**: Kept shortcuts from interfering with Safari or hanging silently when macOS gets grumpy.

#### 🔮 Notch Glow & Privacy Honesty
- **Persistent Notch Pulse**: Rebalanced the notch indicator halo and ripple geometry so the fallback glow stays silky-smooth and visible through the entire pulse cycle.
- **Transparent Privacy**: Clarified reverse-geocoding privacy disclosures.

---

## [v13.1] — 2026-09-01

### 🛠️ Fixes for Previous Release

#### 🎵 Audio & Meme Sounds
- **Acoustic Reverb & Echo Tail**: Re-rendered all 21 meme sound files with Apple Medium Hall reverb (35% wet mix) and spatial echo delay (20% feedback, 1.4s decay tail) baked into 192kbps AAC `.m4a` files.
- **Mario Power-Up Resampling Fix**: Fixed dynamic buffer allocation for 22,050 Hz source audio so the complete ascending power-up melody plays without being truncated.

#### 🪟 Smart Single App Restore
- **Silent "Already In Place" Banner**: Single app restore checks whether target windows are already in place before executing. If unmoved, it displays a quiet compact Notch banner saying `"Already In Place"` (`"כבר במקום"`) with **zero sound played**.
- **Quiet Mode Setting**: Added *"Quiet when already in place"* toggle in Settings under Notification Events, enabled by default with an option to restore standard notifications.

#### 🎨 Notification UI Redesign
- **Clean 2-Row Card Layout**: Redesigned Notification Events list into modern individual cards. Titles and descriptions now have full horizontal width, eliminating awkward text wrapping. Sound selector controls and sub-options are neatly indented on row 2.
- **Hebrew Localization**: Full bilingual translations for all new strings and settings.

---

## [v13.0] — 2026-09-01

### 🎶 "Wilhelm Screamed When He Saw How Fast It Starts Now"

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
