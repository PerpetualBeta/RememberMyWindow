//this file is the main view of the app
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: WindowManager
    @Environment(\.openSettings) private var openSettings
    @AppStorage("themeColor") private var themeColor: ThemeColor = .default
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .auto
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @ObservedObject private var desktopToggleManager = DesktopToggleManager.shared
    @State private var hidePermissionBanner = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar: Snapshot List
            SnapshotListView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 285, max: 360)
                .background {
                    if themeColor.isGalaxy {
                        ZStack {
                            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                            Color(red: 0.02, green: 0.04, blue: 0.12).opacity(0.68)
                        }
                        .ignoresSafeArea()
                    } else {
                        VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                            .ignoresSafeArea()
                    }
                }
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(themeColor.isGalaxy ? Color.white.opacity(0.18) : Color.primary.opacity(0.12))
                        .frame(width: 1)
                        .ignoresSafeArea()
                }
        } content: {
            // Content: Selected Snapshot Detail
            LayoutsView()
                .navigationSplitViewColumnWidth(min: 400, ideal: 500)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        liquidGlassHeaderSlider
                    }
                    ToolbarItem(placement: .principal) {
                        actionButtonsToolbar
                    }
                    ToolbarItem(placement: .primaryAction) {
                        settingsToolbarButton
                    }
                }
                .background {
                    if themeColor.isGalaxy {
                        ZStack {
                            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                            Color(red: 0.02, green: 0.04, blue: 0.12).opacity(0.60)
                        }
                        .ignoresSafeArea()
                    } else {
                        VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                            .ignoresSafeArea()
                    }
                }
                .overlay(alignment: .trailing) {
                    if themeColor.isGalaxy {
                        Rectangle()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: 1)
                            .ignoresSafeArea()
                    }
                }
        } detail: {
            // Detail (Inspector): Actions + Preview + Activity
            inspectorColumn
                .navigationSplitViewColumnWidth(min: 280, ideal: 350, max: 350)
                .background {
                    if themeColor.isGalaxy {
                        ZStack {
                            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                            Color(red: 0.02, green: 0.04, blue: 0.12).opacity(0.68)
                        }
                        .ignoresSafeArea()
                    } else {
                        VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                            .ignoresSafeArea()
                    }
                }
        }
        .overlay(alignment: .top) {
            if !manager.hasAccessibilityPermission && !hidePermissionBanner {
                permissionBanner
            }
        }
        .sheet(isPresented: Binding(
            get: { !hasCompletedOnboarding },
            set: { _ in }
        )) {
            OnboardingView {
                withAnimation { hasCompletedOnboarding = true }
                Task { @MainActor in
                    UpdateManager.shared.checkIfNeeded()
                }
            }
        }
        // Shown only on the first launch after upgrading from a build with a
        // hardcoded shortcut, and only once onboarding is out of the way so the
        // two sheets can never compete for the window.
        .sheet(isPresented: Binding(
            get: { hasCompletedOnboarding && desktopToggleManager.needsShortcutMigrationNotice },
            set: { _ in }
        )) {
            ShortcutMigrationView(language: appLanguage, manager: desktopToggleManager) {
                withAnimation { desktopToggleManager.acknowledgeShortcutChange() }
            }
        }
        .frame(minWidth: 1000, idealWidth: 1150, minHeight: 600, idealHeight: 750)
        .onOpenURL { url in
            if url.host == "toggle-desktop" {
                DesktopToggleManager.shared.toggleDesktop()
            }
        }
        .background {
            if themeColor.isGalaxy {
                GalaxyCosmicBackgroundView()
            }
        }
        .background(WindowTransparencyAccessor())
    }

    // MARK: - Inspector Column

    private var inspectorColumn: some View {
        VStack(spacing: 0) {
            // Layout Preview (Mini-map) — shown only when Auto Layout is OFF (when ON, it is in the center pane)
            if !manager.store.autoSaveEnabled {
                let previewSnapshot: LayoutSnapshot? = {
                    guard let key = manager.selectedSnapshotKey else { return nil }
                    if key == WindowManager.liveKey {
                        let fp = manager.currentFingerprint
                        return LayoutSnapshot(
                            id: UUID(),
                            name: fp.readableName,
                            screenKey: fp.key,
                            readableScreenKey: fp.readableName,
                            records: manager.liveRecords,
                            createdAt: Date(),
                            updatedAt: Date(),
                            location: nil,
                            isAutoSave: true
                        )
                    }
                    return manager.store.snapshots[key]
                }()

                if let snapshot = previewSnapshot {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("VISUAL PREVIEW".localized(appLanguage))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)

                        LayoutPreviewView(snapshot: snapshot, selectedRecordID: nil, tint: themeColor.color(seed: 2))
                            .frame(height: 160)
                            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: snapshot.records.count)
                    }
                    .padding(16)
                    // Slides out to the left (-x) when switching to Auto Layout;
                    // slides in from the left (-x -> 0) when returning to Saved Sessions.
                    // Mirrors the center-pane card to create seamless continuity between columns.
                    .transition(.asymmetric(
                        insertion: .offset(x: -260).combined(with: .opacity),
                        removal:   .offset(x: -260).combined(with: .opacity)
                    ))

                    Divider()
                }
            }
            
            // Activity Log
            ActivityView()
                .frame(maxHeight: .infinity)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: manager.store.autoSaveEnabled)
        .clipped()
    }

    @ViewBuilder
    private var actionButtonsToolbar: some View {
        HStack(spacing: 6) {

            if !manager.store.autoSaveEnabled {
                Button {
                    manager.saveNow()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                        Text((manager.willUpdateSession ? "Update Layout" : "Save Layout").localized(appLanguage))
                    }
                }
                .help({
                    if manager.isUpdateRestricted { return "Cannot update/save while a restricted or mismatched session is selected" }
                    if let key = manager.selectedSnapshotKey, key != WindowManager.liveKey,
                       let snapshot = manager.store.snapshots[key],
                       !manager.canRestore(snapshot: snapshot) {
                        return "Connect the required displays to update this session"
                    }
                    return manager.willUpdateSession ? "Update current layout" : "Save current window positions"
                }())
                .disabled({
                    if manager.isUpdateRestricted { return true }
                    if let key = manager.selectedSnapshotKey, key != WindowManager.liveKey,
                       let snapshot = manager.store.snapshots[key] {
                        return !manager.canRestore(snapshot: snapshot)
                    }
                    return false
                }())

                Button {
                    if let key = manager.selectedSnapshotKey, key != WindowManager.liveKey {
                        manager.restore(key: key)
                    } else {
                        manager.restoreNow()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward.circle")
                        Text("Restore".localized(appLanguage))
                    }
                }
                .help("Restore saved layout for current screens")
                .disabled({
                    if let key = manager.selectedSnapshotKey, key != WindowManager.liveKey {
                        if let snapshot = manager.store.snapshots[key] {
                            return !manager.canRestore(snapshot: snapshot)
                        }
                    }
                    return false
                }())
            }

        }
    }

    private var settingsToolbarButton: some View {
        Button {
            openSettings()
        } label: {
            Image(systemName: "gearshape")
        }
        .help("Settings".localized(appLanguage))
    }

    private var liquidGlassHeaderSlider: some View {
        Picker("", selection: Binding(
            get: { manager.store.autoSaveEnabled ? 0 : 1 },
            set: { val in
                withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                    manager.setAutoSaveEnabled(val == 0)
                }
            }
        )) {
            Text("\(Image(systemName: "clock.arrow.circlepath")) \("Auto Layout".localized(appLanguage))").tag(0)
            Text("\(Image(systemName: "folder")) \("Saved Sessions".localized(appLanguage))").tag(1)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .overlay(HoverBlockerView())
        .help("Switch between Auto Layout mode and Saved Sessions mode".localized(appLanguage))
    }

    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility Permission Required".localized(appLanguage))
                    .font(.headline)
                Text("To track and restore windows from other apps, please enable RememberMyWindows in System Settings. If already ON, toggle it OFF and ON to refresh macOS cache.".localized(appLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()

            Button("Re-check".localized(appLanguage)) {
                manager.checkAccessibilityPermissionManually()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            
            Button("Open System Settings".localized(appLanguage)) {
                manager.openAccessibilitySettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            
            Button {
                withAnimation {
                    hidePermissionBanner = true
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        }
        .padding(16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - HoverBlockerView (from iPhonePhotosBackup)

/// A transparent NSView overlay that absorbs mouse-entered/moved/exited events
/// so the underlying NSSegmentedControl never sees hover and therefore never
/// draws its hover-highlight state. Left-click events are NOT consumed —
/// they fall through to the control below via hitTest returning nil.
class HoverBlockingNSView: NSView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { /* swallow */ }
    override func mouseMoved(with event: NSEvent)   { /* swallow */ }
    override func mouseExited(with event: NSEvent)  { /* swallow */ }

    // Pass clicks through so the Picker still works.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct HoverBlockerView: NSViewRepresentable {
    func makeNSView(context: Context) -> HoverBlockingNSView { HoverBlockingNSView() }
    func updateNSView(_ nsView: HoverBlockingNSView, context: Context) { }
}
