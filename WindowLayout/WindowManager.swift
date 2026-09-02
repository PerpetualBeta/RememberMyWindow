//this file is in charge of the window manager plus the live records of the windows 
import AppKit
import Carbon
import Combine
import Foundation
import CoreLocation
import ServiceManagement
import UserNotifications

@MainActor
final class WindowManager: NSObject, ObservableObject, CLLocationManagerDelegate, UNUserNotificationCenterDelegate {

    static let shared = WindowManager()

    // MARK: - Published state
    @Published var store: LayoutStore = LayoutStore() {
        didSet { persist() }
    }
    @Published private(set) var currentFingerprint: ScreenFingerprint = .current()
    @Published private(set) var isTracking: Bool = false
    @Published private(set) var recentEvents: [TrackingEvent] = []
    

    @Published var statusMessage: String = "Ready"
    @Published var selectedSnapshotKey: String? = nil
    /// The app selected in the main window from the most recently opened menu bar list.
    @Published var selectedAppBundleID: String? = nil
    /// Live-updating window list (never persisted). Updated only after a window event,
    /// or by the legacy poller when it detects a change.
    @Published private(set) var liveRecords: [WindowRecord] = []
    @Published var hasAccessibilityPermission: Bool = AXIsProcessTrusted()
    @Published var launchAtLogin: Bool = false {
        didSet {
            if launchAtLogin != (ServiceManagement.SMAppService.mainApp.status == .enabled) {
                updateLaunchAtLogin(enabled: launchAtLogin)
            }
        }
    }

    // Sentinel key used to identify the live layout selection (not stored in the snapshot dict).
    static let liveKey = "__live__"

    // MARK: - Private
    private var permissionCheckTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var windowObservers: [AnyObject] = []
    private var debounceTask: Task<Void, Never>?
    private let saveURL: URL

    // Throttle: only record a window move/resize after it's been still for 0.8 s
    private var pendingSaves: [WindowID: WindowRecord] = [:]
    private var flushTask: Task<Void, Never>?
    private var trackingTask: Task<Void, Never>?
    private var lastKnownWindows: [WindowID: (frame: CGRect, id: UUID)] = [:]
    /// AX observers for event-driven window tracking. Keyed by PID.
    /// Each entry holds the AXObserver and its run-loop source so we can tear it down cleanly.
    private var axObservers: [pid_t: (observer: AXObserver, source: CFRunLoopSource)] = [:]
    private var axEventDebounceTask: Task<Void, Never>?
    /// Coalesces noisy AX notifications. Some apps emit move/resize notifications continuously
    /// even when their window is not changing, so never turn every notification into a full scan.
    private var isAXFlushScheduled = false
    private var lastAXCaptureDate: Date?
    private var axIdleCaptureInterval: TimeInterval = 2
    /// Persists AX window info across captures. When an app loses AX visibility (not frontmost,
    /// or in its own full-screen Space), AX returns virtual-space coordinates that are useless.
    /// We cache the last-known accurate frames and reuse them in those cases.
    private var cachedAXWindowsByPID: [Int32: [AXWindowInfo]] = [:]
    private var lastCGWindowsByPID: [Int32: [CGWindowBriefInfo]] = [:]
    private let locationManager = CLLocationManager()
    @Published private(set) var currentLocation: CLLocation? = nil
    @Published var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    private var pendingSaveName: String? = nil
    private var pendingSaveUpdate = false
    private var pendingCapturedWindows: [WindowRecord]? = nil
    private var pendingFP: ScreenFingerprint? = nil
    /// Set when the store existed at launch but could not be read. While true,
    /// saving is refused: the file on disk is a library the user still wants,
    /// and the empty one in memory is not.
    private var storeIsUnreadable = false
    private var isWaitingForLocationPermission: Bool = false
    private var isWaitingForLocationUpdate: Bool = false
    private var lastLocationTimestamp: Date? = nil
    /// Tracks window count across consecutive captures to detect sudden anomalous drops.
    private var lastWindowCount: Int = 0

    // MARK: - Screen Lock Tracking
    private var _isScreenLockedState: Bool = false

    /// Returns true if the macOS user session or screen is currently locked.
    var isScreenLocked: Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if (dict["CGSSessionScreenIsLocked"] as? Bool) == true ||
               (dict["CGSSessionScreenIsLocked"] as? Int) == 1 ||
               (dict["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true {
                return true
            }
        }
        return _isScreenLockedState
    }

    struct PendingUnlockRestoreAction {
        let snapshot: LayoutSnapshot
        let restoredCount: Int
        let totalCount: Int
        let connectedDisplayNames: [String]
        let shouldSendShortcut: Bool
    }
    private var pendingUnlockAction: PendingUnlockRestoreAction?

    override private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("RememberMyWindows", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        saveURL = dir.appendingPathComponent("layouts.json")
        super.init()
        
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationAuthorizationStatus = locationManager.authorizationStatus
        
        launchAtLogin = ServiceManagement.SMAppService.mainApp.status == .enabled
        UNUserNotificationCenter.current().delegate = self
        
        load()
        startPermissionMonitoring()
    }

    // MARK: - Safe AX Element Creation

    /// Creates an AXUIElement for an application PID with a safe messaging timeout (150ms default)
    /// to ensure unresponsive external apps never freeze the main thread or background scans.
    static func createAXElement(for pid: pid_t, timeoutSeconds: Float = 0.15) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeoutSeconds)
        return element
    }

    // MARK: - Public API

    func startTracking() {
        guard !isTracking else { return }
        isTracking = true

        // Observe screen changes (display connect/disconnect)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Observe screen lock and unlock state
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenLockedReceived),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenUnlockedReceived),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        // Location updates removed per user request

        // Observe ALL existing and new windows via accessibility / polling
        observeRunningApps()

        // Also watch for new apps launching
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        // Watch for apps terminating so we can remove their AX observers
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        // Track which app is frontmost — critical for diagnosing AX cache invalidations
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appFocusChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        if store.usePollingMode {
            startPolling()
        } else {
            startAXObservers()
        }

        log("Monitoring started (\(store.usePollingMode ? "polling" : "event-driven") mode)", level: .necessary, type: .system)
    }

    func stopTracking() {
        isTracking = false
        trackingTask?.cancel()
        axEventDebounceTask?.cancel()
        isAXFlushScheduled = false
        lastAXCaptureDate = nil
        axIdleCaptureInterval = 2
        stopAllAXObservers()
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        log("Monitoring stopped", level: .necessary, type: .system)
    }

    /// Called when the user toggles polling mode in Settings — restarts tracking with the new strategy.
    func restartTracking() {
        guard isTracking else { return }
        // Tear down only the capture strategy, leaving workspace observers intact
        trackingTask?.cancel()
        axEventDebounceTask?.cancel()
        isAXFlushScheduled = false
        lastAXCaptureDate = nil
        axIdleCaptureInterval = 2
        stopAllAXObservers()
        if store.usePollingMode {
            startPolling()
            log("Switched to polling mode", level: .necessary, type: .system)
        } else {
            startAXObservers()
            log("Switched to event-driven mode", level: .necessary, type: .system)
        }
    }

    /// True if saving right now would update an existing session rather than creating a new one.
    var willUpdateSession: Bool {
        let fp = currentFingerprint
        return store.snapshots.values.contains { !$0.isAutoSave && $0.screenKey == fp.key }
    }

    var isUpdateRestricted: Bool {
        let fp = currentFingerprint
        
        // If the user has selected a specific saved session
        if let selectedKey = selectedSnapshotKey,
           selectedKey != WindowManager.liveKey,
           let selectedSnap = store.snapshots[selectedKey] {
            
            let snapFP = ScreenFingerprint.from(key: selectedSnap.screenKey)
            
            // 1. Physical Mismatch: If models match but UUIDs differ, restrict update
            let currentUUIDs = Set(fp.displays.compactMap { $0.uuid })
            let snapUUIDs = Set(snapFP.displays.compactMap { $0.uuid })
            if fp.modelKey == snapFP.modelKey && currentUUIDs != snapUUIDs {
                return true
            }

            // 2. Single-screen session while multiple screens connected
            if fp.displays.count >= 2 && snapFP.displays.count == 1 {
                return true
            }
        }
        
        return false
    }

    /// The snapshot that `restoreNow()` will restore based on current displays.
    var currentApplicableSnapshot: LayoutSnapshot? {
        let fp = currentFingerprint
        if let defaultID = store.defaultSnapshotIDs[fp.key],
           let snap = store.snapshots[defaultID], !snap.isAutoSave {
            return snap
        } else {
            return store.snapshots.values
                .filter { $0.screenKey == fp.key && !$0.isAutoSave }
                .sorted { $0.updatedAt > $1.updatedAt }
                .first
        }
    }

    func saveNow(named snapshotName: String? = nil) {
        guard store.saveLocationEnabled else {
            performSave(named: snapshotName)
            return
        }

        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            pendingSaveName = snapshotName
            isWaitingForLocationPermission = true
            locationManager.requestWhenInUseAuthorization()
            log("Waiting for location permission before saving...", level: .moderate, type: .system)
            statusMessage = "Waiting for location permission…"
            return
        }
        
        performSave(named: snapshotName)
    }

    func requestLocationPermission() {
        isWaitingForLocationPermission = true
        locationManager.requestWhenInUseAuthorization()
    }

    private func performSave(named snapshotName: String?) {
        let fp = ScreenFingerprint.current()
        
        // Use previously captured windows if we are resuming from a location update
        let windows: [WindowRecord]
        if let pending = pendingCapturedWindows, let pFP = pendingFP, pFP.key == fp.key {
            windows = pending
            log("🔄 Resuming save with \(windows.count) preserved window records", level: .moderate, type: .system)
        } else {
            windows = captureAllWindows(for: fp)
        }
        
        // Include native full-screen windows so they can be restored as full screen
        let filteredWindows = windows
        
        // Ensure we have latest location if possible
        let status = locationManager.authorizationStatus
        let isAuthorized = store.saveLocationEnabled && status != .notDetermined && status != .denied && status != .restricted
        
        if isAuthorized && !isWaitingForLocationUpdate {
            // If location is nil OR older than 60 seconds, request a fresh one for manual save
            let isStale = currentLocation == nil || (lastLocationTimestamp?.timeIntervalSinceNow ?? -1000) < -60
            
            if isStale {
                pendingSaveName = snapshotName
                pendingSaveUpdate = (snapshotName == nil)
                pendingCapturedWindows = windows
                pendingFP = fp
                isWaitingForLocationUpdate = true
                
                // Note: We DON'T clear currentLocation here anymore to avoid UI flickering, 
                // but we wait for the fresh update below.
                
                locationManager.requestLocation()
                log("📍 Requesting fresh location before saving...", level: .moderate, type: .system)
                statusMessage = "Locating…"
                return
            }
        }
        
        // Clear pending state after we have location (or decided we don't need it)
        isWaitingForLocationUpdate = false
        pendingCapturedWindows = nil
        pendingFP = nil

        // ── Check for an existing saved session for this EXACT screen config ────
        let existingEntry = store.snapshots
            .filter { !$0.value.isAutoSave && $0.value.screenKey == fp.key }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .first

        if let (existingKey, existingSnapshot) = existingEntry {
            // ── UPDATE existing session (Exact match) ───────────────────────────
            let runningBundleIDs = Set(NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular || $0.activationPolicy == .accessory }
                .compactMap { $0.bundleIdentifier ?? $0.localizedName })

            // Keep old records only for apps that are NOT currently running
            var mergedRecords = existingSnapshot.records.filter { record in
                let appID = record.windowID.appBundleID
                return !runningBundleIDs.contains(appID)
            }
            
            // Append all currently captured windows
            mergedRecords.append(contentsOf: filteredWindows)

            var updated = existingSnapshot
            updated.records  = mergedRecords
            updated.updatedAt = Date()
            
            // Also update location if we have a fresh one and the snapshot lacks it or it's old
            if let loc = currentLocation {
                updated.location = LocationInfo(
                    latitude: loc.coordinate.latitude,
                    longitude: loc.coordinate.longitude,
                    address: updated.location?.address // Keep existing address for now, geocoder will update it
                )
            }
            
            store.snapshots[existingKey] = updated
            persist()

            // Trigger geocoder update for the updated session as well
            if let loc = currentLocation {
                updateSnapshotLocation(key: existingKey, location: loc)
            }

            // Build human-readable diff details
            let oldIDsForRunningApps = Set(existingSnapshot.records
                .filter { runningBundleIDs.contains($0.windowID.appBundleID) }
                .map { $0.windowID })
            let newIDs = Set(filteredWindows.map { $0.windowID })
            
            let addedRecords = filteredWindows.filter { !oldIDsForRunningApps.contains($0.windowID) }
            let removedRecords = existingSnapshot.records.filter { 
                runningBundleIDs.contains($0.windowID.appBundleID) && !newIDs.contains($0.windowID) 
            }

            let addedNames = addedRecords.map { $0.windowID.displayName }
            let removedNames = removedRecords.map { $0.windowID.displayName }
            var diffLines: [String] = []
            for n in addedNames { diffLines.append("➕ \(n)") }
            for n in removedNames { diffLines.append("➖ \(n)") }

            let summary: String
            if addedNames.isEmpty && removedNames.isEmpty {
                summary = "Positions updated"
            } else {
                var parts: [String] = []
                if !addedNames.isEmpty { parts.append("\(addedNames.count) added") }
                if !removedNames.isEmpty { parts.append("\(removedNames.count) removed") }
                parts.append("positions updated")
                summary = parts.joined(separator: ", ")
            }

            log("Session updated: '\(updated.name)' — \(summary)", level: .moderate,
                type: .manualSave,
                details: diffLines.isEmpty ? filteredWindows.map { formatWindowDetail(record: $0) } : diffLines)
            statusMessage = "Updated '\(updated.name)' · \(summary)"
            return
        }

        // ── Check if we have a session for the same hardware but DIFFERENT geometry ──
        let sameHardwareDiffGeometry = store.snapshots.values
            .filter { !$0.isAutoSave && ScreenFingerprint.from(key: $0.screenKey).hardwareKey == fp.hardwareKey }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first

        if let matchingHardware = sameHardwareDiffGeometry {
            log("Detected geometry change for '\(matchingHardware.name)'. Saving as a NEW session.", level: .moderate, type: .system)
        }

        // ── CREATE new session ───────────────────────────────────────────────────
        let newID = UUID().uuidString
        var snapshot = LayoutSnapshot(
            id: UUID(uuidString: newID) ?? UUID(),
            name: snapshotName ?? defaultName(for: fp),
            screenKey: fp.key,
            readableScreenKey: fp.readableName,
            records: [],
            createdAt: Date(),
            updatedAt: Date(),
            location: nil,
            isAutoSave: false
        )

        if let loc = currentLocation {
            snapshot.location = LocationInfo(
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                address: nil
            )
            updateSnapshotLocation(key: newID, location: loc)
        }
        filteredWindows.forEach { snapshot.upsert($0) }
        store.snapshots[newID] = snapshot
        persist()
        let details = filteredWindows.map { formatWindowDetail(record: $0) }
        log("Snapshot saved: \(snapshot.name)", level: .necessary, type: .manualSave, details: details)
        statusMessage = "Saved layout '\(snapshot.name)'"
    }

    /// Restore saved layout for the current screen config.
    /// Prefers the user-marked default; falls back to the most recent saved session.
    func restoreNow(animated: Bool? = nil, triggerSubtitle: String? = nil) {
        let fp = ScreenFingerprint.current()
        let candidate: LayoutSnapshot?
        if let defaultID = store.defaultSnapshotIDs[fp.key],
           let snap = store.snapshots[defaultID], !snap.isAutoSave {
            candidate = snap
        } else {
            candidate = store.snapshots.values
                .filter { $0.screenKey == fp.key && !$0.isAutoSave }
                .sorted { $0.updatedAt > $1.updatedAt }
                .first
        }
        guard let snapshot = candidate else {
            statusMessage = "No saved layout for current display config"
            return
        }
        let anim = animated ?? store.restoreAnimated
        restore(snapshot: snapshot, animated: anim, triggerSubtitle: triggerSubtitle)
    }

    /// Checks if a snapshot can be restored based on current screen configuration.
    /// Returns false if the snapshot requires external screens that are not currently connected.
    func canRestore(snapshot: LayoutSnapshot) -> Bool {
        // If the screen config matches exactly, it's always restorable
        if snapshot.screenKey == currentFingerprint.key {
            return true
        }

        let currentScreenNames = NSScreen.screens.map { $0.localizedName }
        
        // Find all screens used in the snapshot that are external
        let requiredExternalNames = Set(snapshot.records.compactMap { $0.screenName })
            .filter { name in
                let lower = name.lowercased()
                return !lower.contains("built-in") && !lower.contains("retina display")
            }

        for name in requiredExternalNames {
            if !currentScreenNames.contains(name) {
                // An external screen required by this snapshot is not detected
                return false
            }
        }

        return true
    }

    func restore(key: String, animated: Bool? = nil) {
        guard let snapshot = store.snapshots[key] else { return }
        
        if !canRestore(snapshot: snapshot) {
            log("Cannot restore: required external screens missing", level: .moderate, type: .system)
            statusMessage = "Restore failed: External screen not detected"
            return
        }

        let anim = animated ?? store.restoreAnimated
        restore(snapshot: snapshot, animated: anim)
    }

    func restore(snapshot: LayoutSnapshot, animated: Bool? = nil, specificAppBundleID: String? = nil, isAppLaunch: Bool = false, showNotification: Bool = true, skipCommandSend: Bool = false, triggerSubtitle: String? = nil, completion: (@MainActor () -> Void)? = nil) {
        if !canRestore(snapshot: snapshot) {
            log("Cannot restore: required external screens missing", level: .moderate, type: .system)
            statusMessage = "Restore failed: External screen not detected"
            return
        }
        let anim = animated ?? store.restoreAnimated
        restore(snapshot: snapshot, animated: anim, specificAppBundleID: specificAppBundleID, isAppLaunch: isAppLaunch, showNotification: showNotification, skipCommandSend: skipCommandSend, triggerSubtitle: triggerSubtitle, completion: completion)
    }

    @objc private func appFocusChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let name = app.localizedName ?? "Unknown App"
        // Focus changes can sometimes signal that an app has moved to a different Space,
        // which might invalidate our AX frame cache for that PID.
        log("🎯 Focus changed: \(name)", level: .verbose, type: .system)
    }



    /// Brings the app with the given bundle ID above all other windows.
    func bringAppToFront(bundleID: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID || $0.localizedName == bundleID
        }) else {
            log("Bring to front: '\(bundleID)' not running", level: .moderate, type: .system)
            return
        }
        
        if app.isActive {
            log("'\(app.localizedName ?? bundleID)' is already in front, skipping activation", level: .verbose, type: .system)
            return
        }
        
        // 1. Try standard activation
        app.activate()
        
        // 2. Try Workspace openApplication (often more aggressive)
        if let url = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        }
        
        log("Brought '\(app.localizedName ?? bundleID)' to front", level: .moderate, type: .system)
    }

    /// Sets the preferred app to bring to front for a specific layout.
    func setForegroundApp(key: String, bundleID: String) {
        guard var snap = store.snapshots[key] else { return }
        // Toggle: if already set to this app, clear it; otherwise set it
        if snap.foregroundBundleID == bundleID {
            snap.foregroundBundleID = nil
            log("Cleared foreground app for session", level: .moderate, type: .system)
        } else {
            snap.foregroundBundleID = bundleID
            log("Set foreground app to '\(bundleID)' for session", level: .moderate, type: .system)
        }
        store.snapshots[key] = snap
        persist()
    }

    func deleteSnapshot(key: String) {
        if let snap = store.snapshots[key] {
            store.snapshots.removeValue(forKey: key)
            if store.defaultSnapshotIDs[snap.screenKey] == key {
                store.defaultSnapshotIDs.removeValue(forKey: snap.screenKey)
                // Don't automatically assign a new default; let the next auto-save create a fresh one if needed
            }
            if selectedSnapshotKey == key {
                selectedSnapshotKey = nil
            }
            persist()
            log("Session deleted: \(snap.name)", level: .moderate, type: .system)
        }
    }

    func removeAppFromSnapshot(key: String, windowID: WindowID) {
        if var snap = store.snapshots[key] {
            snap.records.removeAll { $0.windowID == windowID }
            // Clean up excluded app set if this was the last window of that app in the snapshot
            let hasRemaining = snap.records.contains { $0.windowID.appBundleID == windowID.appBundleID }
            if !hasRemaining {
                snap.commandExcludedBundleIDs.remove(windowID.appBundleID)
            }
            store.snapshots[key] = snap
            persist()
            log("Removed '\(windowID.displayName)' from session: \(snap.name)", level: .moderate, type: .system)
        }
    }

    /// Captures the live window positions of the specified application and updates (or adds) them in the active session layout.
    func updateOrAddAppInActiveSnapshot(bundleID: String) {
        let fp = ScreenFingerprint.current()
        let applicableID = currentApplicableSnapshot?.id
        let activePair = store.snapshots.first(where: { $0.value.id == applicableID })
            ?? (selectedSnapshotKey != nil ? store.snapshots.first(where: { $0.key == selectedSnapshotKey! }) : nil)
            ?? store.snapshots.first(where: { $0.value.screenKey == fp.key && !$0.value.isAutoSave })
            ?? store.snapshots.first
        
        guard let (key, snapToUpdate) = activePair else { return }
        var snap = snapToUpdate
        
        // Only save the frontmost (first) window — exactly 1 record per app in the layout.
        // Restore broadcasts this single position to ALL currently open windows of the app.
        let allCaptured = captureWindowsForApp(bundleID: bundleID, fp: fp)
        let appName = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })?.localizedName ?? bundleID

        guard let frontmostRecord = allCaptured.first else {
            log("Could not add '\(appName)': No open window detected", level: .necessary, type: .system)
            deliverNotification(type: .snapshotUpdate, title: "Cannot Add \(appName)", subtitle: "No open window detected", isCompact: true, bundleID: bundleID)
            return
        }

        let wasAlreadyPresent = snap.records.contains { $0.windowID.appBundleID == bundleID }
        
        // Replace all existing records for this app with the single frontmost window
        snap.records.removeAll { $0.windowID.appBundleID == bundleID }
        snap.records.append(frontmostRecord)
        snap.updatedAt = Date()
        
        store.snapshots[key] = snap
        persist()
        objectWillChange.send()
        
        let actionName = wasAlreadyPresent ? "Updated" : "Added"
        log("\(actionName) '\(appName)' in active layout session: \(snap.displayName)", level: .necessary, type: .system)
        
        deliverNotification(type: .snapshotUpdate, title: "\(appName) \(actionName)", subtitle: snap.displayName, isCompact: true, bundleID: bundleID)
    }

    /// Captures live window records for a specific app.
    /// Uses a direct CGWindowList read (always accurate regardless of focus) for screen detection,
    /// then cross-references with the AX cache only for full-screen flag and ghost filtering.
    private func captureWindowsForApp(bundleID: String, fp: ScreenFingerprint) -> [WindowRecord] {
        // --- Primary path: read live CG windows for this app and detect screen from real coords ---
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            return []
        }
        let targetPID = app.processIdentifier
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let screens = NSScreen.screens
        let primaryScreenHeight = screens.first?.frame.height ?? 0
        let appName = app.localizedName ?? bundleID

        // Collect live CG windows for this app (layer 0, >50×50, alpha >0.01)
        struct LiveWindow {
            let cgFrame: CGRect      // CG coords (top-left origin)
            let appKitFrame: CGRect  // AppKit coords (bottom-left origin)
            let title: String
            let windowNumber: Int
            let isOnScreen: Bool
        }

        var liveWindows: [LiveWindow] = []
        for entry in windowList {
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid == targetPID else { continue }
            guard let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let w = bounds["Width"] as? CGFloat,
                  let h = bounds["Height"] as? CGFloat,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0, w > 50, h > 50 else { continue }
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.01 else { continue }
            let title = entry[kCGWindowName as String] as? String ?? ""
            let windowNum = entry[kCGWindowNumber as String] as? Int ?? Int.max
            let isOnScreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? false
            let cgFrame = CGRect(x: x, y: y, width: w, height: h)
            let appKitFrame = CGRect(x: x, y: primaryScreenHeight - y - h, width: w, height: h)
            liveWindows.append(LiveWindow(cgFrame: cgFrame, appKitFrame: appKitFrame,
                                          title: title, windowNumber: windowNum, isOnScreen: isOnScreen))
        }

        // Prefer on-screen windows (off-screen ones may be minimized / on another Space).
        let candidates = liveWindows.filter { $0.isOnScreen }.isEmpty ? liveWindows : liveWindows.filter { $0.isOnScreen }

        guard !candidates.isEmpty else {
            // Nothing visible at all — fall back to the general captureAllWindows path
            let allRecords = captureAllWindows(for: fp, silent: true)
            return allRecords.filter { $0.windowID.appBundleID == bundleID }
        }

        // Build AX isFullScreen map by querying the app's AX element fresh (skip cache for accuracy)
        var axFullScreenFlags: [Int: Bool] = [:] // indexed by window position order
        let axApp = WindowManager.createAXElement(for: targetPID)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let axWins = windowsRef as? [AXUIElement] {
            for (i, win) in axWins.enumerated() {
                var fsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fsRef) == .success,
                   let fs = fsRef as? Bool {
                    axFullScreenFlags[i] = fs
                }
            }
        }

        // Convert candidates → WindowRecords, picking screen from appKitFrame intersection
        var records: [WindowRecord] = []
        for (idx, win) in candidates.enumerated() {
            let screen = screens.max(by: { s1, s2 in
                s1.frame.intersection(win.appKitFrame).area < s2.frame.intersection(win.appKitFrame).area
            })
            let wid = WindowID(appBundleID: bundleID, appName: appName, windowTitle: win.title, appWindowIndex: idx)
            var record = WindowRecord(
                id: UUID(),
                windowID: wid,
                globalFrame: win.appKitFrame,
                screenKey: fp.key,
                screenFrame: screen?.frame,
                screenName: screen?.localizedName ?? "Unknown Screen",
                savedAt: Date(),
                zIndex: idx
            )
            if axFullScreenFlags[idx] == true {
                record.isNativeFullScreen = true
                record.isFullScreenMode = true
            }
            records.append(record)
        }
        return records
    }


    func toggleCommandExclusion(key: String, bundleID: String) {
        guard var snap = store.snapshots[key] else { return }
        if snap.commandExcludedBundleIDs.contains(bundleID) {
            snap.commandExcludedBundleIDs.remove(bundleID)
            log("App '\(bundleID)' is now EXCLUDED from command triggers", level: .moderate, type: .system)
        } else {
            snap.commandExcludedBundleIDs.insert(bundleID)
            log("App '\(bundleID)' is now INCLUDED in command triggers", level: .moderate, type: .system)
        }
        store.snapshots[key] = snap
        persist()
    }

    func renameSnapshot(key: String, newName: String) {
        store.snapshots[key]?.name = newName
        persist()
    }

    func makeDefault(key: String) {
        guard let snapshot = store.snapshots[key] else { return }
        store.defaultSnapshotIDs[snapshot.screenKey] = key
        persist()
    }

    func updateLocationAddress(key: String, newAddress: String) {
        store.snapshots[key]?.location = LocationInfo(
            latitude: store.snapshots[key]?.location?.latitude ?? 0,
            longitude: store.snapshots[key]?.location?.longitude ?? 0,
            address: newAddress
        )
        persist()
    }

    private func updateLaunchAtLogin(enabled: Bool) {
        let service = ServiceManagement.SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            log("\(enabled ? "Enabled" : "Disabled") launch at login", level: .moderate, type: .system)
        } catch {
            log("Failed to \(enabled ? "register" : "unregister") login item: \(error.localizedDescription)", level: .moderate, type: .system)
            // Revert state if it failed
            Task { @MainActor in
                self.launchAtLogin = service.status == .enabled
            }
        }
    }

    // MARK: - Tracking internals

    private func observeRunningApps() {
        let ownBundleID = Bundle.main.bundleIdentifier
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == ownBundleID {
            observeApp(app)
        }
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // Configurable delay so the app's windows appear
        let delay = store.singleAppRestoreDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.observeApp(app)
            // In event-driven mode, attach an AX observer so we detect its future window movements
            if !self.store.usePollingMode {
                self.attachAXObserver(to: app)
                // Trigger one immediate capture to populate the live layout for the new app
                self.scheduleAXEventFlush()
            }
            
            if self.store.autoRestoreOnAppOpen {
                if let snapshot = self.currentApplicableSnapshot {
                    let targetID = app.bundleIdentifier ?? app.localizedName
                    if let targetID = targetID {
                        self.restore(snapshot: snapshot, animated: self.store.restoreAnimated, specificAppBundleID: targetID, isAppLaunch: true, showNotification: true)
                    }
                }
            }
        }
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        detachAXObserver(for: pid)
        // Invalidate AX caches for this PID so stale data doesn't linger
        cachedAXWindowsByPID.removeValue(forKey: pid)
        lastCGWindowsByPID.removeValue(forKey: pid)
        // Schedule a flush so the live layout drops the terminated app's windows
        if !store.usePollingMode {
            scheduleAXEventFlush()
        }
    }

    private func observeApp(_ app: NSRunningApplication) {
        guard let pid = Optional(app.processIdentifier), pid > 0 else { return }
        _ = WindowManager.createAXElement(for: pid)

        // We can't enumerate AX windows from here without accessibility permission,
        // so instead we hook NSWindow notifications for windows in OUR process,
        // and use a polling approach for other processes via NSWorkspace/CGWindowList.
        // For our own process we use notification observers.
        if app.bundleIdentifier == Bundle.main.bundleIdentifier {
            attachWindowNotifications()
        }
        // External windows are captured via CGWindowList on demand.
    }

    private func attachWindowNotifications() {
        let nc = NotificationCenter.default
        let names: [NSNotification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification
        ]
        for name in names {
            let obs = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    guard let win = note.object as? NSWindow else { return }
                    self?.windowDidChange(win)
                }
            }
            windowObservers.append(obs as AnyObject)
        }
    }

    private func windowDidChange(_ window: NSWindow) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let title = window.title
        let frame = window.frame
        let fp = ScreenFingerprint.current()
        let screenKey = fp.key
        
        // Find which screen this window is mostly on
        let midPoint = CGPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(midPoint) } ?? NSScreen.screens.first { $0.frame.intersects(frame) }
        let screenName = screen?.localizedName ?? "Unknown Screen"
        let appName = ProcessInfo.processInfo.processName

        let wid = WindowID(appBundleID: bundleID, appName: appName, windowTitle: title, appWindowIndex: 0)
        let record = WindowRecord(
            windowID: wid,
            globalFrame: frame,
            screenKey: screenKey,
            screenFrame: screen?.frame,
            screenName: screenName,
            savedAt: Date()
        )

        pendingSaves[wid] = record

        // Debounce flush
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPendingSaves()
        }
    }

    private func flushPendingSaves() {
        pendingSaves.removeAll()
        let fp = ScreenFingerprint.current()
        let currentWindows = captureAllWindows(for: fp, silent: true)
        let newCount = currentWindows.count

        // Detect sudden anomalous window count drops (≥3 windows lost in one cycle).
        // Normal fluctuations are 0–1 as apps launch/quit. Large drops signal a filter regression.
        if lastWindowCount > 0 && lastWindowCount - newCount >= 3 {
            log("⚠️ Window count dropped: \(lastWindowCount) → \(newCount) — possible AX filter regression or Space switch", level: .moderate, type: .system)
        }
        lastWindowCount = newCount

        // AX can repeatedly notify us about an app that has not actually changed. Publishing
        // the same layout re-renders the full SwiftUI preview (and its springs) every time,
        // preventing App Nap and causing substantial idle energy use.
        guard liveLayoutChanged(from: liveRecords, to: currentWindows) else {
            // A noisy AX source becomes almost free at idle: 2, 4, 8, 16, then at most
            // one validation scan every 30 seconds.
            axIdleCaptureInterval = min(axIdleCaptureInterval * 2, 30)
            return
        }
        axIdleCaptureInterval = 2
        liveRecords = currentWindows
        log("Live layout updated (\(newCount) windows)", level: .verbose, type: .autoSave)
    }

    /// Compares the display-relevant parts of two captures while tolerating the small coordinate
    /// variations returned by the accessibility APIs between otherwise identical snapshots.
    private func liveLayoutChanged(from previous: [WindowRecord], to current: [WindowRecord]) -> Bool {
        guard previous.count == current.count else { return true }

        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.windowID, $0) })
        for record in current {
            guard let old = previousByID[record.windowID],
                  old.screenKey == record.screenKey,
                  old.screenName == record.screenName,
                  old.zIndex == record.zIndex,
                  old.isFullScreenMode == record.isFullScreenMode,
                  old.isNativeFullScreen == record.isNativeFullScreen,
                  framesMatch(old.globalFrame, record.globalFrame) else {
                return true
            }
        }
        return false
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance &&
        abs(lhs.origin.y - rhs.origin.y) <= tolerance &&
        abs(lhs.width - rhs.width) <= tolerance &&
        abs(lhs.height - rhs.height) <= tolerance
    }


    func clearEvents() {
        recentEvents.removeAll()
    }

    // MARK: - Lock State Handlers

    @objc private func screenLockedReceived() {
        _isScreenLockedState = true
        log("🔒 Screen is locked", level: .verbose, type: .system)
    }

    @objc private func sessionDidResignActive() {
        _isScreenLockedState = true
    }

    @objc private func screensDidSleep() {
        _isScreenLockedState = true
    }

    @objc private func screensDidWake() {
        if !isScreenLocked {
            _isScreenLockedState = false
            handleScreenUnlockedIfNeeded()
        }
    }

    @objc private func sessionDidBecomeActive() {
        _isScreenLockedState = false
        handleScreenUnlockedIfNeeded()
    }

    @objc private func screenUnlockedReceived() {
        _isScreenLockedState = false
        log("🔓 Screen unlocked", level: .moderate, type: .system)
        handleScreenUnlockedIfNeeded()
    }

    private func handleScreenUnlockedIfNeeded() {
        guard let pending = pendingUnlockAction else { return }
        pendingUnlockAction = nil

        log("🔓 Mac unlocked. Executing post-unlock layout settlement for '\(pending.snapshot.name)'...", level: .moderate, type: .restore)

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Settle delay: allow WindowServer and Spaces to finish the unlock transition
            try? await Task.sleep(nanoseconds: 400_000_000) // 400ms (0.4s)

            // 1. 3-pass progressive verification & correction sweep for positions and dimensions
            await self.verifyAndCorrectWindowFrames(for: pending.snapshot)

            // 2. Bring preferred foreground app to front
            if let targetBundleID = pending.snapshot.foregroundBundleID {
                try? await Task.sleep(nanoseconds: 200_000_000)
                self.bringAppToFront(bundleID: targetBundleID)
            }

            // 3. Deliver deferred Notch Notification
            self.deliverNotification(
                type: .fullRestore,
                title: "Layout Restored",
                subtitle: "\(pending.snapshot.name) · \(pending.restoredCount)/\(pending.totalCount) \(lz("windows"))"
            )

            // 4. Send Command+Shift+R shortcut if enabled
            if pending.shouldSendShortcut {
                self.sendCommandToFrontmostApp(targetBundleID: pending.snapshot.foregroundBundleID, snapshot: pending.snapshot)
            }
        }
    }

    /// Re-verifies all window positions and dimensions against a snapshot and corrects any mismatches (e.g. after screen unlock).
    func verifyAndCorrectWindowFrames(for snapshot: LayoutSnapshot) async {
        let runningApps = Dictionary(
            NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { _, new in new }
        )
        let primaryScreenH = NSScreen.screens.first?.frame.height ?? 0
        let tolerance: CGFloat = 15.0

        func isFrameClose(to target: CGRect, current: CGRect) -> Bool {
            abs(current.origin.x - target.origin.x) <= tolerance &&
            abs(current.origin.y - target.origin.y) <= tolerance &&
            abs(current.size.width - target.size.width) <= tolerance &&
            abs(current.size.height - target.size.height) <= tolerance
        }

        var resolvedTargets: [(record: WindowRecord, element: AXUIElement, targetFrame: CGRect)] = []
        let groupedRecords = Dictionary(grouping: snapshot.records, by: { $0.windowID.appBundleID })

        for (bundleID, appRecords) in groupedRecords {
            guard let app = runningApps.values.first(where: { $0.bundleIdentifier == bundleID || $0.localizedName == bundleID }) else {
                continue
            }
            let appAX = WindowManager.createAXElement(for: app.processIdentifier)
            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                  let windowList = windowsValue as? [AXUIElement] else {
                continue
            }

            var unclaimed = windowList
            for rec in appRecords {
                if rec.isNativeFullScreen || rec.isFullScreenMode { continue }
                let target = self.calculateTargetFrame(for: rec)
                let targetSize = rec.globalFrame.size
                let targetAspect = targetSize.width / max(targetSize.height, 1)

                var bestIdx = -1
                var bestDiff = CGFloat.infinity

                for (idx, el) in unclaimed.enumerated() {
                    guard let frame = self.getCurrentFrame(of: el) else { continue }
                    let elAspect = frame.width / max(frame.height, 1)
                    let aspectDiff = abs(elAspect - targetAspect)
                    let targetArea = targetSize.width * targetSize.height
                    let elArea = frame.width * frame.height
                    let areaDiff = abs(elArea - targetArea) / max(targetArea, 1)
                    let score = aspectDiff * 2.0 + areaDiff
                    if score < bestDiff {
                        bestDiff = score
                        bestIdx = idx
                    }
                }

                if bestIdx != -1 {
                    let element = unclaimed.remove(at: bestIdx)
                    resolvedTargets.append((record: rec, element: element, targetFrame: target))
                }
            }
        }

        guard !resolvedTargets.isEmpty else { return }

        // 3 progressive correction sweeps with settle intervals
        for sweepAttempt in 1...3 {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms settle per sweep
            var mismatches: [(record: WindowRecord, element: AXUIElement, targetFrame: CGRect)] = []

            for resolved in resolvedTargets {
                guard let current = self.getCurrentFrame(of: resolved.element) else { continue }
                let targetFrame = resolved.targetFrame
                let axTargetFrame = CGRect(
                    x: targetFrame.origin.x,
                    y: primaryScreenH - targetFrame.origin.y - targetFrame.height,
                    width: targetFrame.width,
                    height: targetFrame.height
                )
                if !isFrameClose(to: axTargetFrame, current: current) {
                    mismatches.append(resolved)
                }
            }

            if mismatches.isEmpty {
                self.log("✅ Post-unlock window frame verification verified all \(resolvedTargets.count) windows in position.", level: .verbose, type: .restore)
                break
            }

            self.log("⚠️ Post-unlock verification sweep \(sweepAttempt)/3 found \(mismatches.count) mismatched window(s). Correcting...", level: .moderate, type: .restore)
            for resolved in mismatches {
                let targetFrame = resolved.targetFrame
                let axX = targetFrame.origin.x
                let axY = primaryScreenH - targetFrame.origin.y - targetFrame.height
                let axW = targetFrame.width
                let axH = targetFrame.height

                var pos = CGPoint(x: axX, y: axY)
                var sz = CGSize(width: axW, height: axH)

                if let v = AXValueCreate(.cgPoint, &pos) {
                    _ = AXUIElementSetAttributeValue(resolved.element, kAXPositionAttribute as CFString, v)
                }
                if let v = AXValueCreate(.cgSize, &sz) {
                    _ = AXUIElementSetAttributeValue(resolved.element, kAXSizeAttribute as CFString, v)
                }
                if let v = AXValueCreate(.cgPoint, &pos) {
                    _ = AXUIElementSetAttributeValue(resolved.element, kAXPositionAttribute as CFString, v)
                }
            }
        }
    }

    // MARK: - Screen Change
    
    private var screenChangeTask: Task<Void, Never>?
    private var pendingConnectedNames: Set<String> = []

    @objc private func screensChanged() {
        let oldFP = currentFingerprint
        let newFP = ScreenFingerprint.current()
        let newKey = newFP.key
        currentFingerprint = newFP

        if oldFP == newFP {
            log("🖥️ Display parameters changed (e.g. transparency), but physical configuration is identical. Ignoring.", level: .verbose, type: .system)
            return
        }

        log("🖥️ Display config changed → \(newFP.readableName) (\(newFP.displays.count) screen(s))", level: .moderate, type: .system)

        let hasSavedSession = store.snapshots.values.contains { $0.screenKey == newKey && !$0.isAutoSave }

        // Detect added / removed displays
        let oldScreens = Set(oldFP.displays.map { $0.screenNumber })
        let newScreens = Set(newFP.displays.map { $0.screenNumber })
        let addedScreens   = newScreens.subtracting(oldScreens)
        let removedScreens = oldScreens.subtracting(newScreens)

        if !removedScreens.isEmpty {
            // Display removal invalidates all cached AX frames — positions shift unpredictably
            log("⚠️ Display removed — clearing AX cache to prevent ghost windows", level: .moderate, type: .system)
            cachedAXWindowsByPID.removeAll()
            lastCGWindowsByPID.removeAll()
        }


        let connectedScreenNames = addedScreens.compactMap { num in
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? Int) == num }?.localizedName
        }
        
        for name in connectedScreenNames {
            if name != "Unknown Screen" && !name.isEmpty {
                pendingConnectedNames.insert(name)
            }
        }
        
        // Even if we don't know the name yet, remember that a screen was added
        let hasAnyAddedScreens = !addedScreens.isEmpty

        if store.autoRestoreEnabled && hasSavedSession {
            screenChangeTask?.cancel()
            screenChangeTask = Task { @MainActor [weak self] in
                // Wait 1.0 second for the display connection storm to settle
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self = self else { return }

                let isLocked = self.isScreenLocked
                if isLocked {
                    self.log("🔒 Screen is locked. Performing silent background restore (suppressing notch overlay and shortcuts until unlock)...", level: .necessary, type: .restore)
                }

                // Show initial "Connected" notification (or send system notification if locked)
                let names = Array(self.pendingConnectedNames)
                let notifTitle: String
                if !names.isEmpty {
                    let joinedNames = names.joined(separator: " & ")
                    notifTitle = "\(joinedNames) Connected"
                } else if hasAnyAddedScreens {
                    notifTitle = "Display Connected"
                } else {
                    notifTitle = "Display Configuration Changed"
                }

                self.deliverNotification(type: .displayChange, title: notifTitle, subtitle: "Restoring layout...")

                // Start restoration
                self.restoreNow()
                
                // Clear the pending names
                self.pendingConnectedNames.removeAll()
            }
        }
    }

    // MARK: - Notification Delivery (Notch & macOS System Notifications)

    enum NotificationEventType {
        case fullRestore
        case singleRestore
        case displayChange
        case snapshotUpdate
        case desktopToggle
        case permissionWarning
    }

    private var notchWindow: NotchNotificationWindow?


    func showNotchNotificationPublic(title: String, subtitle: String, isCompact: Bool = false, bundleID: String? = nil, appIcon: NSImage? = nil, triggerKey: String? = nil) {
        deliverNotification(type: .singleRestore, title: title, subtitle: subtitle, isCompact: isCompact, bundleID: bundleID, appIcon: appIcon, triggerKey: triggerKey)
    }

    /// Settings hover-preview: fires only the specified channel with realistic notification text and icons.
    func previewChannelNotification(channel: NotificationChannel, eventType: NotificationEventType) {
        let (title, subtitle, isCompact, bundleID): (String, String, Bool, String?) = {
            switch eventType {
            case .fullRestore:
                let snapName = self.store.snapshots.values.first?.name ?? lz("Home")
                let count = self.store.snapshots.values.first?.records.count ?? 5
                let winWord = lz("Windows").lowercased()
                return (lz("Layout Restored"), "\(snapName) · \(count)/\(count) \(winWord)", false, nil)
            case .singleRestore:
                return ("Safari \(lz("Restored"))", "", true, "com.apple.Safari")
            case .displayChange:
                return (lz("Display Connected"), lz("Restoring layout..."), false, nil)
            case .snapshotUpdate:
                let snapName = self.store.snapshots.values.first?.name ?? lz("Home")
                return ("Safari \(lz("Saved"))", snapName, true, "com.apple.Safari")
            case .desktopToggle:
                return (lz("Desktop Clean"), lz("All windows hidden"), true, "com.apple.finder")
            case .permissionWarning:
                return ("RememberMyWindows", lz("Permission required"), false, nil)
            }
        }()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if channel == .notch {
                // Force notch only — bypass showSystemNotification check
                guard !self.isScreenLocked else { return }
                self.notchWindow?.dismiss()
                let window = NotchNotificationWindow(title: title, subtitle: subtitle, isCompact: isCompact, bundleID: bundleID, appIcon: nil)
                self.notchWindow = window
                window.show()
                // Also play the correct per-event sound for the notch channel
                let soundEnabled: Bool
                let soundName: String
                switch eventType {
                case .fullRestore:
                    soundEnabled = self.store.notchSoundOnFullRestore
                    soundName = self.store.notchSoundNameFullRestore
                case .singleRestore:
                    soundEnabled = self.store.notchSoundOnSingleRestore
                    soundName = self.store.notchSoundNameSingleRestore
                case .displayChange:
                    soundEnabled = self.store.notchSoundOnDisplayChange
                    soundName = self.store.notchSoundNameDisplayChange
                case .snapshotUpdate:
                    soundEnabled = self.store.notchSoundOnSnapshotUpdate
                    soundName = self.store.notchSoundNameSnapshotUpdate
                case .desktopToggle:
                    soundEnabled = self.store.notchSoundOnDesktopToggle
                    soundName = self.store.notchSoundNameDesktopToggle
                case .permissionWarning:
                    soundEnabled = true
                    soundName = self.store.defaultNotificationSound
                }
                if soundEnabled { SystemSound.playSound(named: soundName, volume: Float(self.store.notchSoundVolume)) }
            } else {
                // Force system notification only — bypass showNotchNotification check
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = subtitle
                // Play the correct per-event sound for the system channel
                let soundEnabled: Bool
                let soundName: String
                switch eventType {
                case .fullRestore:
                    soundEnabled = self.store.systemSoundOnFullRestore
                    soundName = self.store.systemSoundNameFullRestore
                case .singleRestore:
                    soundEnabled = self.store.systemSoundOnSingleRestore
                    soundName = self.store.systemSoundNameSingleRestore
                case .displayChange:
                    soundEnabled = self.store.systemSoundOnDisplayChange
                    soundName = self.store.systemSoundNameDisplayChange
                case .snapshotUpdate:
                    soundEnabled = self.store.systemSoundOnSnapshotUpdate
                    soundName = self.store.systemSoundNameSnapshotUpdate
                case .desktopToggle:
                    soundEnabled = self.store.systemSoundOnDesktopToggle
                    soundName = self.store.systemSoundNameDesktopToggle
                case .permissionWarning:
                    soundEnabled = true
                    soundName = self.store.defaultNotificationSound
                }
                content.sound = soundEnabled ? .default : nil
                if soundEnabled { SystemSound.playSound(named: soundName, volume: Float(self.store.systemSoundVolume)) }
                let request = UNNotificationRequest(identifier: "preview-\(UUID().uuidString)", content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
            }
        }
    }

    func deliverNotification(
        type: NotificationEventType,
        title: String,
        subtitle: String,
        isCompact: Bool = false,
        bundleID: String? = nil,
        appIcon: NSImage? = nil,
        triggerKey: String? = nil,
        silent: Bool = false
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // 1. Notch Notification (suppressed while screen is locked to prevent LockScreen compositor flickering)
            let showNotch = UserDefaults.standard.object(forKey: "showNotchNotification") as? Bool ?? true
            if showNotch && !self.isScreenLocked {
                var shouldShowNotch = false
                var notchSoundEnabled = false
                var notchSoundName = self.store.defaultNotificationSound
                switch type {
                case .fullRestore:
                    shouldShowNotch = self.store.notchNotifyOnFullRestore
                    notchSoundEnabled = self.store.notchSoundOnFullRestore
                    notchSoundName = self.store.notchSoundNameFullRestore
                case .singleRestore:
                    shouldShowNotch = self.store.notchNotifyOnSingleRestore
                    notchSoundEnabled = self.store.notchSoundOnSingleRestore
                    notchSoundName = self.store.notchSoundNameSingleRestore
                case .displayChange:
                    shouldShowNotch = self.store.notchNotifyOnDisplayChange
                    notchSoundEnabled = self.store.notchSoundOnDisplayChange
                    notchSoundName = self.store.notchSoundNameDisplayChange
                case .snapshotUpdate:
                    shouldShowNotch = self.store.notchNotifyOnSnapshotUpdate
                    notchSoundEnabled = self.store.notchSoundOnSnapshotUpdate
                    notchSoundName = self.store.notchSoundNameSnapshotUpdate
                case .desktopToggle:
                    shouldShowNotch = self.store.notchNotifyOnDesktopToggle
                    notchSoundEnabled = self.store.notchSoundOnDesktopToggle
                    notchSoundName = self.store.notchSoundNameDesktopToggle
                case .permissionWarning:
                    shouldShowNotch = true
                    notchSoundEnabled = true
                    notchSoundName = "Hero"
                }

                if shouldShowNotch {
                    if let window = self.notchWindow, window.isVisible, window.isCompact == isCompact {
                        window.update(title: title, subtitle: subtitle, bundleID: bundleID, appIcon: appIcon)
                    } else {
                        self.notchWindow?.dismiss()
                        let window = NotchNotificationWindow(title: title, subtitle: subtitle, isCompact: isCompact, bundleID: bundleID, appIcon: appIcon)
                        self.notchWindow = window
                        window.show()
                    }

                    if notchSoundEnabled && !silent {
                        SystemSound.playSound(named: notchSoundName, volume: Float(self.store.notchSoundVolume))
                    }
                }
            }

            // 2. macOS System Notification (UNUserNotificationCenter)
            if self.store.showSystemNotification && !silent {
                var shouldSend = false
                var systemSoundEnabled = false
                var systemSoundName = self.store.defaultNotificationSound
                switch type {
                case .fullRestore:
                    shouldSend = self.store.systemNotifyOnFullRestore
                    systemSoundEnabled = self.store.systemSoundOnFullRestore
                    systemSoundName = self.store.systemSoundNameFullRestore
                case .singleRestore:
                    shouldSend = self.store.systemNotifyOnSingleRestore
                    systemSoundEnabled = self.store.systemSoundOnSingleRestore
                    systemSoundName = self.store.systemSoundNameSingleRestore
                case .displayChange:
                    shouldSend = self.store.systemNotifyOnDisplayChange
                    systemSoundEnabled = self.store.systemSoundOnDisplayChange
                    systemSoundName = self.store.systemSoundNameDisplayChange
                case .snapshotUpdate:
                    shouldSend = self.store.systemNotifyOnSnapshotUpdate
                    systemSoundEnabled = self.store.systemSoundOnSnapshotUpdate
                    systemSoundName = self.store.systemSoundNameSnapshotUpdate
                case .desktopToggle:
                    shouldSend = self.store.systemNotifyOnDesktopToggle
                    systemSoundEnabled = self.store.systemSoundOnDesktopToggle
                    systemSoundName = self.store.systemSoundNameDesktopToggle
                case .permissionWarning:
                    shouldSend = true
                    systemSoundEnabled = true
                    systemSoundName = "Hero"
                }

                if shouldSend {
                    // Resolve quick-key trigger suffix for OS notification title
                    let resolvedTrigger = triggerKey ?? ( (isCompact && (subtitle == "fn" || subtitle == "⇪⇪")) ? subtitle : nil )
                    let triggerSuffix: String
                    if let trig = resolvedTrigger, !trig.isEmpty {
                        if trig == "fn" {
                            triggerSuffix = " — via 🌐 Fn"
                        } else if trig == "⇪⇪" {
                            triggerSuffix = " — via ⇪⇪"
                        } else {
                            triggerSuffix = " — via \(trig)"
                        }
                    } else {
                        triggerSuffix = ""
                    }

                    let osTitle = "\(title)\(triggerSuffix)"
                    let osBody = (subtitle == "fn" || subtitle == "⇪" || subtitle == "⇪⇪") ? "" : subtitle

                    self.sendSystemNotification(title: osTitle, subtitle: osBody, playSound: systemSoundEnabled && !silent, soundName: systemSoundName)
                }
            }
        }
    }

    private func sendSystemNotification(title: String, subtitle: String, playSound: Bool = true, soundName: String = "Stargaze") {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty {
            content.body = subtitle
        }
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error = error {
                Task { @MainActor in
                    WindowManager.shared.log("Failed to deliver system notification: \(error.localizedDescription)", level: .verbose, type: .system)
                }
            }
        }

        if playSound {
            SystemSound.playSound(named: soundName, volume: Float(self.store.systemSoundVolume))
        }
    }

    func previewSound(named soundName: String, volume: Float? = nil) {
        let vol = volume ?? Float(self.store.notchSoundVolume)
        SystemSound.playSound(named: soundName, volume: vol)
    }

    func requestSystemNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                WindowManager.shared.log("macOS notification authorization: \(granted)", level: .moderate, type: .system)
            }
        }
    }

    // UNUserNotificationCenterDelegate
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    // MARK: - Capture

    private func captureAllWindows(for fp: ScreenFingerprint, silent: Bool = false) -> [WindowRecord] {
        var records: [WindowRecord] = []
        let screens = NSScreen.screens
        let primaryScreenHeight = screens.first?.frame.height ?? 0

        // Use .optionAll so we capture windows on ALL Spaces (including full-screen spaces).
        // .excludeDesktopElements removes dock, menu bar wallpaper panels, etc.
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        // Map of PID to NSRunningApplication for quick lookup.
        let runningApps = Dictionary(
            NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { _, new in new }
        )

        // Build the set of valid CG-coordinate screen rects (top-left origin) so we can
        // distinguish real AX positions from virtual-Space coordinates.
        let primaryH = screens.first?.frame.height ?? 0
        let screenCGRects: [CGRect] = screens.map { s in
            // Convert AppKit frame (bottom-left origin) → CG frame (top-left origin)
            CGRect(x: s.frame.minX, y: primaryH - s.frame.maxY, width: s.frame.width, height: s.frame.height)
        }

        // Build the set of current CG window geometries per PID for Zero-IPC idle optimization
        var cgWindowsByPID: [Int32: [CGWindowBriefInfo]] = [:]
        for entry in windowList {
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let app = runningApps[pid],
                  (app.activationPolicy == .regular || app.activationPolicy == .accessory) else { continue }

            guard let windowID = entry[kCGWindowNumber as String] as? UInt32,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let w = bounds["Width"] as? CGFloat,
                  let h = bounds["Height"] as? CGFloat,
                  let windowLayer = entry[kCGWindowLayer as String] as? Int,
                  windowLayer == 0 else { continue }

            guard w > 50, h > 50 else { continue }
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.01 else { continue }

            let frame = CGRect(x: x, y: y, width: w, height: h)
            cgWindowsByPID[pid, default: []].append(CGWindowBriefInfo(windowID: windowID, bounds: frame))
        }

        // Retrieve true window frames and full-screen status directly from the accessibility tree.
        // This is used to filter out system ghost windows and accurately identify full-screen windows.
        let axWindowsByPID = getValidAXWindows(runningApps: runningApps, screenCGRects: screenCGRects, cgWindowsByPID: cgWindowsByPID)

        struct RawEntry {
            let entry: [String: Any]
            let pid: Int32
            let isOnScreen: Bool
            let area: CGFloat
            let zOrder: Int        // position in CGWindowList (front = lower index)
            let isAXFullScreen: Bool
            let frame: CGRect
            let matchedAXFrameIndex: Int // index into axWindowsByPID[pid]; -1 if no AX data
        }

        var groupedEntries: [Int32: [RawEntry]] = [:]
        var ghostCountByApp:  [Int32: Int] = [:]
        var zOrder = 0

        for entry in windowList {
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let app = runningApps[pid],
                  (app.activationPolicy == .regular || app.activationPolicy == .accessory) else { zOrder += 1; continue }

            guard let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let w = bounds["Width"] as? CGFloat,
                  let h = bounds["Height"] as? CGFloat,
                  let windowLayer = entry[kCGWindowLayer as String] as? Int,
                  windowLayer == 0 else { zOrder += 1; continue }

            guard w > 50, h > 50 else { zOrder += 1; continue }

            // Filter out completely transparent ghost windows
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.01 else { zOrder += 1; continue }

            let isOnScreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? false
            let title = entry[kCGWindowName as String] as? String ?? ""
            let cgFrame = CGRect(x: x, y: y, width: w, height: h)
            var isAXFullScreen = false

            // --- Pre-filter obvious ghost windows ---
            // Only drop clearly-impossible sizes; real full-screen windows (even untitled) must survive.
            if !isOnScreen && title.isEmpty {
                if (w == 64 && h == 64) || (w == 500 && h == 500) || h < 70 {
                    zOrder += 1; continue
                }
            }

            // --- AX Frame Matching ---
            if let axWins = axWindowsByPID[pid] {
                var matchedIdx = -1

                for (i, aw) in axWins.enumerated() {
                    // x/w: 5px tolerance (CG and AX align closely for normal windows;
                    //   the old 10px was causing ghost windows like 1400x718 to match 1408x718)
                    // y/h: 35px tolerance (full-screen AX frames include the hidden menu bar, +~29px)
                    let xMatch = abs(aw.frame.origin.x - cgFrame.origin.x) < 5
                    let yMatch = abs(aw.frame.origin.y - cgFrame.origin.y) < 35
                    let wMatch = abs(aw.frame.width - cgFrame.width) < 5
                    let hMatch = abs(aw.frame.height - cgFrame.height) < 35

                    if xMatch && yMatch && wMatch && hMatch {
                        matchedIdx = i
                        isAXFullScreen = aw.isFullScreen
                        break
                    }
                }

                if matchedIdx == -1 {
                    // Window not in AX tree → ghost.
                    ghostCountByApp[pid, default: 0] += 1
                    zOrder += 1; continue
                }

                let raw = RawEntry(entry: entry, pid: pid, isOnScreen: isOnScreen,
                                   area: w * h, zOrder: zOrder, isAXFullScreen: isAXFullScreen,
                                   frame: cgFrame, matchedAXFrameIndex: matchedIdx)
                groupedEntries[pid, default: []].append(raw)
            } else {
                // No AX data — deduplication will handle this app.
                let raw = RawEntry(entry: entry, pid: pid, isOnScreen: isOnScreen,
                                   area: w * h, zOrder: zOrder, isAXFullScreen: false,
                                   frame: cgFrame, matchedAXFrameIndex: -1)
                groupedEntries[pid, default: []].append(raw)
            }
            zOrder += 1
        }

        // Log any apps where we silently dropped ghost windows
        for (pid, count) in ghostCountByApp {
            let name = runningApps[pid]?.localizedName ?? "pid\(pid)"
            _ = (count, name) // ghost drops are normal operation; only log if anomalously high
        }
        
        // --- Heuristic Deduplication for non-AX Apps ---
        var selectedEntries: [RawEntry] = []

        for (_, entries) in groupedEntries {
            let pid = entries.first!.pid

            if axWindowsByPID[pid] != nil {
                // AX data present. Each CGWindow was matched to a specific AX frame index.
                // Group by that index and keep only the OLDEST window per AX frame
                // (ghosts are always newer — higher kCGWindowNumber — than the real window).
                var bestPerAXFrame: [Int: RawEntry] = [:]
                for e in entries {
                    let idx = e.matchedAXFrameIndex
                    if let existing = bestPerAXFrame[idx] {
                        let existNum = existing.entry[kCGWindowNumber as String] as? Int ?? Int.max
                        let newNum   = e.entry[kCGWindowNumber as String] as? Int ?? Int.max
                        if newNum < existNum { bestPerAXFrame[idx] = e }
                    } else {
                        bestPerAXFrame[idx] = e
                    }
                }
                let kept = bestPerAXFrame.values.sorted { $0.zOrder < $1.zOrder }
                // Duplicate drops are normal ghost-filter operation — no log needed
                selectedEntries.append(contentsOf: kept)
                continue
            }

            let onScreen = entries.filter { $0.isOnScreen }

            if !onScreen.isEmpty {
                // App has on-screen windows — off-screen ones are macOS ghosts. Drop them silently.
                selectedEntries.append(contentsOf: onScreen)
            } else {
                let offScreen = entries.filter { !$0.isOnScreen }
                if offScreen.isEmpty { continue }

                if offScreen.count == 1 {
                    selectedEntries.append(offScreen[0])
                } else {
                    // Multiple off-screen windows — pick the oldest (real windows are created first).
                    let sorted = offScreen.sorted { a, b in
                        let numA = a.entry[kCGWindowNumber as String] as? Int ?? Int.max
                        let numB = b.entry[kCGWindowNumber as String] as? Int ?? Int.max
                        return numA < numB
                    }
                    let winner = sorted[0]
                    selectedEntries.append(winner)
                }
            }
        }
        
        // Sort selected entries back to original zOrder
        selectedEntries.sort { $0.zOrder < $1.zOrder }

        // ── Convert raw entries → WindowRecords ────────────────────────────────
        var appWindowCounts: [Int32: Int] = [:]
        var currentZIndex = 0

        for raw in selectedEntries {
            guard let app = runningApps[raw.pid],
                  let bounds = raw.entry[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let w = bounds["Width"] as? CGFloat,
                  let h = bounds["Height"] as? CGFloat else { continue }

            let appName  = app.localizedName ?? (raw.entry[kCGWindowOwnerName as String] as? String) ?? "Unknown"
            let bundleID = app.bundleIdentifier ?? appName
            let title    = raw.entry[kCGWindowName as String] as? String ?? ""

            // AppKit coords: (bottom-left origin)
            let appKitFrame = CGRect(x: x, y: primaryScreenHeight - y - h, width: w, height: h)

            // Find which screen this window primarily lives on
            let screen = screens.max(by: { s1, s2 in
                let area1 = s1.frame.intersection(appKitFrame).area
                let area2 = s2.frame.intersection(appKitFrame).area
                return area1 < area2
            })

            let index = appWindowCounts[raw.pid, default: 0]
            appWindowCounts[raw.pid] = index + 1

            let wid = WindowID(appBundleID: bundleID, appName: appName, windowTitle: title, appWindowIndex: index)
            let recordID = self.lastKnownWindows[wid]?.id ?? UUID()

            var record = WindowRecord(
                id: recordID,
                windowID: wid,
                globalFrame: appKitFrame,
                screenKey: fp.key,
                screenFrame: screen?.frame,
                screenName: screen?.localizedName ?? "Unknown Screen",
                savedAt: Date(),
                zIndex: currentZIndex
            )

            // Mark windows that are in native macOS full-screen mode.
            if raw.isAXFullScreen {
                record.isNativeFullScreen = true
                record.isFullScreenMode = true
            } else if let s = screen {
                let matchesFrame = abs(appKitFrame.width - s.frame.width) < 2 && abs(appKitFrame.height - s.frame.height) < 2

                if matchesFrame {
                    // Perfectly matches the full physical screen frame (e.g. YouTube PWA full-screen).
                    record.isFullScreenMode = true
                } else if !raw.isOnScreen {
                    // Check the native full-screen "parked" signature against every connected screen.
                    // When a full-screen app is in its own Space, its CG window sits at the screen's
                    // top-left corner (or 29px below for the primary display's menu bar).
                    // This works for both built-in (x=0, y≈29) and external monitors (x=-588, y≈-1440).
                    let isParkedFullScreen = screens.contains { sc in
                        let scCGMinX = sc.frame.minX
                        let scCGMinY = primaryScreenHeight - sc.frame.maxY
                        let xOK = abs(raw.frame.origin.x - scCGMinX) < 5
                        let wOK = abs(raw.frame.width - sc.frame.width) < 5
                        let yAtTop        = abs(raw.frame.origin.y - scCGMinY) < 10
                        let yBelowMenuBar = abs(raw.frame.origin.y - scCGMinY - 29) < 10
                        return xOK && wOK && (yAtTop || yBelowMenuBar)
                    }
                    if isParkedFullScreen {
                        record.isNativeFullScreen = true
                        record.isFullScreenMode = true
                    }
                }
            }

            records.append(record)
            currentZIndex += 1
        }

        if !silent {
            log("Scanned \(records.count) active windows via CGWindowList", level: .verbose)
        }
        return records
    }

    struct AXWindowInfo {
        let frame: CGRect
        let isFullScreen: Bool
    }

    struct CGWindowBriefInfo: Equatable {
        let windowID: UInt32
        let bounds: CGRect
    }

    /// Retrieves all valid window frames and their full-screen status directly from the Accessibility API.
    /// Results are cached per-PID. When AX returns empty or virtual-space coordinates (app not frontmost),
    /// the last known good cache is used instead to guarantee frame matching still works.
    private func getValidAXWindows(
        runningApps: [Int32: NSRunningApplication],
        screenCGRects: [CGRect],
        cgWindowsByPID: [Int32: [CGWindowBriefInfo]]
    ) -> [Int32: [AXWindowInfo]] {
        var result: [Int32: [AXWindowInfo]] = [:]
        
        // Prune cache for apps that are no longer running
        let activePIDs = Set(runningApps.keys)
        let stalePIDs = cachedAXWindowsByPID.keys.filter { !activePIDs.contains($0) }
        stalePIDs.forEach { cachedAXWindowsByPID.removeValue(forKey: $0) }
        let staleCGPIDs = lastCGWindowsByPID.keys.filter { !activePIDs.contains($0) }
        staleCGPIDs.forEach { lastCGWindowsByPID.removeValue(forKey: $0) }

        for (pid, app) in runningApps {
            guard app.activationPolicy == .regular || app.activationPolicy == .accessory else { continue }
            
            // Finder's AX tree only exposes the desktop background pseudo-window (e.g. 2560x2372),
            // not real folder windows. Including it would cause every Finder CGWindow to fail
            // frame-matching and be discarded as a ghost. Finder is handled by heuristic deduplication.
            if app.bundleIdentifier == "com.apple.finder" { continue }

            // Zero-IPC Idle Optimization: Skip AX query if the app has no active CG windows
            // or if window IDs and bounds have not changed since the last check.
            guard let currentCGWindows = cgWindowsByPID[pid], !currentCGWindows.isEmpty else {
                lastCGWindowsByPID.removeValue(forKey: pid)
                cachedAXWindowsByPID.removeValue(forKey: pid)
                continue
            }

            if let lastCGWindows = lastCGWindowsByPID[pid],
               lastCGWindows == currentCGWindows,
               let cachedAX = cachedAXWindowsByPID[pid] {
                // Geometry is completely identical. Safe to skip AX IPC queries and reuse cache!
                result[pid] = cachedAX
                continue
            }

            let axApp = WindowManager.createAXElement(for: pid)
            var windowsRef: CFTypeRef?
            var wins: [AXUIElement] = []
            
            // Try standard windows attribute
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let foundWins = windowsRef as? [AXUIElement] {
                wins = foundWins
            }
            
            // If empty, try children attribute (common fallback for non-standard apps)
            if wins.isEmpty {
                if AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &windowsRef) == .success,
                   let children = windowsRef as? [AXUIElement] {
                    wins = children.filter { child in
                        var roleRef: CFTypeRef?
                        if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
                           let role = roleRef as? String {
                            if role == kAXWindowRole { return true }
                            var subroleRef: CFTypeRef?
                            if AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subroleRef) == .success,
                               let subrole = subroleRef as? String {
                                return subrole == kAXStandardWindowSubrole ||
                                       subrole == kAXFloatingWindowSubrole ||
                                       subrole == kAXDialogSubrole
                            }
                        }
                        return false
                    }
                }
            }

            var axWins: [AXWindowInfo] = []
            for win in wins {
                AXUIElementSetMessagingTimeout(win, 0.15)
                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
                AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)
                
                var pos = CGPoint.zero
                var size = CGSize.zero
                if let posVal = posRef as! AXValue?, AXValueGetValue(posVal, .cgPoint, &pos) {}
                if let sizeVal = sizeRef as! AXValue?, AXValueGetValue(sizeVal, .cgSize, &size) {}
                
                var fsRef: CFTypeRef?
                var isFullScreen = false
                if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fsRef) == .success,
                   let fsVal = fsRef as? Bool {
                    isFullScreen = fsVal
                }
                
                // Only accept windows whose origin lands within a real connected screen (in CG coords).
                // When an app is not frontmost and in its own full-screen Space, AX reports the window
                // at the virtual Space position, which is far outside all physical screen bounds.
                // Example: Antigravity on Dell full-screen → AX reports (-588, -1440) when not frontmost,
                // but the Dell's CG rect is (-588, -508) to (1972, 932). The y=-1440 is out of all screens.
                let windowCGOrigin = CGPoint(x: pos.x, y: pos.y)
                let isOnAnyScreen = screenCGRects.contains { rect in
                    let expanded = rect.insetBy(dx: -50, dy: -50)
                    return expanded.contains(windowCGOrigin)
                }
                // Ignore tiny auxiliary windows (toolbars, panels < 50×50).
                // These match no CGWindow (which also has a >50×50 guard) and would pollute the cache,
                // causing real full-screen windows to fail frame-matching on the next capture cycle.
                let isSizeable = size.width > 50 && size.height > 50
                if isOnAnyScreen && isSizeable {
                    axWins.append(AXWindowInfo(frame: CGRect(origin: pos, size: size), isFullScreen: isFullScreen))
                }
            }
            
            if !axWins.isEmpty {
                // Fresh AX data from an on-screen position — update cache.
                let wasStale = cachedAXWindowsByPID[pid] == nil
                let appLabel = app.localizedName ?? "pid\(pid)"
                let fsSuffix = axWins.contains(where: { $0.isFullScreen }) ? " [fullscreen]" : ""
                if wasStale {
                    log("💾 AX cache POPULATED for \(appLabel): \(axWins.count) frame(s)\(fsSuffix)", level: .verbose, type: .system)
                }
                cachedAXWindowsByPID[pid] = axWins
                lastCGWindowsByPID[pid] = currentCGWindows
                result[pid] = axWins
            } else if let cached = cachedAXWindowsByPID[pid] {
                // AX returned nothing useful (app is backgrounded / in its own full-screen Space).
                // Use the last known good frames so ghost-window filtering still works correctly.
                lastCGWindowsByPID[pid] = currentCGWindows
                result[pid] = cached
            } else {
                // No fresh data and no cache — deduplication will handle it.
                // (Normal for apps that haven't been focused since launch.)
            }
        }
        return result
    }

    // MARK: - Permission Check & Auto-Recovery

    /// Starts continuous background permission tracking to handle login race conditions and macOS TCC initialization.
    func startPermissionMonitoring() {
        refreshAccessibilityPermissionStatus()

        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccessibilityPermissionStatus()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccessibilityPermissionStatus()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccessibilityPermissionStatus()
            }
        }
    }

    /// Re-evaluates AXIsProcessTrusted() and triggers auto-recovery when permissions become active.
    func refreshAccessibilityPermissionStatus() {
        let current = AXIsProcessTrusted()
        if current != hasAccessibilityPermission {
            hasAccessibilityPermission = current
            handlePermissionTransition(to: current)
        }
    }

    private func handlePermissionTransition(to granted: Bool) {
        if granted {
            log("Accessibility permission detected as ACTIVE. Initializing tracking, observers, and shortcuts.", level: .necessary, type: .system)
            if isTracking && !store.usePollingMode {
                startAXObservers()
            }
            scheduleAXEventFlush(delay: 0)
            DesktopToggleManager.shared.start()
            if store.quickKeyRestoreEnabled {
                QuickKeyRestoreManager.shared.setup()
            }
        } else {
            log("Accessibility permission is inactive or missing. Waiting for macOS TCC initialization...", level: .moderate, type: .system)
        }
    }

    /// Prompts the user to grant Accessibility permission (shows system dialog once).
    func requestAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        refreshAccessibilityPermissionStatus()
    }

    /// Manually re-checks permissions (e.g. from user UI interaction).
    func checkAccessibilityPermissionManually() {
        refreshAccessibilityPermissionStatus()
    }

    /// Explicitly opens the macOS System Settings Privacy & Security > Accessibility pane.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Toggles a bundle ID in the custom web apps set.
    func toggleCustomWebApp(bundleID: String) {
        if store.customWebAppBundleIDs.contains(bundleID) {
            store.customWebAppBundleIDs.remove(bundleID)
        } else {
            store.customWebAppBundleIDs.insert(bundleID)
        }
        persist()
    }

    /// Silently checks Finder Automation permission using AEDeterminePermissionToAutomateTarget.
    /// Never shows a dialog — reads TCC state only.
    var hasFinderAutomationPermission: Bool {
        guard let finder = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.finder")
                .first else { return false }
        var pid = finder.processIdentifier
        var target = AEAddressDesc()
        let createErr = AECreateDesc(typeKernelProcessID, &pid, MemoryLayout<pid_t>.size, &target)
        guard createErr == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
        return status == noErr
    }

    /// Triggers the macOS Automation permission dialog for Finder.
    /// Only call from a user-initiated action — this will show the system dialog.
    func requestFinderAutomationPermission() {
        guard let finder = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.finder")
                .first else {
            var error: NSDictionary?
            _ = NSAppleScript(source: "tell application \"Finder\" to get name")?.executeAndReturnError(&error)
            return
        }
        var pid = finder.processIdentifier
        var target = AEAddressDesc()
        let createErr = AECreateDesc(typeKernelProcessID, &pid, MemoryLayout<pid_t>.size, &target)
        guard createErr == noErr else { return }
        defer { AEDisposeDesc(&target) }
        
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
        if status == errAEEventNotPermitted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        } else {
            var error: NSDictionary?
            _ = NSAppleScript(source: "tell application \"Finder\" to get name")?.executeAndReturnError(&error)
        }
    }

    /// Restores a single app's windows on a background queue. Calls `completion` on the main thread when all windows are in place.
    func restoreSingleAppBackground(snapshot: LayoutSnapshot, bundleID: String, showNotification: Bool = true, completion: (() -> Void)? = nil) {
        let appRecords = snapshot.records.filter { $0.windowID.appBundleID == bundleID || $0.windowID.appName == bundleID }
        guard !appRecords.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard self.hasAccessibilityPermission else { return }

            let runningApps = NSWorkspace.shared.runningApplications
            guard let app = runningApps.first(where: { $0.bundleIdentifier == bundleID || $0.localizedName == bundleID }) else { return }

            let axApp = WindowManager.createAXElement(for: app.processIdentifier)
            var windowsRef: CFTypeRef?
            var wins: [AXUIElement] = []
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let foundWins = windowsRef as? [AXUIElement] {
                wins = foundWins
            }

            guard !wins.isEmpty else { return }

            let screens = NSScreen.screens
            let primaryScreenH = screens.first?.frame.height ?? 1080

            for (idx, win) in wins.enumerated() {
                let record = idx < appRecords.count ? appRecords[idx] : appRecords.first!
                let targetFrame = self.calculateTargetFrame(for: record)
                let axX = targetFrame.origin.x
                let axY = primaryScreenH - targetFrame.origin.y - targetFrame.height
                let axW = targetFrame.width
                let axH = targetFrame.height

                if record.isNativeFullScreen || record.isFullScreenMode {
                    var pos = CGPoint(x: axX, y: axY)
                    if let v = AXValueCreate(.cgPoint, &pos) {
                        _ = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
                    }
                    var sz = CGSize(width: axW, height: axH)
                    if let v = AXValueCreate(.cgSize, &sz) {
                        _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v)
                    }
                    if record.isNativeFullScreen {
                        _ = AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, kCFBooleanTrue)
                    }
                } else {
                    let currentFrame = self.getCurrentFrame(of: win)
                    let currentScreen: NSScreen?
                    if let cur = currentFrame {
                        let curMid = CGPoint(x: cur.midX, y: primaryScreenH - cur.midY)
                        currentScreen = screens.first { $0.frame.contains(curMid) } ?? screens.first
                    } else {
                        currentScreen = screens.first
                    }
                    
                    let targetMid = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
                    let targetScreen = screens.first { $0.frame.contains(targetMid) } ?? screens.first

                    let currentScreenArea = (currentScreen?.frame.width ?? 1920) * (currentScreen?.frame.height ?? 1080)
                    let targetScreenArea = (targetScreen?.frame.width ?? 1920) * (targetScreen?.frame.height ?? 1080)
                    let isMovingToSmallerScreen = targetScreen != currentScreen && targetScreenArea < currentScreenArea

                    var targetPos = CGPoint(x: axX, y: axY)
                    var targetSize = CGSize(width: axW, height: axH)

                    if isMovingToSmallerScreen {
                        // Pre-shrink so window can enter smaller target bounds freely
                        let maxAllowedW = min(axW, (targetScreen?.visibleFrame.width ?? axW))
                        let maxAllowedH = min(axH, (targetScreen?.visibleFrame.height ?? axH))
                        var preShrinkSize = CGSize(width: maxAllowedW, height: maxAllowedH)
                        if let v = AXValueCreate(.cgSize, &preShrinkSize) {
                            _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v)
                        }
                        if let v = AXValueCreate(.cgPoint, &targetPos) {
                            _ = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
                        }
                        if let v = AXValueCreate(.cgSize, &targetSize) {
                            _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v)
                        }
                    } else {
                        // Move to position first, then apply size
                        if let v = AXValueCreate(.cgPoint, &targetPos) {
                            _ = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
                        }
                        if let v = AXValueCreate(.cgSize, &targetSize) {
                            _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v)
                        }
                    }

                    // Settle & verification loop (up to 3 passes) to guarantee position + size
                    let axTargetFrame = CGRect(x: axX, y: axY, width: axW, height: axH)
                    for _ in 1...3 {
                        usleep(40_000) // 40ms settle
                        if let current = self.getCurrentFrame(of: win) {
                            if abs(current.origin.x - axTargetFrame.origin.x) <= 4 &&
                               abs(current.origin.y - axTargetFrame.origin.y) <= 4 &&
                               abs(current.size.width - axTargetFrame.size.width) <= 4 &&
                               abs(current.size.height - axTargetFrame.size.height) <= 4 {
                                break
                            }
                            if let v = AXValueCreate(.cgPoint, &targetPos) {
                                _ = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
                            }
                            if let v = AXValueCreate(.cgSize, &targetSize) {
                                _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v)
                            }
                        }
                    }
                }
            }

            if showNotification {
                let appName = appRecords.first?.windowID.appName ?? bundleID
                // Pre-fetch the icon on the background thread before menu modal loop can block AppKit lookups
                let prefetchedIcon: NSImage? = app.icon
                    ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
                self.deliverNotification(
                    type: .singleRestore,
                    title: "\(appName) \(lz("Restored"))",
                    subtitle: "",
                    isCompact: true,
                    bundleID: bundleID,
                    appIcon: prefetchedIcon
                )
            }

            if let completion = completion {
                DispatchQueue.main.async { completion() }
            }
        }
    }

    // MARK: - Restore

    private func restore(snapshot: LayoutSnapshot, animated: Bool, specificAppBundleID: String? = nil, isAppLaunch: Bool = false, showNotification: Bool = true, skipCommandSend: Bool = false, triggerSubtitle: String? = nil, completion: (@MainActor () -> Void)? = nil) {
        let fp = ScreenFingerprint.current()

        if !hasAccessibilityPermission {
            log("⚠️ Accessibility permission not active — grant it in System Settings › Privacy & Security › Accessibility / Device Control", level: .necessary)
            if specificAppBundleID == nil {
                statusMessage = "Accessibility permission required"
            }
            // Don't return — still attempt AppleScript fallback for each window
        }

        let primaryScreenH = NSScreen.screens.first?.frame.height ?? 0
        let ownProcessName = ProcessInfo.processInfo.processName  // e.g. "RememberMyWindows"

        let records: [WindowRecord]
        if let targetApp = specificAppBundleID {
            records = snapshot.records.filter { $0.windowID.appBundleID == targetApp || $0.windowID.appName == targetApp }
            if records.isEmpty { return }
            log("Starting auto-restoration for \(targetApp) (\(records.count) windows)", level: .necessary, type: .restore)
        } else {
            records = snapshot.records
            log("Starting restoration of \(records.count) windows for \(fp.readableName)", level: .necessary, type: .restore)
            statusMessage = "Restoring \(records.count) windows…"
        }

        MenuBarIconManager.shared.triggerActionState(minDuration: 0.6)


        Task {
            let runningApps = Dictionary(
                NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
                uniquingKeysWith: { _, new in new }
            )
            let fp = ScreenFingerprint.current()
            let liveRecords = self.captureAllWindows(for: fp, silent: true)

            // ---------- Pre-resolve AX window targets grouped by application ----------
            struct ResolvedTarget {
                let record: WindowRecord
                let element: AXUIElement
                let targetFrame: CGRect
            }
            var resolvedTargets: [ResolvedTarget] = []

            let externalRecords = records.filter { $0.windowID.appBundleID != Bundle.main.bundleIdentifier && $0.windowID.appBundleID != ownProcessName }
            let groupedRecords = Dictionary(grouping: externalRecords, by: { $0.windowID.appBundleID })

            // Optional: Launch closed apps sequentially if enabled for full restore
            if specificAppBundleID == nil && self.store.launchMissingAppsOnRestore {
                let missingBundleIDs = groupedRecords.keys.filter { bundleID in
                    !runningApps.values.contains { $0.bundleIdentifier == bundleID || $0.localizedName == bundleID }
                }

                if !missingBundleIDs.isEmpty {
                    self.log("🚀 Launching \(missingBundleIDs.count) closed application(s) for full restore...", level: .necessary, type: .restore)
                    for (index, bundleID) in missingBundleIDs.enumerated() {
                        let sampleName = groupedRecords[bundleID]?.first?.windowID.appName ?? bundleID
                        if showNotification {
                            self.deliverNotification(
                                type: .fullRestore,
                                title: "Opening \(sampleName)",
                                subtitle: "Launching app (\(index + 1)/\(missingBundleIDs.count))...",
                                isCompact: true,
                                bundleID: bundleID
                            )
                        }

                        let launched: Bool
                        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                            let configuration = NSWorkspace.OpenConfiguration()
                            configuration.activates = false
                            configuration.addsToRecentItems = false

                            var launchSuccess = false
                            let semaphore = DispatchSemaphore(value: 0)
                            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                                launchSuccess = (error == nil)
                                semaphore.signal()
                            }
                            _ = semaphore.wait(timeout: .now() + 4.0)
                            launched = launchSuccess
                        } else {
                            launched = NSWorkspace.shared.launchApplication(sampleName)
                        }

                        if launched {
                            self.log("✅ Successfully launched '\(sampleName)'", level: .moderate, type: .restore)
                            // Allow application window subsystem to initialize safely
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                        } else {
                            self.log("⚠️ Could not launch '\(sampleName)'", level: .moderate, type: .restore)
                        }
                    }
                }
            }

            // Refresh running applications map after launching missing apps
            let updatedRunningApps = Dictionary(
                NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
                uniquingKeysWith: { _, new in new }
            )

            for (bundleID, appRecords) in groupedRecords {
                // Skip if app is still not running
                guard let app = updatedRunningApps.values.first(where: { $0.bundleIdentifier == bundleID || $0.localizedName == bundleID }) else {
                    self.log("⏭️ Skipping '\(bundleID)' — app is not running", level: .verbose, type: .restore)
                    continue
                }

                // If all records for this app are already full-screen on the target screen, skip AX resolution & DO NOT activate/focus!
                let isAlreadyFullScreenOnTargetScreen = appRecords.allSatisfy { record in
                    guard record.isNativeFullScreen || record.isFullScreenMode else { return false }
                    guard let lr = liveRecords.first(where: {
                        $0.windowID.appBundleID == record.windowID.appBundleID &&
                        (record.windowID.windowTitle.isEmpty ? $0.windowID.appWindowIndex == record.windowID.appWindowIndex : $0.windowID.windowTitle == record.windowID.windowTitle)
                    }) else { return false }
                    guard lr.isNativeFullScreen || lr.isFullScreenMode else { return false }
                    let sameScreen = lr.screenName == record.screenName ||
                                     (lr.screenFrame != nil && record.screenFrame != nil &&
                                      abs(lr.screenFrame!.origin.x - record.screenFrame!.origin.x) < 5 &&
                                      abs(lr.screenFrame!.origin.y - record.screenFrame!.origin.y) < 5)
                    return sameScreen
                }

                if isAlreadyFullScreenOnTargetScreen {
                    self.log("ℹ️ Skipping AX resolution & activation for '\(bundleID)' — already full-screen on target display", level: .verbose, type: .restore)
                    continue
                }
                
                let pid = app.processIdentifier
                let appElement = AXUIElementCreateApplication(pid)
                
                // Fetch the live AX window list.
                // IMPORTANT: apps currently in full-screen on a different Mission Control Space
                // often return an EMPTY kAXWindowsAttribute until activated.
                // We must activate + retry (same logic as resolveAXWindow) to get their AX element.
                var windowListRef: CFTypeRef?
                var wins: [AXUIElement] = []
                if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowListRef) == .success,
                   let foundWins = windowListRef as? [AXUIElement] {
                    wins = foundWins
                }
                
                if wins.isEmpty {
                    // Activate the app and retry — necessary for full-screen Space occupants
                    app.activate()
                    for _ in 1...3 {
                        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowListRef) == .success,
                           let foundWins = windowListRef as? [AXUIElement], !foundWins.isEmpty {
                            wins = foundWins
                            break
                        }
                    }
                }
                
                if wins.isEmpty {
                    // Final fallback: kAXChildren (for non-standard apps like VLC)
                    if AXUIElementCopyAttributeValue(appElement, kAXChildrenAttribute as CFString, &windowListRef) == .success,
                       let children = windowListRef as? [AXUIElement] {
                        wins = children.filter { child in
                            var roleRef: CFTypeRef?
                            if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
                               let role = roleRef as? String {
                                if role == kAXWindowRole { return true }
                                var subroleRef: CFTypeRef?
                                if AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subroleRef) == .success,
                                   let subrole = subroleRef as? String {
                                    return subrole == kAXStandardWindowSubrole ||
                                           subrole == kAXFloatingWindowSubrole ||
                                           subrole == kAXDialogSubrole
                                }
                            }
                            return false
                        }
                    }
                }
                
                guard !wins.isEmpty else {
                    self.log("⏭️ Skipping '\(bundleID)' — no AX windows found after retries", level: .verbose, type: .restore)
                    continue
                }
                
                var unclaimed = wins
                var matchedTargetsForApp: [ResolvedTarget] = []
                
                func getTitle(of el: AXUIElement) -> String {
                    var tv: CFTypeRef?
                    if AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &tv) == .success,
                       let t = tv as? String {
                        return t
                    }
                    return ""
                }
                
                // Pass 1: Exact title match
                for rec in appRecords {
                    guard !rec.windowID.windowTitle.isEmpty else { continue }
                    if let idx = unclaimed.firstIndex(where: { getTitle(of: $0) == rec.windowID.windowTitle }) {
                        let element = unclaimed.remove(at: idx)
                        let target = self.calculateTargetFrame(for: rec)
                        matchedTargetsForApp.append(ResolvedTarget(record: rec, element: element, targetFrame: target))
                    }
                }
                
                // Pass 2: Fuzzy title match
                for rec in appRecords {
                    if matchedTargetsForApp.contains(where: { $0.record.id == rec.id }) { continue }
                    guard !rec.windowID.windowTitle.isEmpty else { continue }
                    
                    let targetTitle = rec.windowID.windowTitle
                    if let idx = unclaimed.firstIndex(where: {
                        let t = getTitle(of: $0)
                        return t.contains(targetTitle) || targetTitle.contains(t)
                    }) {
                        let element = unclaimed.remove(at: idx)
                        let target = self.calculateTargetFrame(for: rec)
                        matchedTargetsForApp.append(ResolvedTarget(record: rec, element: element, targetFrame: target))
                    }
                }
                
                // Pass 3: Match remaining windows using size and aspect ratio similarity (extremely robust for apps like VLC with multi-window layouts)
                let unmatchedRecords = appRecords.filter { rec in
                    !matchedTargetsForApp.contains(where: { $0.record.id == rec.id })
                }
                
                for rec in unmatchedRecords {
                    let targetSize = rec.globalFrame.size
                    let targetAspect = targetSize.width / max(targetSize.height, 1)
                    
                    var bestIdx = -1
                    var bestDiff = CGFloat.infinity
                    
                    for (idx, el) in unclaimed.enumerated() {
                        guard let frame = self.getCurrentFrame(of: el) else { continue }
                        let elAspect = frame.width / max(frame.height, 1)
                        
                        let aspectDiff = abs(elAspect - targetAspect)
                        
                        let targetArea = targetSize.width * targetSize.height
                        let elArea = frame.width * frame.height
                        let areaDiff = abs(elArea - targetArea) / max(targetArea, 1)
                        
                        let score = aspectDiff * 2.0 + areaDiff
                        if score < bestDiff {
                            bestDiff = score
                            bestIdx = idx
                        }
                    }
                    
                    if bestIdx != -1 {
                        let element = unclaimed.remove(at: bestIdx)
                        let target = self.calculateTargetFrame(for: rec)
                        matchedTargetsForApp.append(ResolvedTarget(record: rec, element: element, targetFrame: target))
                    }
                }
                
                // Pass 4: Fallback index match for any remaining unmatched records
                let remainingRecords = appRecords.filter { rec in
                    !matchedTargetsForApp.contains(where: { $0.record.id == rec.id })
                }
                let sortedRemaining = remainingRecords.sorted(by: { $0.windowID.appWindowIndex < $1.windowID.appWindowIndex })
                for rec in sortedRemaining {
                    let element: AXUIElement
                    if !unclaimed.isEmpty {
                        element = unclaimed.removeFirst()
                    } else if let first = wins.first {
                        element = first
                    } else {
                        continue
                    }
                    let target = self.calculateTargetFrame(for: rec)
                    matchedTargetsForApp.append(ResolvedTarget(record: rec, element: element, targetFrame: target))
                }
                
                // Broadcast mode: if there are extra open AX windows that weren't claimed by saved records,
                // apply the template target frame (e.g. from appRecords.first) to every extra window.
                // This stacks all open windows at the saved position so the user can drag them apart.
                if let templateRecord = appRecords.first {
                    let target = self.calculateTargetFrame(for: templateRecord)
                    for extraWin in unclaimed {
                        matchedTargetsForApp.append(ResolvedTarget(record: templateRecord, element: extraWin, targetFrame: target))
                    }
                    unclaimed.removeAll()
                }

                resolvedTargets.append(contentsOf: matchedTargetsForApp)
            }

            // Pre-check if single-app windows were already in place before restoration
            let wasAlreadyInPlace: Bool = {
                guard specificAppBundleID != nil, !records.isEmpty else { return false }
                for record in records {
                    let appLive = liveRecords.filter { $0.windowID.appBundleID == record.windowID.appBundleID }
                    guard !appLive.isEmpty else { return false }
                    
                    let matchingLR: WindowRecord?
                    if !record.windowID.windowTitle.isEmpty,
                       let match = appLive.first(where: { $0.windowID.windowTitle == record.windowID.windowTitle }) {
                        matchingLR = match
                    } else if let match = appLive.first(where: { $0.windowID.appWindowIndex == record.windowID.appWindowIndex }) {
                        matchingLR = match
                    } else if appLive.count == 1 {
                        matchingLR = appLive.first
                    } else {
                        return false
                    }
                    
                    guard let lr = matchingLR else { return false }
                    
                    let wantsFS = record.isNativeFullScreen || record.isFullScreenMode
                    let liveFS = lr.isNativeFullScreen || lr.isFullScreenMode
                    if wantsFS != liveFS {
                        return false
                    }
                    
                    if wantsFS {
                        // Both are full screen: verify monitor match
                        let sameScreen = lr.screenName == record.screenName ||
                            (lr.screenFrame != nil && record.screenFrame != nil &&
                             abs(lr.screenFrame!.origin.x - record.screenFrame!.origin.x) < 5 &&
                             abs(lr.screenFrame!.origin.y - record.screenFrame!.origin.y) < 5)
                        if !sameScreen { return false }
                    } else {
                        // Both are normal windows: verify coordinate match
                        let target = self.calculateTargetFrame(for: record)
                        let tol: CGFloat = 2.0
                        let close = abs(lr.globalFrame.origin.x - target.origin.x) <= tol &&
                                    abs(lr.globalFrame.origin.y - target.origin.y) <= tol &&
                                    abs(lr.globalFrame.width - target.width) <= tol &&
                                    abs(lr.globalFrame.height - target.height) <= tol
                        if !close { return false }
                    }
                }
                return true
            }()

            // ---------- Sequential Restoration ----------
            var restoredCount = 0
            var didModifyAnyWindow = false

            // 1. Restore our own windows (RememberMyWindows)
            let ownRecords = records.filter { $0.windowID.appBundleID == Bundle.main.bundleIdentifier || $0.windowID.appBundleID == ownProcessName }
            for record in ownRecords {
                let target = self.calculateTargetFrame(for: record)
                let success = await MainActor.run { [weak self] in
                    if let win = NSApplication.shared.windows.first(where: { $0.title == record.windowID.windowTitle }) {
                        if abs(win.frame.origin.x - target.origin.x) > 2 ||
                           abs(win.frame.origin.y - target.origin.y) > 2 ||
                           abs(win.frame.width - target.width) > 2 ||
                           abs(win.frame.height - target.height) > 2 {
                            didModifyAnyWindow = true
                            if animated {
                                win.animator().setFrame(target, display: true)
                            } else {
                                win.setFrame(target, display: true)
                            }
                        }
                        self?.log("✅ Own window '\(record.windowID.windowTitle)' restored", level: .verbose)
                        return true
                    }
                    return false
                }
                if success {
                    restoredCount += 1
                }
            }

            // 2. Restore all resolved external window targets (every window of every app)
            for targetItem in resolvedTargets {
                let record = targetItem.record
                let appName = record.windowID.appBundleID
                let target = targetItem.targetFrame

                // Skip if app is not running
                if !updatedRunningApps.values.contains(where: { $0.bundleIdentifier == appName || $0.localizedName == appName }) {
                    continue
                }

                // Skip if app is already full-screen on the correct screen in the live layout
                if (record.isNativeFullScreen || record.isFullScreenMode) {
                    let liveRecord = liveRecords.first { lr in
                        lr.windowID.appBundleID == record.windowID.appBundleID &&
                        (record.windowID.windowTitle.isEmpty ? lr.windowID.appWindowIndex == record.windowID.appWindowIndex : lr.windowID.windowTitle == record.windowID.windowTitle)
                    }
                    if let liveRecord = liveRecord, liveRecord.isNativeFullScreen || liveRecord.isFullScreenMode {
                        let sameScreen = liveRecord.screenName == record.screenName ||
                                         (liveRecord.screenFrame != nil && record.screenFrame != nil &&
                                          abs(liveRecord.screenFrame!.origin.x - record.screenFrame!.origin.x) < 5 &&
                                          abs(liveRecord.screenFrame!.origin.y - record.screenFrame!.origin.y) < 5)
                        if sameScreen {
                            self.log("ℹ️ Skipping '\(appName)' — already full-screen on target display", level: .verbose, type: .restore)
                            continue
                        }
                    }
                }

                self.log("→ Restoring '\(appName)' window", level: .verbose)
                
                var success = false
                var windowModified = false
                
                let liveRecord = liveRecords.first { lr in
                    lr.windowID.appBundleID == record.windowID.appBundleID &&
                    (record.windowID.windowTitle.isEmpty ? lr.windowID.appWindowIndex == record.windowID.appWindowIndex : lr.windowID.windowTitle == record.windowID.windowTitle)
                }
                let res = await self.restoreViaAX(
                    win: targetItem.element,
                    record: record,
                    targetFrame: target,
                    primaryScreenH: primaryScreenH,
                    liveRecord: liveRecord,
                    animated: animated
                )
                success = res.success
                windowModified = res.didModify
                
                if !success {
                    self.log("⚠️ AX failed or unavailable for '\(appName)', trying AppleScript...", level: .verbose, type: .system)
                    success = await self.restoreViaOsascript(record: record, targetFrame: target, primaryScreenH: primaryScreenH)
                    windowModified = true
                }

                if windowModified {
                    didModifyAnyWindow = true
                }

                if success {
                    restoredCount += 1
                    if record.isNativeFullScreen {
                        // Allow macOS Space transition to settle before restoring subsequent windows
                        try? await Task.sleep(nanoseconds: 800_000_000) // 800ms
                    }
                }
            }

            // Build status-aware detail lines: ✓ = app was running, ✗ = app was not running (skipped)
            let details: [String] = records.map { record in
                let isRunning = updatedRunningApps.values.contains(where: {
                    $0.bundleIdentifier == record.windowID.appBundleID ||
                    $0.localizedName == record.windowID.appBundleID
                })
                let marker = isRunning ? "✓ " : "✗ "
                return marker + self.formatWindowDetail(record: record)
            }

            let isLocked = self.isScreenLocked
            if isLocked && specificAppBundleID == nil {
                self.pendingUnlockAction = PendingUnlockRestoreAction(
                    snapshot: snapshot,
                    restoredCount: restoredCount,
                    totalCount: snapshot.records.count,
                    connectedDisplayNames: Array(self.pendingConnectedNames),
                    shouldSendShortcut: self.store.refreshFrontmostOnFullRestore
                )
                self.log("🔒 Layout restore completed while locked. Deferred notch overlay and shortcut queued for screen unlock.", level: .necessary, type: .restore)
            }

            if specificAppBundleID == nil {
                // Finally, bring the user's preferred foreground app to the absolute front (if set and screen is unlocked)
                if !isLocked, let targetBundleID = snapshot.foregroundBundleID {
                    self.bringAppToFront(bundleID: targetBundleID)
                }

                self.log("Restoring layout for \(fp.readableName)", level: .necessary, type: .restore, details: details)
                self.statusMessage = "Restore complete"
                
                if !isLocked && self.store.refreshFrontmostOnFullRestore {
                    await self.sendCommandToFrontmostAppAsync(targetBundleID: snapshot.foregroundBundleID, snapshot: snapshot)
                }

                if showNotification {
                    self.deliverNotification(
                        type: .fullRestore,
                        title: "Layout Restored",
                        subtitle: "\(snapshot.name) · \(restoredCount)/\(snapshot.records.count) \(lz("windows"))",
                        triggerKey: triggerSubtitle
                    )
                }

                // Fire completion handler on MainActor immediately so UI is responsive
                if let completion = completion {
                    await MainActor.run {
                        completion()
                    }
                }

                // ---------- Per-App WindowServer Verification (Background) ----------
                // The live layout is built from CGWindowList, so it is the source of truth for the
                // frames that macOS has actually committed. Run verification and minor nudge corrections
                // quietly in the background so full restore never hangs waiting on Space transitions.
                Task {
                    self.log("🔎 Verifying each restored app against the live WindowServer layout...", level: .verbose, type: .restore)
                    func isFrameClose(to target: CGRect, current: CGRect, tolerance: CGFloat = 15.0) -> Bool {
                        abs(current.origin.x - target.origin.x) <= tolerance &&
                        abs(current.origin.y - target.origin.y) <= tolerance &&
                        abs(current.size.width - target.size.width) <= tolerance &&
                        abs(current.size.height - target.size.height) <= tolerance
                    }

                    func takeMatchingLiveRecord(
                        for record: WindowRecord,
                        from availableRecords: inout [WindowRecord]
                    ) -> WindowRecord? {
                        if !record.windowID.windowTitle.isEmpty,
                           let titleAndIndex = availableRecords.firstIndex(where: {
                               $0.windowID.windowTitle == record.windowID.windowTitle &&
                               $0.windowID.appWindowIndex == record.windowID.appWindowIndex
                           }) {
                            return availableRecords.remove(at: titleAndIndex)
                        }

                        if !record.windowID.windowTitle.isEmpty,
                           let titleMatch = availableRecords.firstIndex(where: {
                               $0.windowID.windowTitle == record.windowID.windowTitle
                           }) {
                            return availableRecords.remove(at: titleMatch)
                        }

                        if let indexMatch = availableRecords.firstIndex(where: {
                            $0.windowID.appWindowIndex == record.windowID.appWindowIndex
                        }) {
                            return availableRecords.remove(at: indexMatch)
                        }

                        return nil
                    }

                    func mismatchedRecords(
                        for appRecords: [WindowRecord],
                        in liveLayout: [WindowRecord],
                        targetFramesByRecordID: [UUID: CGRect]
                    ) -> [WindowRecord] {
                        guard let appID = appRecords.first?.windowID.appBundleID else { return [] }
                        var availableLiveRecords = liveLayout.filter {
                            $0.windowID.appBundleID == appID
                        }
                        var mismatches: [WindowRecord] = []

                        for record in appRecords {
                            guard let liveRecord = takeMatchingLiveRecord(
                                for: record,
                                from: &availableLiveRecords
                            ) else {
                                mismatches.append(record)
                                continue
                            }

                            guard let targetFrame = targetFramesByRecordID[record.id] else {
                                mismatches.append(record)
                                continue
                            }
                            if !isFrameClose(to: targetFrame, current: liveRecord.globalFrame) {
                                mismatches.append(record)
                            }
                        }

                        return mismatches
                    }

                    let verificationRecords = records.filter { record in
                        record.windowID.appBundleID != Bundle.main.bundleIdentifier &&
                        record.windowID.appBundleID != ownProcessName &&
                        !record.isNativeFullScreen &&
                        !record.isFullScreenMode &&
                        updatedRunningApps.values.contains(where: {
                            $0.bundleIdentifier == record.windowID.appBundleID ||
                            $0.localizedName == record.windowID.appBundleID
                        })
                    }
                    var targetFramesByRecordID: [UUID: CGRect] = [:]
                    for record in verificationRecords {
                        targetFramesByRecordID[record.id] = self.calculateTargetFrame(for: record)
                    }
                    var verificationAppIDs: [String] = []
                    var seenVerificationAppIDs = Set<String>()
                    for record in verificationRecords where seenVerificationAppIDs.insert(record.windowID.appBundleID).inserted {
                        verificationAppIDs.append(record.windowID.appBundleID)
                    }

                    // Give WindowServer one quiet settling interval before the first check
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    let verificationDeadline = Date().addingTimeInterval(4)
                    var verificationAttempt = 0
                    var mismatchesByApp: [String: [WindowRecord]] = [:]

                    while true {
                        verificationAttempt += 1
                        let liveLayout = self.captureAllWindows(for: ScreenFingerprint.current(), silent: true)
                        mismatchesByApp = [:]
                        for appID in verificationAppIDs {
                            let appRecords = verificationRecords.filter {
                                $0.windowID.appBundleID == appID
                            }
                            guard !appRecords.isEmpty else { continue }
                            let appMismatches = mismatchedRecords(
                                for: appRecords,
                                in: liveLayout,
                                targetFramesByRecordID: targetFramesByRecordID
                            )
                            if !appMismatches.isEmpty {
                                mismatchesByApp[appID] = appMismatches
                            }
                        }

                        if mismatchesByApp.isEmpty {
                            self.log("✅ All apps verified by WindowServer after \(verificationAttempt) attempt(s).", level: .verbose, type: .restore)
                            break
                        }

                        if Date() >= verificationDeadline {
                            self.log("⚠️ Verification deadline reached with \(mismatchesByApp.count) app(s) still mismatched.", level: .moderate, type: .restore)
                            break
                        }

                        let correctionTargets = verificationAppIDs.flatMap { appID in
                            resolvedTargets.filter { $0.record.windowID.appBundleID == appID }
                        }

                        self.log("🔧 Correction pass \(verificationAttempt): re-applying frame to \(correctionTargets.count) window(s)...", level: .verbose, type: .restore)
                        for target in correctionTargets {
                            let targetFrame = target.targetFrame
                            let axY = primaryScreenH - targetFrame.origin.y - targetFrame.height
                            var position = CGPoint(x: targetFrame.origin.x, y: axY)
                            var size = targetFrame.size
                            if let value = AXValueCreate(.cgPoint, &position) {
                                _ = AXUIElementSetAttributeValue(target.element, kAXPositionAttribute as CFString, value)
                            }
                            if let value = AXValueCreate(.cgSize, &size) {
                                _ = AXUIElementSetAttributeValue(target.element, kAXSizeAttribute as CFString, value)
                            }
                        }

                        try? await Task.sleep(nanoseconds: 150_000_000)
                    }

                    for appID in verificationAppIDs {
                        if mismatchesByApp[appID] != nil {
                            self.log("⚠️ \(appID) could not be fully verified by WindowServer.", level: .moderate, type: .restore)
                        } else {
                            self.log("✅ \(appID) verified by WindowServer.", level: .verbose, type: .restore)
                        }
                    }
                }
            } else {
                // ---------- Single-App Restore Path ----------
                var singleRestoreVerified: Bool? = nil
                var singleRestoreUnverifiedCount = 0
                let targetTargets = resolvedTargets.filter {
                    !$0.record.isNativeFullScreen && !$0.record.isFullScreenMode
                }
                let nonVerifiableRecordCount = resolvedTargets.count - targetTargets.count

                func isTargetInPlace(_ target: ResolvedTarget) -> Bool {
                    guard let current = self.getCurrentFrame(of: target.element) else { return false }
                    let axX = target.targetFrame.origin.x
                    let axY = primaryScreenH - target.targetFrame.origin.y - target.targetFrame.height
                    let axTargetFrame = CGRect(x: axX, y: axY, width: target.targetFrame.width, height: target.targetFrame.height)
                    let tolerance: CGFloat = 3.0
                    return abs(current.origin.x - axTargetFrame.origin.x) <= tolerance &&
                           abs(current.origin.y - axTargetFrame.origin.y) <= tolerance &&
                           abs(current.width - axTargetFrame.width) <= tolerance &&
                           abs(current.height - axTargetFrame.height) <= tolerance
                }

                let verificationDeadline = Date().addingTimeInterval(3)
                var verificationAttempt = 0

                while Date() < verificationDeadline && verificationAttempt < 15 {
                    verificationAttempt += 1
                    try? await Task.sleep(nanoseconds: 80_000_000) // 80ms

                    let mismatchedTargets = targetTargets.filter { !isTargetInPlace($0) }

                    if mismatchedTargets.isEmpty && nonVerifiableRecordCount == 0 {
                        singleRestoreVerified = true
                        self.log(
                            "✅ Single-app restore verified by WindowServer after \(verificationAttempt) attempt(s).",
                            level: .verbose,
                            type: .restore
                        )
                        break
                    }

                    if mismatchedTargets.isEmpty {
                        singleRestoreUnverifiedCount = nonVerifiableRecordCount
                        break
                    }

                    singleRestoreUnverifiedCount = mismatchedTargets.count + nonVerifiableRecordCount
                    self.log(
                        "⚠️ WindowServer single-app check \(verificationAttempt): \(singleRestoreUnverifiedCount) window(s) not yet confirmed.",
                        level: .verbose,
                        type: .restore
                    )

                    for targetItem in mismatchedTargets {
                        let targetFrame = targetItem.targetFrame
                        let liveRecord = liveRecords.first {
                            $0.windowID.appBundleID == targetItem.record.windowID.appBundleID &&
                            $0.windowID.appWindowIndex == targetItem.record.windowID.appWindowIndex
                        }
                        _ = await self.restoreViaAX(
                            win: targetItem.element,
                            record: targetItem.record,
                            targetFrame: targetFrame,
                            primaryScreenH: primaryScreenH,
                            liveRecord: liveRecord,
                            animated: false
                        )
                    }
                }

                if singleRestoreVerified != true {
                    singleRestoreVerified = false
                    self.log(
                        "⚠️ Single-app restore could not be fully verified by WindowServer (\(singleRestoreUnverifiedCount) window(s)).",
                        level: .moderate,
                        type: .restore
                    )
                }

                self.log("Restored \(resolvedTargets.count) window(s) for \(specificAppBundleID!)", level: .necessary, type: .restore, details: details)
                if singleRestoreVerified == false {
                    self.statusMessage = lz("Restore needs attention")
                }
                
                if !isLocked && self.store.refreshFrontmostOnSingleRestore && !skipCommandSend {
                    var delay = isAppLaunch ? self.store.singleAppCommandDelay : 0.05
                    if isAppLaunch {
                        let runningApps = NSWorkspace.shared.runningApplications
                        let targetApp = runningApps.first(where: { $0.bundleIdentifier == specificAppBundleID || $0.localizedName == specificAppBundleID })
                        let isWeb = WebAppDetector.shared.isWebApp(
                            bundleID: specificAppBundleID,
                            appURL: targetApp?.bundleURL,
                            processIdentifier: targetApp?.processIdentifier,
                            customIDs: self.store.customWebAppBundleIDs
                        )
                        if isWeb {
                            let extra = self.store.webAppLaunchCommandDelay
                            delay += extra
                            self.log("🌐 Detected web app '\(targetApp?.localizedName ?? specificAppBundleID!)' — adding +\(String(format: "%.1f", extra))s delay (total \(String(format: "%.1f", delay))s) before ⌘⇧R", level: .necessary, type: .restore)
                        }
                    }
                    await self.sendCommandToFrontmostAppAsync(targetBundleID: specificAppBundleID, snapshot: snapshot, delayOverride: delay)
                }

                if showNotification {
                    let appName = records.first?.windowID.appName ?? specificAppBundleID ?? "App"
                    let isQuiet = wasAlreadyInPlace && !didModifyAnyWindow && self.store.quietSingleRestoreWhenInPlace
                    let notifTitle = isQuiet ? lz("Already In Place") : "\(appName) \(lz("Restored"))"
                    // For the quiet "already in place" compact notch, only pass the raw trigger key
                    // (e.g. "⇪⇪" or "fn") as the subtitle — never append the app name, because
                    // the compact pill badge has no room and the icon already identifies the app.
                    let notifSubtitle = isQuiet ? (triggerSubtitle ?? "") : (triggerSubtitle ?? "")

                    self.deliverNotification(
                        type: .singleRestore,
                        title: notifTitle,
                        subtitle: notifSubtitle,
                        isCompact: true,
                        bundleID: specificAppBundleID,
                        triggerKey: triggerSubtitle,
                        silent: isQuiet
                    )
                    // Brief pause so the icon drop animation is visible before the menu opens
                    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                }

                if let completion = completion {
                    await MainActor.run {
                        completion()
                    }
                }
            }
        }
    }

    // MARK: - AX restore (must be called from @MainActor context)

    private func resolveAXWindow(for record: WindowRecord, runningApps: [NSRunningApplication]) async -> AXUIElement? {
        let appName = record.windowID.appBundleID
        guard let app = runningApps.first(where: { $0.bundleIdentifier == appName || $0.localizedName == appName }) else {
            return nil
        }
        
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        var wins: [AXUIElement] = []
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let foundWins = windowsRef as? [AXUIElement] {
            wins = foundWins
        }
        
        if wins.isEmpty {
            // Try to activate the app (sometimes required for AX to work reliably / report windows)
            app.activate()
            // Retry a few times with a small delay, as some apps take a moment to report windows after activation
            for _ in 1...3 {
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                   let foundWins = windowsRef as? [AXUIElement], !foundWins.isEmpty {
                    wins = foundWins
                    break
                }
            }
        }
        
        if wins.isEmpty {
            if AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &windowsRef) == .success,
               let children = windowsRef as? [AXUIElement] {
                wins = children.filter { child in
                    var roleRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
                       let role = roleRef as? String {
                        if role == kAXWindowRole { return true }
                        
                        // Check subroles for non-standard windows (common in media players)
                        var subroleRef: CFTypeRef?
                        if AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subroleRef) == .success,
                           let subrole = subroleRef as? String {
                            return subrole == kAXStandardWindowSubrole || 
                                   subrole == kAXFloatingWindowSubrole || 
                                   subrole == kAXDialogSubrole
                        }
                    }
                    return false
                }
            }
        }
        
        guard !wins.isEmpty else { return nil }

        // Match by title first; if title changed or not found, fall back to window index or first window
        if !record.windowID.windowTitle.isEmpty {
            return wins.first { w in
                var tv: CFTypeRef?
                guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &tv) == .success,
                      let t = tv as? String else { return false }
                return t == record.windowID.windowTitle
            } ?? wins.first { w in
                var tv: CFTypeRef?
                guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &tv) == .success,
                      let t = tv as? String else { return false }
                return t.contains(record.windowID.windowTitle) || record.windowID.windowTitle.contains(t)
            } ?? (record.windowID.appWindowIndex < wins.count ? wins[record.windowID.appWindowIndex] : wins.first)
        } else {
            let idx = record.windowID.appWindowIndex
            return idx < wins.count ? wins[idx] : wins.first
        }
    }

    nonisolated private func getCurrentFrame(of element: AXUIElement) -> CGRect? {
        var positionValueRef: AnyObject?
        var sizeValueRef: AnyObject?
        var position = CGPoint.zero
        var size = CGSize.zero
        
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValueRef) == .success,
              let positionValue = positionValueRef,
              AXValueGetValue((positionValue as! AXValue), .cgPoint, &position) else {
            return nil
        }
        
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValueRef) == .success,
              let sizeValue = sizeValueRef,
              AXValueGetValue((sizeValue as! AXValue), .cgSize, &size) else {
            return nil
        }
        
        return CGRect(origin: position, size: size)
    }

    private func restoreViaAX(
        win: AXUIElement,
        record: WindowRecord,
        targetFrame: CGRect,
        primaryScreenH: CGFloat,
        liveRecord: WindowRecord?,
        animated: Bool = true
    ) async -> (success: Bool, didModify: Bool) {
        let appName = record.windowID.appBundleID

        // CG/AX coords: origin = top-left of primary screen
        let axX = targetFrame.origin.x
        let axY = primaryScreenH - targetFrame.origin.y - targetFrame.height  // AppKit → CG Y flip
        let axW = targetFrame.width
        let axH = targetFrame.height

        func isFrameClose(to target: CGRect, current: CGRect, tolerance: CGFloat = 2.0) -> Bool {
            abs(current.origin.x - target.origin.x) <= tolerance &&
            abs(current.origin.y - target.origin.y) <= tolerance &&
            abs(current.size.width - target.size.width) <= tolerance &&
            abs(current.size.height - target.size.height) <= tolerance
        }

        guard hasAccessibilityPermission else {
            log("AX ❌ no permission for '\(appName)' — will fall back to osascript", level: .verbose)
            return (success: false, didModify: false)
        }

        var isAlreadyFullScreen = false
        var fsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fsRef) == .success,
           let fsVal = fsRef as? Bool {
            isAlreadyFullScreen = fsVal
        }

        var didModify = false

        let wantsFullScreen = record.isNativeFullScreen || record.isFullScreenMode
        let isLiveFS = (liveRecord?.isNativeFullScreen ?? false) || (liveRecord?.isFullScreenMode ?? false)
        let currentlyFullScreen = isAlreadyFullScreen || isLiveFS

        // Determine if we need to change screens for a full-screen window
        var needsScreenChangeForFullScreen = false
        if wantsFullScreen && currentlyFullScreen {
            if let liveScreen = liveRecord?.screenName, let targetScreenName = record.screenName {
                if liveScreen != targetScreenName {
                    needsScreenChangeForFullScreen = true
                }
            } else {
                // Fallback to coordinate check if screenName info isn't available
                var positionValueRef: AnyObject?
                var position = CGPoint.zero
                if AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &positionValueRef) == .success,
                   let positionValue = positionValueRef {
                    AXValueGetValue((positionValue as! AXValue), .cgPoint, &position)
                }
                
                let screens = NSScreen.screens
                let primaryScreen = screens.first
                let primaryHeight = primaryScreen?.frame.height ?? 0
                
                func axFrame(for screen: NSScreen) -> CGRect {
                    return CGRect(
                        x: screen.frame.origin.x,
                        y: primaryHeight - screen.frame.origin.y - screen.frame.size.height,
                        width: screen.frame.size.width,
                        height: screen.frame.size.height
                    )
                }
                
                let currentScreen = screens.first { screen in
                    axFrame(for: screen).contains(position)
                } ?? screens.first
                
                let targetMidPoint = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
                let targetScreen = screens.first { $0.frame.contains(targetMidPoint) } ?? screens.first
                
                if currentScreen != targetScreen {
                    needsScreenChangeForFullScreen = true
                }
            }
        }

        // Case 1: App is already full screen on the correct screen and wants full screen -> leave untouched!
        if wantsFullScreen && currentlyFullScreen && !needsScreenChangeForFullScreen {
            log("AX ✅ '\(appName)' already full-screen on target display", level: .verbose)
            return (success: true, didModify: false)
        }

        var activeWin = win

        // Case 2: Target layout wants normal/windowed mode but window is currently full-screen, OR
        // target layout wants full-screen but window is currently on a DIFFERENT monitor -> exit full screen first
        if currentlyFullScreen && (!wantsFullScreen || needsScreenChangeForFullScreen) {
            log("ℹ️ Restore: '\(appName)' → exiting Full Screen first to change screens or layout", level: .verbose, type: .restore)
            _ = AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, kCFBooleanFalse)
            didModify = true
            
            // Wait up to 500ms, retrying the exit command if the window manager ignores it
            var exited = false
            for _ in 1...5 {
                for _ in 1...10 { // 100ms wait per attempt
                    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                    var fsCheckRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fsCheckRef) == .success,
                       let val = fsCheckRef as? Bool, !val {
                        exited = true
                        break
                    }
                }
                if exited { break }
                // Re-send exit command in case it was ignored or missed during space transitions
                _ = AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, kCFBooleanFalse)
            }
            
            if exited {
                try? await Task.sleep(nanoseconds: 800_000_000) // 800ms settle delay
            } else {
                log("⚠️ Restore: '\(appName)' failed to exit full screen programmatically", level: .moderate, type: .restore)
            }

            // Re-resolve the AXUIElement to ensure the reference is fresh and valid after the space transition
            let runningAppsArray = Array(NSWorkspace.shared.runningApplications)
            if let freshWin = await self.resolveAXWindow(for: record, runningApps: runningAppsArray) {
                activeWin = freshWin
                log("🔄 Re-resolved fresh AXUIElement for '\(appName)' after exiting Full Screen", level: .verbose, type: .restore)
            }
        }

        // Case 3: Target layout wants full-screen (and window was either not full screen or moved from another monitor)
        if wantsFullScreen {
            didModify = true

            // 1. Move window to the target screen
            var pos = CGPoint(x: axX, y: axY)
            if let v = AXValueCreate(.cgPoint, &pos) {
                _ = AXUIElementSetAttributeValue(activeWin, kAXPositionAttribute as CFString, v)
            }
            
            // 2. Set size to fill screen bounds on the destination screen FIRST
            var sz = CGSize(width: axW, height: axH)
            if let v = AXValueCreate(.cgSize, &sz) {
                _ = AXUIElementSetAttributeValue(activeWin, kAXSizeAttribute as CFString, v)
            }
            if let v = AXValueCreate(.cgPoint, &pos) {
                _ = AXUIElementSetAttributeValue(activeWin, kAXPositionAttribute as CFString, v)
            }

            // 3. Wait briefly and confirm window arrived on target screen coordinates
            for _ in 1...10 {
                if let current = getCurrentFrame(of: activeWin),
                   abs(current.origin.x - axX) <= 150 && abs(current.origin.y - axY) <= 150 {
                    break
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }

            // 4. Trigger native full screen if native full-screen is requested
            if record.isNativeFullScreen {
                let runningAppsArray = NSWorkspace.shared.runningApplications
                if let targetApp = runningAppsArray.first(where: { $0.bundleIdentifier == appName || $0.localizedName == appName }) {
                    targetApp.activate()
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms settle

                let fsErr = AXUIElementSetAttributeValue(activeWin, "AXFullScreen" as CFString, kCFBooleanTrue)
                if fsErr == .success {
                    log("✅ Restore: '\(appName)' → entering Full Screen on target display", level: .verbose, type: .restore)
                    return (success: true, didModify: true)
                } else {
                    log("ℹ️ Restore: '\(appName)' — native full-screen unsupported, kept at filled screen bounds", level: .verbose, type: .restore)
                    return (success: true, didModify: true)
                }
            } else {
                return (success: true, didModify: true)
            }
        }

        let axTargetFrame = CGRect(x: axX, y: axY, width: axW, height: axH)
        var targetSize = CGSize(width: axW, height: axH)
        var targetPos = CGPoint(x: axX, y: axY)

        // Check if window is already in exact position and size
        if let cur = getCurrentFrame(of: activeWin), isFrameClose(to: axTargetFrame, current: cur, tolerance: 2.0) {
            log("AX ✅ '\(appName)' already in place at (\(Int(axX)), \(Int(axY))) \(Int(axW))×\(Int(axH))", level: .verbose)
            return (success: true, didModify: didModify)
        }

        didModify = true

        // 1. Identify current screen and target screen to determine optimal resize order
        let screens = NSScreen.screens
        let currentFrame = getCurrentFrame(of: activeWin)
        let currentScreen: NSScreen?
        if let cur = currentFrame {
            let curMid = CGPoint(x: cur.midX, y: primaryScreenH - cur.midY)
            currentScreen = screens.first { $0.frame.contains(curMid) } ?? screens.first
        } else {
            currentScreen = screens.first
        }
        
        let targetMid = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        let targetScreen = screens.first { $0.frame.contains(targetMid) } ?? screens.first

        let currentScreenArea = (currentScreen?.frame.width ?? 1920) * (currentScreen?.frame.height ?? 1080)
        let targetScreenArea = (targetScreen?.frame.width ?? 1920) * (targetScreen?.frame.height ?? 1080)
        let isMovingToSmallerScreen = targetScreen != currentScreen && targetScreenArea < currentScreenArea

        if isMovingToSmallerScreen {
            // Target monitor is smaller: pre-shrink first so window can freely move into target monitor bounds
            let maxAllowedW = min(axW, (targetScreen?.visibleFrame.width ?? axW))
            let maxAllowedH = min(axH, (targetScreen?.visibleFrame.height ?? axH))
            var preShrinkSize = CGSize(width: maxAllowedW, height: maxAllowedH)
            if let v = AXValueCreate(.cgSize, &preShrinkSize) {
                _ = AXUIElementSetAttributeValue(activeWin, kAXSizeAttribute as CFString, v)
            }
            // Move to target position
            if let v = AXValueCreate(.cgPoint, &targetPos) {
                let e = AXUIElementSetAttributeValue(activeWin, kAXPositionAttribute as CFString, v)
                if e != .success { log("AX ⚠️ '\(appName)' set-position error \(e.rawValue)", level: .verbose) }
            }
            // Apply exact target size
            if let v = AXValueCreate(.cgSize, &targetSize) {
                let e = AXUIElementSetAttributeValue(activeWin, kAXSizeAttribute as CFString, v)
                if e != .success { log("AX ⚠️ '\(appName)' set-size error \(e.rawValue)", level: .verbose) }
            }
        } else {
            // Same monitor or moving to larger monitor: Position FIRST, then Size!
            // Move to target position
            if let v = AXValueCreate(.cgPoint, &targetPos) {
                let e = AXUIElementSetAttributeValue(activeWin, kAXPositionAttribute as CFString, v)
                if e != .success { log("AX ⚠️ '\(appName)' set-position error \(e.rawValue)", level: .verbose) }
            }
            // Apply exact target size
            if let v = AXValueCreate(.cgSize, &targetSize) {
                let e = AXUIElementSetAttributeValue(activeWin, kAXSizeAttribute as CFString, v)
                if e != .success { log("AX ⚠️ '\(appName)' set-size error \(e.rawValue)", level: .verbose) }
            }
        }

        // Double-check verification loop (up to 3 passes)
        for _ in 1...3 {
            try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
            if let current = getCurrentFrame(of: activeWin) {
                if isFrameClose(to: axTargetFrame, current: current, tolerance: 2.0) {
                    break
                }
                // Discrepancy detected: re-apply position & size
                if let v = AXValueCreate(.cgPoint, &targetPos) {
                    _ = AXUIElementSetAttributeValue(activeWin, kAXPositionAttribute as CFString, v)
                }
                if let v = AXValueCreate(.cgSize, &targetSize) {
                    _ = AXUIElementSetAttributeValue(activeWin, kAXSizeAttribute as CFString, v)
                }
            }
        }

        log("AX ✅ '\(appName)' final frame → (\(Int(axX)), \(Int(axY))) \(Int(axW))×\(Int(axH))", level: .verbose)
        return (success: true, didModify: true)
    }

    // MARK: - osascript fallback (nonisolated — safe on any thread)

    nonisolated private func restoreViaOsascript(record: WindowRecord, targetFrame: CGRect, primaryScreenH: CGFloat) async -> Bool {
        let appName = record.windowID.appBundleID
        let x       = Int(targetFrame.origin.x)
        let y       = Int(primaryScreenH - targetFrame.origin.y - targetFrame.height)
        let right   = x + Int(targetFrame.width)
        let bottom  = y + Int(targetFrame.height)
        let title   = record.windowID.windowTitle

        var script = ""
        
        // Window bounds setting part
        if title.isEmpty {
            script += """
            try
                tell application id "\(appName)"
                    set bounds of front window to {\(x), \(y), \(right), \(bottom)}
                end tell
            end try
            """
        } else {
            let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
            script += """
            try
                tell application id "\(appName)"
                    try
                        set bounds of window "\(safeTitle)" to {\(x), \(y), \(right), \(bottom)}
                    on error
                        set bounds of front window to {\(x), \(y), \(right), \(bottom)}
                    end try
                end tell
            end try
            """
        }

        // Full-screen part (System Events fallback)
        if record.isNativeFullScreen || record.isFullScreenMode {
            script += """
            
            tell application "System Events"
                try
                    set value of attribute "AXFullScreen" of (first window of (first process whose bundle identifier is "\(appName)")) to true
                end try
            end tell
            """
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = pipe

        do {
            try proc.run()
            proc.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let success = proc.terminationStatus == 0
            await MainActor.run { [weak self] in
                if success {
                    self?.log("osascript ✅ '\(appName)' → (\(x), \(y)) \(right - x)×\(bottom - y)", level: .verbose)
                } else {
                    self?.log("osascript ❌ '\(appName)': \(output.isEmpty ? "unknown error" : output)", level: .verbose)
                }
            }
            return success
        } catch {
            await MainActor.run { [weak self] in
                self?.log("osascript ❌ could not launch for '\(appName)': \(error)", level: .verbose)
            }
            return false
        }
    }

    /// Calculates the final intended frame for a window based on user preferences.
    /// Returns a frame adjusted for the specific screen's visible area (clamped to avoid being hidden under the menu bar or dock).
    private func calculateTargetFrame(for record: WindowRecord) -> CGRect {
        let f = record.globalFrame
        
        // Find which screen this window primarily lives on
        guard let screen = NSScreen.screens.max(by: { $0.frame.intersection(f).area < $1.frame.intersection(f).area }) ?? NSScreen.main else {
            return f
        }
        
        let vf = screen.visibleFrame
        
        // Preserve exact saved width and height (only capped if window is physically larger than visible screen)
        let targetW = min(f.width, vf.width)
        let targetH = min(f.height, vf.height)
        
        // Clamp origin so the entire window fits inside visibleFrame without mutating dimensions
        let targetX = min(max(f.origin.x, vf.minX), max(vf.minX, vf.maxX - targetW))
        let targetY = min(max(f.origin.y, vf.minY), max(vf.minY, vf.maxY - targetH))
        
        return CGRect(x: targetX, y: targetY, width: targetW, height: targetH)
    }

    // MARK: - AX Observer Event-Driven Tracking

    /// Registers AX observers for all currently-running user apps and does an initial capture in the background.
    private func startAXObservers() {
        Task { @MainActor in
            let apps = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular || $0.activationPolicy == .accessory
            }
            for app in apps {
                self.attachAXObserver(to: app)
            }
            // One initial capture to populate liveRecords once observers are configured
            self.scheduleAXEventFlush(delay: 100_000_000)
        }
    }

    /// Removes all AX observers and clears storage.
    private func stopAllAXObservers() {
        for (_, entry) in axObservers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), entry.source, .defaultMode)
        }
        axObservers.removeAll()
    }

    /// Attaches an AXObserver to the given app that fires on window-moved / resized / created / destroyed events.
    private func attachAXObserver(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, axObservers[pid] == nil else { return }
        // Skip our own process (handled via NSWindow notifications)
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        guard hasAccessibilityPermission else { return }

        var observer: AXObserver?
        // The C callback is a plain C function pointer — captures a raw unmanaged pointer to self.
        // We hop to the MainActor explicitly so WindowManager's actor isolation is respected.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let err = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon = refcon else { return }
            let manager = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in
                manager.scheduleAXEventFlush()
            }
        }, &observer)

        guard err == .success, let obs = observer else {
            log("AX observer: failed to create for pid \(pid) — err \(err.rawValue)", level: .verbose, type: .system)
            return
        }

        let axApp = WindowManager.createAXElement(for: pid)
        let notifications: [String] = [
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification
        ]
        for n in notifications {
            // Errors here are expected for apps that don't expose AX windows — ignore them.
            AXObserverAddNotification(obs, axApp, n as CFString, selfPtr)
        }

        let src = AXObserverGetRunLoopSource(obs)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        axObservers[pid] = (observer: obs, source: src)
    }

    /// Removes and destroys the AX observer for a given PID.
    private func detachAXObserver(for pid: pid_t) {
        guard let entry = axObservers[pid] else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), entry.source, .defaultMode)
        axObservers.removeValue(forKey: pid)
    }

    /// Coalesces AX notification bursts and rate-limits expensive full window scans.
    /// A few apps emit these notifications while idle, so cancellation-based debouncing alone
    /// would repeatedly allocate tasks and keep the process awake.
    func scheduleAXEventFlush(delay: UInt64 = 500_000_000) { // 500 ms default
        guard !isAXFlushScheduled else { return }
        isAXFlushScheduled = true

        // Keep live tracking responsive after a drag. Repeated idle notifications back off.
        let elapsed = lastAXCaptureDate.map { Date().timeIntervalSince($0) } ?? .infinity
        let throttleDelay = UInt64(max(0, axIdleCaptureInterval - elapsed) * 1_000_000_000)
        let effectiveDelay = max(delay, throttleDelay)
        axEventDebounceTask = Task { [weak self] in
            if effectiveDelay > 0 {
                do {
                    try await Task.sleep(nanoseconds: effectiveDelay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self = self, self.isTracking else {
                self?.isAXFlushScheduled = false
                return
            }
            // Already on MainActor (inherited from the class isolation)
            self.isAXFlushScheduled = false
            self.lastAXCaptureDate = Date()
            self.flushPendingSaves()
        }
    }

    private func startPolling() {

        trackingTask?.cancel()
        trackingTask = Task { [weak self] in
            // Initial snapshot to avoid logging everything on start
            if let self = self {
                let fp = ScreenFingerprint.current()
                let records = self.captureAllWindows(for: fp, silent: true)
                for r in records {
                    self.lastKnownWindows[r.windowID] = (r.globalFrame, r.id)
                }
                self.liveRecords = records
                self.lastWindowCount = records.count
            }

            // Polling is a compatibility fallback. Start at five seconds for responsiveness,
            // then exponentially back off while the desktop is unchanged to avoid idle wakeups.
            var pollInterval: UInt64 = 5_000_000_000
            let maximumPollInterval: UInt64 = 60_000_000_000
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: pollInterval)
                } catch {
                    break
                }
                guard let self = self, isTracking else { continue }
                
                let fp = ScreenFingerprint.current()
                let currentRecords = self.captureAllWindows(for: fp, silent: true)
                
                var hasChanges = false
                if currentRecords.count != self.lastKnownWindows.count {
                    hasChanges = true
                } else {
                    for r in currentRecords {
                        if let last = self.lastKnownWindows[r.windowID] {
                            if abs(last.frame.origin.x - r.globalFrame.origin.x) > 2 ||
                               abs(last.frame.origin.y - r.globalFrame.origin.y) > 2 ||
                               abs(last.frame.width - r.globalFrame.width) > 2 ||
                               abs(last.frame.height - r.globalFrame.height) > 2 {
                                hasChanges = true
                                break
                            }
                        } else {
                            hasChanges = true
                            break
                        }
                    }
                }
                
                if hasChanges {
                    // Update cache with ONLY current windows to avoid accumulating stale IDs
                    var nextMap: [WindowID: (frame: CGRect, id: UUID)] = [:]
                    for r in currentRecords {
                        nextMap[r.windowID] = (r.globalFrame, r.id)
                    }
                    self.lastKnownWindows = nextMap
                    self.liveRecords = currentRecords
                    self.lastWindowCount = currentRecords.count
                    pollInterval = 5_000_000_000
                } else {
                    pollInterval = min(pollInterval * 2, maximumPollInterval)
                }
            }
        }
    }

    private func handleExternalChanges(_: [WindowID: WindowRecord]) {
        // We now ignore the parameter and perform a full sync in flushPendingSaves
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPendingSaves()
        }
    }



    // MARK: - Persistence

    func persist() {
        guard !storeIsUnreadable else {
            log(
                "Refusing to save: \(saveURL.lastPathComponent) could not be read at launch, and saving now would overwrite it.",
                level: .necessary
            )
            return
        }
        do {
            let data = try JSONEncoder().encode(store)
            try data.write(to: saveURL, options: .atomic)
        } catch {
            log("Persist error: \(error)", level: .necessary)
        }
    }

    /// Keeps the first bad copy beside the original and refuses to save over
    /// it. A later launch must not replace that copy with a second, less
    /// interesting failure.
    private func markStoreUnreadable(_ reason: String) {
        storeIsUnreadable = true
        let backup = saveURL.appendingPathExtension("corrupt")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: saveURL, to: backup)
        }
        log(
            "\(saveURL.lastPathComponent) \(reason). A copy is at \(backup.lastPathComponent). Saving is disabled until this is resolved.",
            level: .necessary
        )
    }

    private func load() {
        // Missing and unreadable are different things. The first is a first
        // run; the second is a library that is still on disk and still wanted.
        let data: Data
        do {
            data = try Data(contentsOf: saveURL)
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            markStoreUnreadable("could not be read (\(error.localizedDescription))")
            return
        }

        var loaded: LayoutStore
        do {
            loaded = try JSONDecoder().decode(LayoutStore.self, from: data)
        } catch {
            markStoreUnreadable("could not be decoded (\(error.localizedDescription))")
            return
        }

        var migrated = false
        for (key, snap) in loaded.snapshots {
            if key == snap.screenKey {
                let newID = UUID().uuidString
                loaded.snapshots.removeValue(forKey: key)
                var updatedSnap = snap
                updatedSnap.id = UUID(uuidString: newID) ?? UUID()
                loaded.snapshots[newID] = updatedSnap
                if loaded.defaultSnapshotIDs[snap.screenKey] == nil {
                    loaded.defaultSnapshotIDs[snap.screenKey] = newID
                }
                migrated = true
            }
        }

        // Native full-screen windows are now supported again, so we no longer prune them here.

        // Purge old auto-save snapshots that were persisted by earlier app versions.
        // The live layout is now tracked via in-memory liveRecords and is never stored.
        var purged = false
        for (key, snap) in loaded.snapshots where snap.isAutoSave {
            loaded.snapshots.removeValue(forKey: key)
            if loaded.defaultSnapshotIDs[snap.screenKey] == key {
                loaded.defaultSnapshotIDs.removeValue(forKey: snap.screenKey)
            }
            purged = true
        }

        store = loaded
        pruneStore()
        if migrated || purged { persist() }
    }

    /// Removes 'ghost' records that no longer pass the filtering criteria (e.g. from accessory apps).
    private func pruneStore() {
        var changed = false
        for (snapKey, var snapshot) in store.snapshots {
            let originalCount = snapshot.records.count
            snapshot.records.removeAll { record in
                // Check if it's our own app
                if record.windowID.appBundleID == Bundle.main.bundleIdentifier ||
                   record.windowID.appName == ProcessInfo.processInfo.processName ||
                   record.windowID.appName == "RememberMyWindows" ||
                   record.windowID.appBundleID == "RememberMyWindows" {
                    return true
                }
                
                // Check if the app still exists and is 'regular'
                // We use the bundle ID if available, otherwise app name
                let appRef = record.windowID.appBundleID
                if let app = NSWorkspace.shared.runningApplications.first(where: { 
                    $0.bundleIdentifier == appRef || $0.localizedName == appRef 
                }) {
                    return app.activationPolicy != .regular && app.activationPolicy != .accessory
                }
                return false
            }
            if snapshot.records.count != originalCount {
                store.snapshots[snapKey] = snapshot
                changed = true
            }
        }
        if changed {
            persist()
            log("Pruned \(store.snapshots.values.reduce(0) { $0 + $1.records.count }) windows across all sessions", type: .system)
        }
    }

    // MARK: - Helpers

    private func defaultName(for fp: ScreenFingerprint) -> String {
        fp.readableName
    }

    func log(_ msg: String, level: LogLevel = .moderate, type: EventType = .system, details: [String]? = nil) {
        // Determine if we should record this log based on importance
        let currentLevelImportance: Int
        switch store.logLevel {
        case .necessary: currentLevelImportance = 0
        case .moderate:  currentLevelImportance = 1
        case .verbose:   currentLevelImportance = 2
        }

        let msgImportance: Int
        switch level {
        case .necessary: msgImportance = 0
        case .moderate:  msgImportance = 1
        case .verbose:   msgImportance = 2
        }

        if msgImportance > currentLevelImportance {
            return
        }

        let event = TrackingEvent(type: type, message: msg, details: details, date: Date())
        recentEvents.insert(event, at: 0)
        if recentEvents.count > 100 { recentEvents.removeLast() }
        print("[RememberMyWindows] [\(type.rawValue)] \(msg)")
        if let details = details {
            details.forEach { print("  - \($0)") }
        }
    }

    private func formatWindowDetail(record: WindowRecord) -> String {
        let app = record.windowID.appName ?? record.windowID.appBundleID
        let title = record.windowID.windowTitle
        let size = "\(Int(record.globalFrame.width))×\(Int(record.globalFrame.height))"
        let screen = record.screenName ?? "Unknown Screen"
        
        // If the window title is exactly the same as the app name, or contains it redundantly, simplify
        if title.isEmpty || title == app {
            return "\(app) [\(size)] on \(screen)"
        } else {
            return "\(app) '\(title)' [\(size)] on \(screen)"
        }
    }

    // MARK: - CLLocationManagerDelegate
    
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            currentLocation = locations.last
            lastLocationTimestamp = Date()
            
            if isWaitingForLocationUpdate {
                isWaitingForLocationUpdate = false
                log("📍 Location received. Completing save...", level: .moderate, type: .system)
                performSave(named: pendingSaveName)
                pendingSaveName = nil
            }
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            log("Location error: \(error.localizedDescription)", type: .system)
            if isWaitingForLocationUpdate {
                isWaitingForLocationUpdate = false
                log("⚠️ Location update failed. Proceeding with save anyway.", type: .system)
                performSave(named: pendingSaveName)
                pendingSaveName = nil
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            self.locationAuthorizationStatus = status
            
            // If authorized, start a single request to get the initial location
            if status != .notDetermined && status != .denied && status != .restricted {
                manager.requestLocation()
            }
            
            if isWaitingForLocationPermission && status != .notDetermined {
                isWaitingForLocationPermission = false
                let isAuthorized = status != .denied && status != .restricted
                log("Location permission updated (\(isAuthorized ? "authorized" : "denied")). Resuming save.", type: .system)
                performSave(named: pendingSaveName)
                pendingSaveName = nil
            }
        }
    }

    /// Helper to geocode and update a snapshot's location
    private func updateSnapshotLocation(key: String, location: CLLocation) {
        Task {
            let coder = CLGeocoder()
            if let placemarks = try? await coder.reverseGeocodeLocation(location),
               let first = placemarks.first {
                let addr = [first.name, first.locality, first.administrativeArea]
                    .compactMap { $0 }.joined(separator: ", ")
                await MainActor.run {
                    if self.store.snapshots[key] != nil {
                        self.store.snapshots[key]?.location = LocationInfo(
                            latitude: location.coordinate.latitude,
                            longitude: location.coordinate.longitude,
                            address: addr
                        )
                        self.persist()
                    }
                }
            }
        }
    }

    /// Sends the Command+Shift+R keystroke (Reader Mode / Media Video Pop-up) to the frontmost application.
    /// Can optionally check if there is an external monitor connected.
    func sendCommandToFrontmostApp(targetBundleID: String? = nil, snapshot: LayoutSnapshot? = nil, delayOverride: Double? = nil) {
        Task { @MainActor in
            await self.sendCommandToFrontmostAppAsync(targetBundleID: targetBundleID, snapshot: snapshot, delayOverride: delayOverride)
        }
    }

    func sendCommandToFrontmostAppAsync(targetBundleID: String? = nil, snapshot: LayoutSnapshot? = nil, delayOverride: Double? = nil) async {
        guard !isScreenLocked else {
            log("Command skipped: Screen is currently locked.", level: .verbose, type: .system)
            return
        }
        guard AXIsProcessTrusted() else { return }
        
        let runningApps = NSWorkspace.shared.runningApplications
        var targetApp: NSRunningApplication?
        
        if let bundleID = targetBundleID {
            targetApp = runningApps.first(where: { $0.bundleIdentifier == bundleID || $0.localizedName == bundleID })
        }
        
        if targetApp == nil {
            targetApp = runningApps.first(where: { $0.isActive })
        }
        
        guard let app = targetApp else {
            log("Command skipped: No target application found to activate.", level: .verbose, type: .system)
            return
        }
        
        let appBundleID = app.bundleIdentifier ?? ""
        if let snap = snapshot, !snap.commandExcludedBundleIDs.contains(appBundleID) {
            log("Command skipped: App '\(app.localizedName ?? appBundleID)' is not enabled in the active layout.", level: .moderate, type: .system)
            return
        }
        
        // If external monitor restriction is active, verify that we have at least 2 screens connected
        if store.refreshFrontmostOnlyOnExternalDisplay {
            guard NSScreen.screens.count >= 2 else {
                log("Command skipped: Single monitor detected, but setting requires an external display.", level: .verbose, type: .system)
                return
            }
        }
        
        // Ensure the app is active and brought to frontmost status
        if !app.isActive {
            app.activate()
            if let url = app.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
            }
        }
        
        log("Sending Command+Shift+R (Reader/Video Mode) to app '\(app.localizedName ?? "")'", level: .moderate, type: .system)
        
        let delay = delayOverride ?? 0.3
        let shouldAnimate = store.showCommandOverlayAnimation
        
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        
        if shouldAnimate {
            CommandOverlayManager.shared.showOverlay(for: app)
        }
        
        let src = CGEventSource(stateID: .combinedSessionState)
        let rKeyDown = CGEvent(keyboardEventSource: src, virtualKey: 15, keyDown: true)
        rKeyDown?.flags = [.maskCommand, .maskShift]
        let rKeyUp = CGEvent(keyboardEventSource: src, virtualKey: 15, keyDown: false)
        rKeyUp?.flags = []
        
        rKeyDown?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms key down hold
        rKeyUp?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 30_000_000) // 30ms settle
    }
}

// MARK: - Event model

enum EventType: String, Codable {
    case autoSave = "Auto-save"
    case manualSave = "Save"
    case restore = "Restore"
    case system = "System"
}

struct TrackingEvent: Identifiable {
    let id = UUID()
    let type: EventType
    let message: String
    let details: [String]?
    let date: Date

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
