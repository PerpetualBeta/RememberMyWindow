//
//  MenuBarIconManager.swift
//  RememberMyWindows
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Menu Bar Icon Presets

enum MenuBarIconPreset: String, CaseIterable, Identifiable, Codable {
    case macWindow        = "Mac Window"
    case windowGrid       = "2x2 Grid"
    case layers3D         = "3D Stack"
    case workspaceRestore = "Workspace Restore"
    case missionControl   = "Mission Control"
    case sparkles         = "Magic Sparkles"
    case customSymbol     = "Custom SF Symbol"
    case customImage      = "Custom Image"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .macWindow:        return "Mac Window"
        case .windowGrid:       return "2x2 Grid"
        case .layers3D:         return "3D Stack"
        case .workspaceRestore: return "Workspace Restore"
        case .missionControl:   return "Mission Control"
        case .sparkles:         return "Magic Sparkles"
        case .customSymbol:     return "Custom SF Symbol"
        case .customImage:      return "Custom Image"
        }
    }

    var defaultRestingSymbol: String {
        switch self {
        case .macWindow:        return "macwindow.on.rectangle"
        case .windowGrid:       return "rectangle.split.2x2"
        case .layers3D:         return "square.3.layers.3d"
        case .workspaceRestore: return "arrow.triangle.2.circlepath"
        case .missionControl:   return "rectangle.3.group"
        case .sparkles:         return "sparkles"
        case .customSymbol:     return "macwindow.on.rectangle"
        case .customImage:      return "photo"
        }
    }

    var defaultActionSymbol: String {
        switch self {
        case .macWindow:        return "macwindow.badge.plus"
        case .windowGrid:       return "rectangle.split.2x2.fill"
        case .layers3D:         return "square.3.layers.3d.down.right"
        case .workspaceRestore: return "arrow.triangle.2.circlepath.circle.fill"
        case .missionControl:   return "rectangle.3.group.fill"
        case .sparkles:         return "sparkle"
        case .customSymbol:     return "macwindow.badge.plus"
        case .customImage:      return "photo.fill"
        }
    }

    init(rawValueOrFallback raw: String) {
        if raw == "Dual Display" {
            self = .workspaceRestore
        } else if raw == "Memory Eye" {
            self = .missionControl
        } else {
            self = MenuBarIconPreset(rawValue: raw) ?? .macWindow
        }
    }
}

// MARK: - Menu Bar Icon Manager

@MainActor
final class MenuBarIconManager: ObservableObject {
    static let shared = MenuBarIconManager()

    // MARK: - Keys
    private let kSelectedPreset       = "menuBarIconPreset"
    private let kCustomRestingSymbol  = "menuBarCustomRestingSymbol"
    private let kCustomActionSymbol   = "menuBarCustomActionSymbol"
    private let kCustomImagePath      = "menuBarCustomImagePath"
    private let kMatchThemeColor      = "menuBarMatchThemeColor"

    // MARK: - Published Properties
    @Published var selectedPreset: MenuBarIconPreset {
        didSet {
            UserDefaults.standard.set(selectedPreset.rawValue, forKey: kSelectedPreset)
            refreshStatusItem()
        }
    }

    @Published var customRestingSymbol: String {
        didSet {
            UserDefaults.standard.set(customRestingSymbol, forKey: kCustomRestingSymbol)
            if selectedPreset == .customSymbol { refreshStatusItem() }
        }
    }

    @Published var customActionSymbol: String {
        didSet {
            UserDefaults.standard.set(customActionSymbol, forKey: kCustomActionSymbol)
            if selectedPreset == .customSymbol && isActionActive { refreshStatusItem() }
        }
    }

    @Published var customImagePath: String {
        didSet {
            UserDefaults.standard.set(customImagePath, forKey: kCustomImagePath)
            if selectedPreset == .customImage { refreshStatusItem() }
        }
    }

    @Published var matchThemeColor: Bool {
        didSet {
            UserDefaults.standard.set(matchThemeColor, forKey: kMatchThemeColor)
            refreshStatusItem()
        }
    }

    @Published private(set) var isActionActive: Bool = false

    private var actionWorkItem: DispatchWorkItem?
    private weak var statusButton: NSStatusBarButton?

    // MARK: - Init
    private init() {
        let savedPresetStr = UserDefaults.standard.string(forKey: kSelectedPreset) ?? MenuBarIconPreset.macWindow.rawValue
        self.selectedPreset = MenuBarIconPreset(rawValueOrFallback: savedPresetStr)

        self.customRestingSymbol = UserDefaults.standard.string(forKey: kCustomRestingSymbol) ?? "macwindow.on.rectangle"
        self.customActionSymbol  = UserDefaults.standard.string(forKey: kCustomActionSymbol) ?? "macwindow.badge.plus"
        self.customImagePath     = UserDefaults.standard.string(forKey: kCustomImagePath) ?? ""
        self.matchThemeColor     = UserDefaults.standard.bool(forKey: kMatchThemeColor)

        // Observe theme changes to refresh icon color if matchThemeColor is true
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.matchThemeColor else { return }
                self.refreshStatusItem()
            }
        }
    }

    // MARK: - Status Item Binding
    func bind(button: NSStatusBarButton?) {
        self.statusButton = button
        refreshStatusItem()
    }

    // MARK: - Action Trigger
    /// Temporarily activates the Action state icon for at least `minDuration` seconds, then reverts to Resting state.
    func triggerActionState(minDuration: TimeInterval = 0.6, completion: (() -> Void)? = nil) {
        actionWorkItem?.cancel()
        isActionActive = true
        refreshStatusItem()

        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.isActionActive = false
            self.refreshStatusItem()
            completion?()
        }
        actionWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + minDuration, execute: item)
    }

    // MARK: - Refresh Status Item
    func refreshStatusItem() {
        guard let button = statusButton else { return }
        let img = generateImage(forActionState: isActionActive)
        button.image = img
    }

    // MARK: - Image Generation
    func generateImage(forActionState actionState: Bool) -> NSImage {
        let baseImage: NSImage
        
        switch selectedPreset {
        case .customImage:
            if !customImagePath.isEmpty,
               let loadedImg = NSImage(contentsOfFile: customImagePath) {
                baseImage = resizeImage(loadedImg, targetSize: NSSize(width: 18, height: 18))
            } else {
                let symbolName = actionState ? selectedPreset.defaultActionSymbol : selectedPreset.defaultRestingSymbol
                baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "RememberMyWindows")
                    ?? NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "RememberMyWindows")!
            }

        case .customSymbol:
            let symbolName = actionState
                ? (customActionSymbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? selectedPreset.defaultActionSymbol : customActionSymbol)
                : (customRestingSymbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? selectedPreset.defaultRestingSymbol : customRestingSymbol)
            baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "RememberMyWindows")
                ?? NSImage(systemSymbolName: actionState ? selectedPreset.defaultActionSymbol : selectedPreset.defaultRestingSymbol, accessibilityDescription: "RememberMyWindows")
                ?? NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "RememberMyWindows")!

        default:
            let symbolName = actionState ? selectedPreset.defaultActionSymbol : selectedPreset.defaultRestingSymbol
            baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "RememberMyWindows")
                ?? NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "RememberMyWindows")!
        }

        // Apply theme tint or template
        if matchThemeColor {
            let themeStr = UserDefaults.standard.string(forKey: "themeColor") ?? "Default"
            let theme = ThemeColor(rawValue: themeStr) ?? .default
            
            if theme.isGalaxy {
                // Galaxy theme tint
                let tinted = baseImage.copy() as? NSImage ?? baseImage
                tinted.isTemplate = false
                return tintImage(tinted, with: NSColor(red: 0.35, green: 0.65, blue: 1.0, alpha: 1.0))
            } else if let swiftColor = theme.color {
                let nsColor = NSColor(swiftColor)
                let tinted = baseImage.copy() as? NSImage ?? baseImage
                tinted.isTemplate = false
                return tintImage(tinted, with: nsColor)
            } else {
                // Default theme: use system accent color
                let tinted = baseImage.copy() as? NSImage ?? baseImage
                tinted.isTemplate = false
                return tintImage(tinted, with: NSColor.controlAccentColor)
            }
        } else {
            let template = baseImage.copy() as? NSImage ?? baseImage
            template.isTemplate = true
            return template
        }
    }

    private func resizeImage(_ image: NSImage, targetSize: NSSize) -> NSImage {
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: targetSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver,
                   fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }

    private func tintImage(_ image: NSImage, with color: NSColor) -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let size = image.size
        let tintedImage = NSImage(size: size)
        tintedImage.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            tintedImage.unlockFocus()
            return image
        }

        let rect = CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height))
        ctx.clip(to: rect, mask: cgImage)
        color.setFill()
        rect.fill()
        tintedImage.unlockFocus()
        tintedImage.isTemplate = false
        return tintedImage
    }

    // MARK: - Custom Image File Picker
    func pickCustomImage() {
        let openPanel = NSOpenPanel()
        openPanel.prompt = "Choose Icon"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [.png, .jpeg, .icns, .image]

        if openPanel.runModal() == .OK, let url = openPanel.url {
            self.customImagePath = url.path
            self.selectedPreset = .customImage
            refreshStatusItem()
        }
    }
}
