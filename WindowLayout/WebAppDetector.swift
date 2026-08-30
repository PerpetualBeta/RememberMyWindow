import AppKit
import ApplicationServices
import Foundation

/// Utility for accurately detecting whether an application is a Web App, PWA,
/// Electron wrapper, Web Browser, or contains web content (AXWebArea).
public final class WebAppDetector {
    public static let shared = WebAppDetector()

    private init() {}

    /// Known web browser bundle IDs
    public let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "com.brave.Browser",
        "com.brave.Browser.nightly",
        "company.thebrowser.Browser",        // Arc
        "org.mozilla.firefox",
        "org.mozilla.nightly",
        "org.mozilla.firefoxdeveloperedition",
        "com.kagi.kagimacOS",                 // Orion
        "app.zen-browser.zen",                // Zen Browser
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "org.torproject.torbrowser",
        "com.pushplaylabs.sidekick"
    ]

    /// Known major Electron / Chromium / Web wrapper apps that take longer to initialize
    public let knownWebWrapperBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",          // Slack
        "com.hnc.Discord",                    // Discord
        "com.hnc.DiscordPTB",
        "com.hnc.DiscordCanary",
        "notion.id",                          // Notion
        "com.spotify.client",                 // Spotify
        "com.figma.Desktop",                  // Figma
        "md.obsidian",                        // Obsidian
        "net.whatsapp.WhatsApp",              // WhatsApp
        "com.linear",                         // Linear
        "com.microsoft.teams2",               // Teams (new)
        "com.microsoft.teams",                // Teams (classic)
        "com.microsoft.VSCode",               // Visual Studio Code
        "com.microsoft.VSCodeInsiders",
        "com.github.GitHubClient",            // GitHub Desktop
        "com.trello.trellodesktop",           // Trello
        "ru.keepcoder.Telegram",              // Telegram Web/wrapper variants
        "com.postmanlabs.mac",                // Postman
        "com.todoist.mac.Todoist",            // Todoist
        "com.loom.desktop",                   // Loom
        "com.kapeli.dashdoc",
        "com.superhuman.electron",            // Superhuman
        "com.openai.chat"                     // ChatGPT macOS app
    ]

    /// Determines if an app is a Web App / PWA / Browser / Electron app based on bundle identifier,
    /// bundle structure, custom user preferences, and AX hierarchy inspection.
    public func isWebApp(
        bundleID: String?,
        appURL: URL? = nil,
        processIdentifier: pid_t? = nil,
        customIDs: Set<String> = []
    ) -> Bool {
        guard let bundleID = bundleID, !bundleID.isEmpty else {
            return false
        }

        // 1. Check user custom list
        if customIDs.contains(bundleID) {
            return true
        }

        // 2. Safari Web Apps (macOS Sonoma / Sequoia Dock Web Apps)
        if bundleID.hasPrefix("com.apple.Safari.WebApp") {
            return true
        }

        // 3. Chromium PWAs (Chrome, Brave, Edge, Chromium, Arc web shortcuts)
        if bundleID.hasPrefix("com.google.Chrome.app.") ||
           bundleID.hasPrefix("com.microsoft.edgemac.app.") ||
           bundleID.hasPrefix("com.brave.Browser.app.") ||
           bundleID.hasPrefix("org.chromium.Chromium.app.") ||
           bundleID.hasPrefix("company.thebrowser.Browser.app.") {
            return true
        }

        // 4. Known Web Browsers
        if browserBundleIDs.contains(bundleID) {
            return true
        }

        // 5. Known Electron / Web wrappers
        if knownWebWrapperBundleIDs.contains(bundleID) {
            return true
        }

        // 6. Bundle inspection (Electron / Chromium Embedded Framework / CrAppMode)
        if let url = appURL {
            if isElectronOrChromiumBundle(url: url) {
                return true
            }
        }

        // 7. AX Hierarchy inspection: Checks if the application contains an AXWebArea
        if let pid = processIdentifier, pid > 0, AXIsProcessTrusted() {
            if hasAXWebArea(pid: pid) {
                return true
            }
        }

        return false
    }

    /// Convenience overload for `NSRunningApplication`.
    public func isWebApp(_ app: NSRunningApplication, customIDs: Set<String> = []) -> Bool {
        isWebApp(
            bundleID: app.bundleIdentifier ?? app.localizedName,
            appURL: app.bundleURL,
            processIdentifier: app.processIdentifier,
            customIDs: customIDs
        )
    }

    // MARK: - Bundle Inspection

    private func isElectronOrChromiumBundle(url: URL) -> Bool {
        let fileManager = FileManager.default
        let frameworksURL = url.appendingPathComponent("Contents/Frameworks", isDirectory: true)

        let electronPath = frameworksURL.appendingPathComponent("Electron Framework.framework").path
        if fileManager.fileExists(atPath: electronPath) {
            return true
        }

        let cefPath = frameworksURL.appendingPathComponent("Chromium Embedded Framework.framework").path
        if fileManager.fileExists(atPath: cefPath) {
            return true
        }

        // Chrome App Mode shortcut bundles often contain App Mode Loader or Info.plist with CrAppMode
        let infoPlistURL = url.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: infoPlistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            if plist["CrAppModeShortcutID"] != nil ||
               plist["CrAppModeShortcutName"] != nil ||
               plist["CrAppModeShortcutURL"] != nil ||
               plist["WKManifest"] != nil {
                return true
            }
        }

        return false
    }

    // MARK: - Accessibility AXWebArea Inspection

    /// Scans the app's top-level accessibility window elements for an AXWebArea role.
    private func hasAXWebArea(pid: pid_t) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return false
        }

        for window in windows.prefix(3) {
            if containsWebArea(element: window, depth: 0, maxDepth: 4) {
                return true
            }
        }
        return false
    }

    private func containsWebArea(element: AXUIElement, depth: Int, maxDepth: Int) -> Bool {
        if depth > maxDepth { return false }

        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            if role == "AXWebArea" || role == "AXHTMLContent" {
                return true
            }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children.prefix(8) {
                if containsWebArea(element: child, depth: depth + 1, maxDepth: maxDepth) {
                    return true
                }
            }
        }

        return false
    }
}
