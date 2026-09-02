// this file used for window preview icon plus full screen preview
import SwiftUI

// MARK: - Window Preview Icon (for list rows)

struct WindowPreviewIcon: View {
    let record: WindowRecord
    let tint: Color

    private let displayW: CGFloat = 52
    private let displayH: CGFloat = 34
    private let cornerR: CGFloat = 4

    var body: some View {
        ZStack(alignment: .topLeading) {
            // ── Screen bezel ──────────────────────────────────
            RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                .fill(Color.primary.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                        .stroke(tint.opacity(0.2), lineWidth: 0.75) // Theme-colored bezel
                }

            // ── Window rectangle ──────────────────────────────
            GeometryReader { geo in
                let screenFrame = record.screenFrame
                    ?? NSScreen.main?.frame
                    ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)

                let canvasW = geo.size.width
                let canvasH = geo.size.height

                let scaleX = canvasW / screenFrame.width
                let scaleY = canvasH / screenFrame.height

                let relX = (record.globalFrame.origin.x - screenFrame.origin.x) * scaleX
                let relY = (screenFrame.height
                            - (record.globalFrame.origin.y - screenFrame.origin.y)
                            - record.globalFrame.height) * scaleY
                let winW  = min(canvasW, max(6, record.globalFrame.width  * scaleX))
                let winH  = min(canvasH, max(5, record.globalFrame.height * scaleY))
                let isFilled = winW >= canvasW * 0.92 && winH >= canvasH * 0.92
                let winCorner: CGFloat = isFilled ? cornerR : 2

                ZStack(alignment: .topLeading) {
                    // Window body
                    RoundedRectangle(cornerRadius: winCorner, style: .continuous)
                        .fill(tint.opacity(isFilled ? 0.28 : 0.18))
                        .overlay {
                            RoundedRectangle(cornerRadius: winCorner, style: .continuous)
                                .stroke(tint.opacity(0.8), lineWidth: 0.75)
                        }
                    
                    // Abstract Content Blocks
                    VStack(alignment: .leading, spacing: 2) {
                        // Title bar with dots
                        HStack(spacing: 1.5) {
                            Circle().fill(tint.opacity(0.6)).frame(width: 1.5, height: 1.5)
                            Circle().fill(tint.opacity(0.4)).frame(width: 1.5, height: 1.5)
                            Circle().fill(tint.opacity(0.4)).frame(width: 1.5, height: 1.5)
                        }
                        .padding(.leading, 2)
                        .padding(.top, 1)
                        
                        // Body bars
                        if winH > 10 {
                            VStack(alignment: .leading, spacing: 2) {
                                RoundedRectangle(cornerRadius: 0.5).fill(tint.opacity(0.2)).frame(width: winW * 0.6, height: 1.5)
                                RoundedRectangle(cornerRadius: 0.5).fill(tint.opacity(0.15)).frame(width: winW * 0.8, height: 1.5)
                                RoundedRectangle(cornerRadius: 0.5).fill(tint.opacity(0.1)).frame(width: winW * 0.4, height: 1.5)
                            }
                            .padding(.leading, 3)
                            .padding(.top, 1)
                        }
                    }
                }
                .frame(width: winW, height: winH)
                .offset(x: relX, y: relY)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: record.globalFrame)
            }
        }
        .frame(width: displayW, height: displayH)
    }
}

// MARK: - Full-Screen Window Preview Icon

struct FullScreenPreviewIcon: View {
    let tint: Color
    private let displayW: CGFloat = 52
    private let displayH: CGFloat = 34
    private let cornerR: CGFloat = 4

    var body: some View {
        ZStack {
            // Screen bezel — fully filled with tint
            RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                .fill(tint.opacity(0.18))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                        .stroke(tint.opacity(0.6), lineWidth: 0.75)
                }

            // Abstract Content: Multiple bars to show "filling"
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 1).fill(tint.opacity(0.3)).frame(width: 30, height: 2)
                RoundedRectangle(cornerRadius: 1).fill(tint.opacity(0.2)).frame(width: 25, height: 2)
                RoundedRectangle(cornerRadius: 1).fill(tint.opacity(0.1)).frame(width: 20, height: 2)
            }
            .offset(y: 2)
        }
        .frame(width: displayW, height: displayH)
    }
}

// MARK: - Layout Preview View (for detail view)

struct AppIconView: View {
    let bundleID: String
    var body: some View {
        let image: NSImage? = {
            // 1. Standard NSWorkspace lookup — works for .app bundles in /Applications
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            // 2. Running-app icon — works for Chrome PWAs, Electron apps, anything currently running
            if let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
               let icon = runningApp.icon {
                return icon
            }
            return nil
        }()
        
        if let image = image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
        } else {
            Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
        }
    }
}

struct LayoutPreviewView: View {
    let snapshot: LayoutSnapshot
    let selectedRecordID: UUID?
    let tint: Color
    
    var body: some View {
        GeometryReader { geo in
            let boundingBox = calculateBoundingBox()
            let scale = calculateScale(for: geo.size, boundingBox: boundingBox)
            
            ZStack {
                // Screens
                ForEach(getScreenFrames(), id: \.origin.x) { frame in
                    screenView(frame: frame, boundingBox: boundingBox, scale: scale)
                }
                
                // Windows
                ForEach(snapshot.records) { record in
                    windowView(record: record, boundingBox: boundingBox, scale: scale)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .liquidGlass(cornerRadius: 16, style: .card)
    }
    
    private func screenView(frame: CGRect, boundingBox: CGRect, scale: CGFloat) -> some View {
        let x = (frame.origin.x - boundingBox.origin.x) * scale
        let y = (boundingBox.height - (frame.origin.y - boundingBox.origin.y + frame.height)) * scale
        let w = frame.width * scale
        let h = frame.height * scale
        
        let cornerR: CGFloat = 10 * scale
        
        return ZStack {
            // Main Panel
            RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                .fill(Color(red: 0.04, green: 0.07, blue: 0.18).opacity(0.85))
            
            // Inner glow / bezel detail
            RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.38), Color.white.opacity(0.12), Color.white.opacity(0.22)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
        }
        .frame(width: w, height: h)
        .position(x: x + w/2, y: y + h/2)
    }
    
    private func windowView(record: WindowRecord, boundingBox: CGRect, scale: CGFloat) -> some View {
        let isSelected = record.id == selectedRecordID
        let x = (record.globalFrame.origin.x - boundingBox.origin.x) * scale
        let y = (boundingBox.height - (record.globalFrame.origin.y - boundingBox.origin.y + record.globalFrame.height)) * scale
        let w = record.globalFrame.width * scale
        let h = record.globalFrame.height * scale
        
        // Match Theme Colors (Use high-contrast slate for Black theme so preview window cards remain visible)
        let baseTint = (tint == .black || tint == Color.black) ? Color(white: 0.8) : tint
        let winCorner: CGFloat = max(4, 8 * scale)
        
        return ZStack {
            // Window body with theme-colored glass
            RoundedRectangle(cornerRadius: winCorner, style: .continuous)
                .fill(baseTint.opacity(isSelected ? 0.45 : 0.25))
                .overlay {
                    // Vibrant theme-colored border
                    RoundedRectangle(cornerRadius: winCorner, style: .continuous)
                        .stroke(baseTint.opacity(isSelected ? 1.0 : 0.6), lineWidth: isSelected ? 1.5 : 0.75)
                }
                .shadow(color: baseTint.opacity(isSelected ? 0.5 : 0.0), radius: 8, x: 0, y: 0)
            
            // App Icon
            AppIconView(bundleID: record.windowID.appBundleID)
                .frame(width: min(w * 0.7, 32), height: min(h * 0.7, 32))
                .shadow(color: .black.opacity(0.2), radius: 2)
            
            // Optional label if window is large enough
            if w > 60 && h > 40 {
                VStack {
                    Spacer()
                    Text(record.windowID.appName?.prefix(12) ?? "")
                        .font(.system(size: 10 * scale, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.bottom, 4)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                }
            }
        }
        .frame(width: max(8, w), height: max(8, h))
        .position(x: x + w/2, y: y + h/2)
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: record.globalFrame)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
    }
    
    // Helpers
    
    private func getScreenFrames() -> [CGRect] {
        var uniqueFrames: [CGRect] = []
        for frame in snapshot.records.compactMap({ $0.screenFrame }) {
            if !uniqueFrames.contains(where: { $0.equalTo(frame) }) {
                uniqueFrames.append(frame)
            }
        }
        let frames = uniqueFrames.sorted { $0.origin.x < $1.origin.x }
        if frames.isEmpty {
            return [NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        }
        return frames
    }
    
    private func calculateBoundingBox() -> CGRect {
        let frames = getScreenFrames()
        guard let first = frames.first else { return .zero }
        return frames.reduce(first) { $0.union($1) }
    }
    
    private func calculateScale(for size: CGSize, boundingBox: CGRect) -> CGFloat {
        let horizontalScale = size.width / boundingBox.width
        let verticalScale = size.height / boundingBox.height
        return min(horizontalScale, verticalScale) * 0.9 // Add some padding
    }
}

// MARK: - Screen Layout Thumbnail (for snapshot list rows)

/// Draws proportional monitor-outline rectangles for each display in a snapshot's screen config.
/// Single display → one rectangle. Two displays side-by-side → two rectangles, etc.
struct ScreenLayoutThumbnail: View {
    let screenKey: String
    let tint: Color
    let isLive: Bool
    var isHighlighted: Bool = false

    /// Fixed canvas size for the thumbnail area
    private let canvasW: CGFloat = 34
    private let canvasH: CGFloat = 22

    private var fingerprint: ScreenFingerprint {
        ScreenFingerprint.from(key: screenKey)
    }

    private var displays: [ScreenFingerprint.DisplayID] {
        let d = fingerprint.displays
        // Sort left-to-right by origin so layout order is preserved
        return d.sorted { $0.originX < $1.originX }
    }

    private var boundingBox: CGRect {
        guard let first = displays.first else { return .zero }
        return displays.reduce(CGRect(x: first.originX, y: first.originY,
                                     width: first.width, height: first.height)) { box, d in
            box.union(CGRect(x: d.originX, y: d.originY, width: d.width, height: d.height))
        }
    }

    var body: some View {
        let bb = boundingBox
        guard bb.width > 0, bb.height > 0 else { return AnyView(EmptyView()) }

        let scaleX = canvasW / bb.width
        let scaleY = canvasH / bb.height
        let scale  = min(scaleX, scaleY)

        // Center the layout within the canvas
        let layoutW = bb.width  * scale
        let layoutH = bb.height * scale
        let offsetX = (canvasW - layoutW) / 2
        let offsetY = (canvasH - layoutH) / 2

        let active = isLive || isHighlighted

        return AnyView(
            ZStack(alignment: .topLeading) {
                // Screens
                ForEach(Array(displays.enumerated()), id: \.offset) { _, d in
                    let x = CGFloat(d.originX - Int(bb.minX)) * scale + offsetX
                    // Invert Y: macOS is Y-up, SwiftUI is Y-down.
                    // Calculate distance from the TOP of the bounding box to the TOP of this display.
                    let y = CGFloat(Int(bb.maxY) - (d.originY + d.height)) * scale + offsetY
                    let w = max(6, CGFloat(d.width)  * scale)
                    let h = max(4, CGFloat(d.height) * scale)

                    let screenFill = active
                        ? (tint == .black ? Color.white.opacity(0.35) : tint.opacity(0.45))
                        : Color.white.opacity(0.22)
                    let screenStroke = active
                        ? (tint == .black ? Color.white : tint)
                        : Color.white.opacity(0.88)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(screenFill)
                        .overlay {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .stroke(screenStroke, lineWidth: active ? 1.5 : 1.0)
                        }
                        .shadow(color: active ? screenStroke.opacity(0.70) : Color.black.opacity(0.45), radius: active ? 3.0 : 1.5, x: 0, y: 1)
                        .frame(width: w, height: h)
                        .offset(x: x, y: y)
                }

                // Small active layout indicator dot in top-right corner
                if active {
                    Circle()
                        .fill(tint == .black ? Color.white : tint)
                        .frame(width: 5, height: 5)
                        .shadow(color: Color.white.opacity(0.85), radius: 2)
                        .shadow(color: Color.black.opacity(0.5), radius: 1, x: 0, y: 1)
                        .position(x: canvasW, y: 0)
                }
            }
            .frame(width: canvasW, height: canvasH)
        )
    }

    private static var thumbnailCache: [String: NSImage] = [:]

    /// Renders the layout thumbnail as a compact, crisp NSImage properly dimensioned for native NSMenuItems (20x14 pt).
    @MainActor
    static func renderImage(screenKey: String, tint: Color, isLive: Bool = false) -> NSImage? {
        let cacheKey = "\(screenKey)_\(isLive)"
        if let cached = thumbnailCache[cacheKey] {
            return cached
        }

        let displays = ScreenFingerprint.from(key: screenKey).displays.sorted { $0.originX < $1.originX }
        guard let first = displays.first else { return nil }
        let boundingBox = displays.reduce(CGRect(x: first.originX, y: first.originY, width: first.width, height: first.height)) { box, d in
            box.union(CGRect(x: d.originX, y: d.originY, width: d.width, height: d.height))
        }
        guard boundingBox.width > 0, boundingBox.height > 0 else { return nil }

        let canvasW: CGFloat = 20
        let canvasH: CGFloat = 14
        let scaleX = (canvasW - 2) / boundingBox.width
        let scaleY = (canvasH - 2) / boundingBox.height
        let scale = min(scaleX, scaleY)
        let layoutW = boundingBox.width * scale
        let layoutH = boundingBox.height * scale
        let offsetX = (canvasW - layoutW) / 2
        let offsetY = (canvasH - layoutH) / 2

        let image = NSImage(size: NSSize(width: canvasW, height: canvasH), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            for d in displays {
                let x = CGFloat(d.originX - Int(boundingBox.minX)) * scale + offsetX
                let y = CGFloat(d.originY - Int(boundingBox.minY)) * scale + offsetY
                let w = max(4.5, CGFloat(d.width) * scale)
                let h = max(3.5, CGFloat(d.height) * scale)
                let r = CGRect(x: x, y: y, width: w, height: h)
                let path = CGPath(roundedRect: r, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)

                let fillColor = isLive
                    ? NSColor.white.withAlphaComponent(0.40)
                    : NSColor.white.withAlphaComponent(0.20)
                let strokeColor = isLive
                    ? NSColor.white
                    : NSColor.white.withAlphaComponent(0.88)

                ctx.addPath(path)
                ctx.setFillColor(fillColor.cgColor)
                ctx.fillPath()

                ctx.addPath(path)
                ctx.setStrokeColor(strokeColor.cgColor)
                ctx.setLineWidth(isLive ? 1.25 : 0.90)
                ctx.strokePath()
            }

            if isLive {
                let dotRect = CGRect(x: canvasW - 4.5, y: canvasH - 4.5, width: 3.5, height: 3.5)
                ctx.addEllipse(in: dotRect)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillPath()
            }

            return true
        }
        image.isTemplate = false
        thumbnailCache[cacheKey] = image
        return image
    }
}

// MARK: - Command Badge View
struct CommandBadgeView: View {
    let isActive: Bool
    let isHovered: Bool
    let themeColor: Color
    
    @State private var offsetX: CGFloat = 100
    @State private var opacity: Double = 0.0
    @State private var glowRadius: CGFloat = 1.5
    @State private var glowOpacity: Double = 0.15
    @State private var strokeOpacity: Double = 0.3

    var body: some View {
        if isActive {
            Text("⌘⇧R")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(isHovered ? Color.white : themeColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? Color.white.opacity(0.2) : themeColor.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isHovered ? Color.white.opacity(0.6) : themeColor.opacity(strokeOpacity), lineWidth: 0.8)
                )
                .shadow(color: isHovered ? Color.white.opacity(0.5) : themeColor.opacity(glowOpacity), radius: glowRadius)
                .offset(x: offsetX)
                .opacity(opacity)
                .onAppear {
                    // Step 1: Slide in from far right (100 -> 0) slowly and fade in with glow
                    withAnimation(.spring(response: 0.75, dampingFraction: 0.7)) {
                        offsetX = 0
                        opacity = 1.0
                        glowRadius = 14
                        glowOpacity = 0.85
                        strokeOpacity = 0.85
                    }
                    // Step 2: Settle glow back to resting state
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_150_000_000)
                        withAnimation(.spring(response: 0.8, dampingFraction: 0.85)) {
                            glowRadius = 2.0
                            glowOpacity = 0.3
                            strokeOpacity = 0.35
                        }
                    }
                }
        } else {
            // Non-active rows: show ⌘⇧R dimly instead of the plain ⌘ icon
            Text("⌘⇧R")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(isHovered ? Color.white.opacity(0.9) : Color.secondary.opacity(0.6))
        }
    }
}

// MARK: - Menu Window List View (for Menu Bar)

struct MenuWindowListView: View {
    let snapshot: LayoutSnapshot
    let activeBundleID: String?
    var limitToActiveApp: Bool = false
    var specificRecords: [WindowRecord]? = nil
    @EnvironmentObject var manager: WindowManager
    @AppStorage("themeColor") private var themeColor: ThemeColor = .default
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .auto
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredRecordID: UUID? = nil
    @State private var isAppeared = false

    // Opacities that need boosting in light mode
    private var badgeBgOpacity: Double { colorScheme == .dark ? 0.1 : 0.18 }
    private var activeBgOpacity: Double { colorScheme == .dark ? 0.06 : 0.12 }
    private var activeBadgeBgOpacity: Double { colorScheme == .dark ? 0.15 : 0.22 }

    var body: some View {
        // Track which bundle IDs have already received the Active badge so that
        // only the first (topmost) window row for the frontmost app gets it.
        var seenActiveBundleIDs: Set<String> = []

        return VStack(spacing: 2) {
            if let customList = specificRecords {
                ForEach(customList) { record in
                    let isFirstOfApp: Bool = {
                        let bid = record.windowID.appBundleID
                        if seenActiveBundleIDs.contains(bid) { return false }
                        seenActiveBundleIDs.insert(bid)
                        return true
                    }()
                    appRow(record, isFirstOfApp: isFirstOfApp)
                        .scaleEffect(isAppeared ? 1.0 : 0.96)
                        .offset(y: isAppeared ? 0 : 4)
                        .opacity(isAppeared ? 1.0 : 0.0)
                }
            } else {
                let frontmostBundleID = activeBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                let activeRecords = snapshot.records.filter { $0.windowID.appBundleID == frontmostBundleID }
                let otherRecords = limitToActiveApp ? [] : snapshot.records.filter { $0.windowID.appBundleID != frontmostBundleID }
                let displayedActiveRecords = (!activeRecords.isEmpty || !limitToActiveApp) ? activeRecords : [snapshot.records.first].compactMap { $0 }

                if !displayedActiveRecords.isEmpty {
                    ForEach(Array(displayedActiveRecords.enumerated()), id: \.element.id) { index, record in
                        appRow(record, isFirstOfApp: index == 0)
                            .scaleEffect(isAppeared ? 1.0 : 0.96)
                            .offset(y: isAppeared ? 0 : 4)
                            .opacity(isAppeared ? 1.0 : 0.0)
                    }
                    if !otherRecords.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                            .padding(.horizontal, 14)
                    }
                }
                ForEach(otherRecords) { record in
                    appRow(record, isFirstOfApp: false)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                isAppeared = true
            }
        }
    }

    private func appRow(_ record: WindowRecord, isFirstOfApp: Bool = true) -> some View {
        let isForeground = record.windowID.appBundleID == snapshot.foregroundBundleID
        let rowTint = record.isFullScreenMode ? Color.indigo : themeColor.color(seed: 6)
        let isHovered = hoveredRecordID == record.id
        let itemTint = isHovered ? Color.white : rowTint
        // Active badge shown only on the first (topmost) window of the frontmost app
        let isActive = isFirstOfApp && record.windowID.appBundleID == (activeBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        
        return HStack(spacing: 12) {
            if record.isFullScreenMode {
                FullScreenPreviewIcon(tint: itemTint)
                    .frame(width: 32, height: 21)
            } else {
                WindowPreviewIcon(record: record, tint: itemTint)
                    .frame(width: 32, height: 21)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(record.windowID.appName ?? record.windowID.appBundleID)
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(isHovered ? Color(NSColor.selectedMenuItemTextColor) : Color.primary)
                        .lineLimit(1)
                    
                    if isActive {
                        Text("Active".localized(appLanguage))
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(isHovered ? Color.white.opacity(0.25) : Color.green.opacity(activeBadgeBgOpacity))
                            .foregroundStyle(isHovered ? Color.white : Color.green)
                            .clipShape(Capsule())
                            .scaleEffect(isAppeared ? 1.0 : 0.8)
                    }
                    
                    if isForeground {
                        Image(systemName: "square.3.layers.3d.top.filled")
                            .font(.system(size: 8))
                            .foregroundStyle(isHovered ? Color.white : themeColor.color(seed: 5))
                    }
                    
                    // ⌘ badge: visible when Command+Shift+R will be sent to this app.
                    // Shows only when the global trigger is on AND the app is not excluded.
                    let willReceiveCommand = (manager.store.refreshFrontmostOnFullRestore || manager.store.refreshFrontmostOnSingleRestore)
                        && snapshot.commandExcludedBundleIDs.contains(record.windowID.appBundleID)
                    if willReceiveCommand {
                        CommandBadgeView(
                            isActive: isActive,
                            isHovered: isHovered,
                            themeColor: themeColor.color(seed: 5)
                        )
                    }
                }
                
                HStack(spacing: 4) {
                    if let screenName = record.screenName {
                        Text(lz(screenName))
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(isHovered ? Color.white.opacity(0.2) : rowTint.opacity(badgeBgOpacity))
                            .foregroundStyle(isHovered ? Color.white : rowTint)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    
                    if !record.windowID.windowTitle.isEmpty {
                        Text(record.windowID.windowTitle)
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(isHovered ? Color(NSColor.selectedMenuItemTextColor).opacity(0.8) : .secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            
            if isHovered {
                Text("Restore".localized(appLanguage))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .padding(.trailing, 4)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isHovered ? Color(NSColor.selectedContentBackgroundColor) : Color.clear)
                
                if isActive && !isHovered {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(rowTint.opacity(activeBgOpacity))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(rowTint.opacity(isAppeared ? 0.35 : 0.0), lineWidth: 1.2)
                                .animation(.easeOut(duration: 0.45), value: isAppeared)
                        )
                        .overlay(
                            GeometryReader { geo in
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color.clear,
                                        rowTint.opacity(0.4),
                                        Color.white.opacity(0.25),
                                        rowTint.opacity(0.4),
                                        Color.clear
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .frame(width: geo.size.width * 0.4)
                                .offset(x: isAppeared ? geo.size.width * 1.3 : -geo.size.width * 0.5)
                                .animation(.easeOut(duration: 0.95).delay(0.1), value: isAppeared)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        )
                }
            }
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredRecordID = hovering ? record.id : nil
        }
        .onTapGesture {
            manager.restore(snapshot: snapshot, specificAppBundleID: record.windowID.appBundleID)
            NSApp.sendAction(#selector(NSMenu.cancelTracking), to: nil, from: nil)
        }
    }
}

