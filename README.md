<div align="center">

<img src="AppIcon.png" width="128" height="128" alt="RememberMyWindows Icon"/>

# RememberMyWindows

**A native macOS app that remembers where your windows were — and puts them back.**

[Features](#-features) · [Installation](#-installation) · [How it works](#️-how-it-works) · [Project Structure](#-project-structure) · [Contributing](#-contributing)

[![Release](https://img.shields.io/github/v/release/netanel3000fine/RememberMyWindow?color=brightgreen&logo=github)](https://github.com/netanel3000fine/RememberMyWindow/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift&logoColor=white)](https://swift.org)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

<br/>

<a href="https://github.com/netanel3000fine/RememberMyWindow/releases/latest">
  <img src="https://img.shields.io/badge/Download_Latest_Release-DMG_%26_ZIP-007AFF?style=for-the-badge&logo=apple&logoColor=white" alt="Download DMG"/>
</a>

</div>

---

## ✨ What it does

Every time you plug in a monitor, disconnect from a dock, wake from sleep, or rearrange your displays — macOS scatters your windows across screens. **RememberMyWindows** fixes that seamlessly.

It continuously tracks window arrangements in the background. The moment it recognises your display setup, it restores every window across every application to its exact saved size and position.

<div align="center">
  <img width="1419" height="893" alt="Screenshot of RememberMyWindows" src="https://github.com/user-attachments/assets/4fcaa48b-c658-46eb-afff-776e05e02ebd" />
</div>

---

## 🚀 Features

### 🖥️ Display & Window Intelligence
- **Screen Fingerprinting**: Identifies display arrangements by hardware IDs and physical resolutions — layouts are uniquely matched to your exact monitors.
- **Multi-Space Awareness (WindowServer)**: Directly queries macOS WindowServer (`CGSCopySpacesForWindows`) to distinguish open windows on other Spaces from closed windows, deferring restoration until you navigate to that Space.
- **Cable & Reconnect Debounce**: Automatically debounces rapid display plug/unplug events, waiting for screen configurations to settle before applying layouts.
- **Contested Window Recovery**: Wins back stubborn windows from apps that try to fight the restore layout, using retry backoff and gentle multi-display nudging.
- **Edge Overhang Preservation**: Preserves windows deliberately positioned partially over display borders on matching setups.

### 💾 Auto-Save & Named Layouts
- **Live Auto-Save**: Automatically records window moves and resizes with an 800ms debounce buffer (no unnecessary disk writes).
- **Persistent Auto Layout**: Keeps a rolling 5-entry history across restarts and sleep in `auto-layout.json`, with a dedicated hero card in the UI.
- **Named Layout Presets**: Create, rename, snapshot, and manually restore custom named layouts per monitor configuration.
- **Launch & Login Restore**: Optionally launches closed apps and automatically restores the full layout immediately when RememberMyWindows starts.

### 🎛️ Control & Shortcuts
- **Dual-Action Menu Bar**:
  - **Left-click**: Restores the currently focused frontmost application and opens the window list.
  - **Right-click**: Instantly triggers a full layout restore for all open applications.
- **Desktop Toggle (Cmd+D)**: A Carbon-powered hotkey instantly hides/unhides all desktop windows (collapsing Finder windows) with optional automatic layout restore upon unhiding.
- **Quick Key Restore**: Long-press `Fn` / Globe (🌐) or double-tap `⇪ Caps Lock` to restore layouts immediately.
- **⌘⇧R Post-Restore Automation**: Automatically fires ⌘⇧R to active apps post-restore (e.g. Reader Mode in Safari, Hard Reload in Chrome, or Picture-in-Picture).

### 🎨 Visuals, Audio & Localization
- **Dynamic Notch Notifications**: Sleek pill-shaped alerts sliding down from the MacBook notch, with typography-measured sizing and physical bezel clearance.
- **Interactive Soundboard**: Built-in sound library with Encore tones, classic macOS alerts, and meme effects, with per-event toggles and master volume control.
- **Liquid Glass Interface & Themes**: Customizable primary accent hues and smooth translucent glass design.
- **English & Hebrew Localization**: Complete bi-directional localization with native RTL layout support.
- **Convenient GitHub Updates**: Built-in update checker with one-click in-app ZIP updates.

---

## 📋 Requirements

- **macOS 14.0 (Sonoma)**, **macOS 15.0 (Sequoia)**, or later
- **Apple Silicon (M-series)** or **Intel Mac**
- **Xcode 15+** (if building from source)

---

## 🔧 Installation

### Option 1: Pre-Built Download (Recommended)

1. Download the latest **`RememberMyWindows.dmg`** from the **[Releases Page](https://github.com/netanel3000fine/RememberMyWindow/releases/latest)**.
2. Open the DMG and drag **RememberMyWindows.app** to your **Applications** folder.
3. Launch the app and follow the onboarding setup to grant permissions.

### Option 2: Build from Source

```bash
# 1. Clone the repository
git clone https://github.com/netanel3000fine/RememberMyWindow.git
cd RememberMyWindow

# 2. Build and run with the shell script
./Build-RememberMyWindows.sh

# Or open in Xcode
open WindowLayout/RememberMyWindows.xcodeproj
```

In Xcode:
1. Select your target and **Signing & Capabilities** (select your development team).
2. Press **⌘R** to build and run.

---

### 🔑 Required Permissions

On first launch, macOS will prompt you for the following permissions:

| Permission | Why it's needed | Where to manage |
|---|---|---|
| **Accessibility** | Required to read and reposition windows across third-party applications via `AXUIElement`. | *System Settings → Privacy & Security → Accessibility* |
| **Automation / Apple Events** | Used for Desktop Toggle integration to collapse and restore Finder windows. | *System Settings → Privacy & Security → Automation* |

> [!TIP]
> Permissions can be reviewed and adjusted at any time in macOS **System Settings → Privacy & Security**.

---

## 🏗️ How it works

### 1. Screen Fingerprinting
Each connected display provides a unique hardware ID and bounds. RememberMyWindows computes a composite fingerprint string representing your physical display topology:

```text
12345678@2560x1600+87654321@2560x1440
```

When monitors connect, disconnect, or rearrange, a new fingerprint is computed and matched against your saved layout database.

### 2. Multi-Space Window Capture
Uses `CGWindowListCopyWindowInfo` paired with private WindowServer resolution (`CGSCopySpacesForWindows` via `dlsym`) to inspect open windows across all virtual Spaces. This guarantees:
- Non-active Spaces don't register false window closures.
- Minimized and hidden windows are recognized and respected.
- Background utility elements under 50px are excluded.

### 3. Native Accessibility Restoration Engine
Unlike legacy AppleScript-based tools, RememberMyWindows uses native macOS Accessibility APIs (`AXUIElement`):
- Direct nonisolated element handles allow adjusting multiple windows per application concurrently.
- Re-verifies live geometry with WindowServer after repositioning.
- Exponential backoff handles apps that contest window placement on display reconnection.

### 4. Dual-Origin Coordinate Translation
- macOS WindowServer / `CGWindowList` coordinates originate from the **top-left** of the primary display.
- AppKit / `NSScreen` coordinates originate from the **bottom-left**.
- RememberMyWindows translates between coordinate spaces in real time using the primary screen's visible frame height.

---

## 📁 Project Structure

```text
RememberMyWindow/
├── LICENSE                             ← GNU General Public License v3.0
├── README.md                           ← Project documentation
├── CHANGELOG.md                        ← Detailed version history
├── Build-RememberMyWindows.sh          ← Development compilation & signing script
├── DMG-BuildandPackage.sh              ← DMG & ZIP release packager
└── WindowLayout/                       ← Application source code
    ├── RememberMyWindowsApp.swift      ← SwiftUI app lifecycle & menu bar setup
    ├── WindowManager.swift             ← Core window tracking, save & restore engine
    ├── WindowSpaces.swift              ← WindowServer Space query SPI (CGSCopySpacesForWindows)
    ├── WindowRecord.swift              ← Data models for windows, layouts, and apps
    ├── AutoSaveStore.swift             ← Continuous auto-save engine & ring buffer
    ├── AutoLayoutHeroCard.swift        ← Interactive Auto Layout preview card
    ├── ScreenFingerprint.swift         ← Display configuration identification
    ├── DesktopToggleManager.swift      ← Cmd+D desktop toggle & window hide manager
    ├── Hotkey.swift                    ← Carbon-based global keyboard shortcut engine
    ├── NotchNotification.swift         ← Dynamic notch pill overlay notification
    ├── CommandOverlayManager.swift     ← ⌘⇧R command trigger & visual overlay HUD
    ├── WebAppDetector.swift            ← Web app, PWA, and browser detection
    ├── MenuBarIconManager.swift        ← Menu bar icon styles, animations & theme tints
    ├── UpdateManager.swift             ← GitHub release update checker & ZIP updater
    ├── ThemeManager.swift              ← Accent colors, themes & Liquid Glass styling
    ├── Localization.swift              ← Hebrew & English bi-directional translation
    ├── ContentView.swift               ← Main settings & navigation shell
    ├── LayoutsView.swift               ← Saved layouts & snapshots browser
    ├── SettingsView.swift              ← Preferences & configuration panel
    ├── ActivityView.swift              ← Real-time activity log viewer
    ├── OnboardingView.swift            ← First-launch feature tour & setup wizard
    ├── ShortcutMigrationView.swift     ← Legacy shortcut migration helper
    ├── WindowPreviewComponents.swift   ← Minimap & display layout preview canvas
    ├── Sounds/                         ← Curated notification audio assets (.m4a)
    ├── en.lproj/                       ← English localization string catalog
    └── he.lproj/                       ← Hebrew localization string catalog
```

---

## 💾 Data Storage

All data is stored strictly locally on your Mac — no network analytics, no telemetry:

```text
~/Library/Application Support/RememberMyWindows/
├── layouts.json          ← Named snapshots & saved layout configurations
└── auto-layout.json      ← Rolling 5-entry persistent auto-save ring buffer
```

> [!NOTE]
> No layout data, window titles, or credentials ever leave your machine. 📴

---

## 🤝 Contributing

Contributions are warmly welcomed! This project is licensed under **GPLv3**:

- ✅ You can fork, inspect, modify, and redistribute.
- ✅ All derivative works remain free and open source.
- ❌ Closed-source or proprietary redistribution is not permitted.

Feel free to open an **[Issue](https://github.com/netanel3000fine/RememberMyWindow/issues)** for feature suggestions or bug reports, or submit a **Pull Request**.

---

## 📄 License

RememberMyWindows is licensed under the **GNU General Public License v3.0**.  
See [LICENSE](LICENSE) for full details.

<div align="center">
Made with ❤️ by <a href="https://github.com/netanel3000fine">Netanel</a>
</div>
