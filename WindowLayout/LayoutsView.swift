import SwiftUI
import MapKit

struct LayoutsView: View {
    @EnvironmentObject var manager: WindowManager
    @AppStorage("themeColor") private var themeColor: ThemeColor = .default
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .auto

    var body: some View {
        let hasSaved = !manager.store.snapshots.filter({ !$0.value.isAutoSave }).isEmpty
        if manager.liveRecords.isEmpty && !hasSaved {
            emptyState
        } else if let key = manager.selectedSnapshotKey {
            if key == WindowManager.liveKey {
                let fp = manager.currentFingerprint
                let liveSnap = LayoutSnapshot(
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
                SnapshotDetailView(snapshot: liveSnap, key: key)
            } else if let snapshot = manager.store.snapshots[key] {
                SnapshotDetailView(snapshot: snapshot, key: key)
            } else {
                Text("Select a layout to view details".localized(appLanguage))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            Text("Select a layout to view details".localized(appLanguage))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Empty State

    var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 52))
                .foregroundStyle(.quaternary)
            Text("No layouts saved yet".localized(appLanguage))
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Arrange your windows and click \"Save Layout\" to record their positions.\nThey'll be restored automatically whenever this screen configuration reconnects.".localized(appLanguage))
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Snapshot List View

struct SnapshotListView: View {
    @EnvironmentObject var manager: WindowManager
    @AppStorage("themeColor") private var themeColor: ThemeColor = .default
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .auto
    @State private var hoveredKey: String? = nil

    var liveSnapshot: (key: String, snapshot: LayoutSnapshot)? {
        guard !manager.liveRecords.isEmpty else { return nil }
        let fp = manager.currentFingerprint
        let snap = LayoutSnapshot(
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
        return (key: WindowManager.liveKey, snapshot: snap)
    }

    var savedSnapshots: [(key: String, snapshot: LayoutSnapshot)] {
        return manager.store.snapshots
            .filter { !$0.value.isAutoSave }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .map { (key: $0.key, snapshot: $0.value) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // LIVE LAYOUT SECTION
                VStack(alignment: .leading, spacing: 8) {
                    Text("LIVE LAYOUT".localized(appLanguage))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                    
                    if let live = liveSnapshot {
                        snapshotRow(live.snapshot, key: live.key, isLive: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .liquidGlass(
                                isSelected: manager.selectedSnapshotKey == live.key,
                                prominent: true,
                                tint: themeColor.color(seed: 1),
                                isHovered: hoveredKey == live.key
                            )
                            .contentShape(Rectangle())
                            .onHover { isHovered in
                                if isHovered { hoveredKey = live.key }
                                else if hoveredKey == live.key { hoveredKey = nil }
                            }
                            .onTapGesture {
                                manager.selectedSnapshotKey = live.key
                                manager.selectedAppBundleID = nil
                            }
                    } else {
                        Text("No active layout for this screen config".localized(appLanguage))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 8)
                    }

                    // SCREEN ID — fixed below the live layout row
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SCREEN ID".localized(appLanguage))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                        Text(manager.currentFingerprint.key)
                            .font(.system(size: 8).monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 8)
                }

                // SAVED SESSIONS SECTION
                VStack(alignment: .leading, spacing: 8) {
                    Text("SAVED SESSIONS".localized(appLanguage))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                    
                    if savedSnapshots.isEmpty {
                        Text("No saved sessions".localized(appLanguage))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 8)
                    } else {
                        ForEach(savedSnapshots, id: \.key) { item in
                            snapshotRow(item.snapshot, key: item.key, isLive: false)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .liquidGlass(
                                    isSelected: manager.selectedSnapshotKey == item.key,
                                    prominent: false,
                                    tint: themeColor.color(seed: 2),
                                    isHovered: hoveredKey == item.key
                                )
                                .contentShape(Rectangle())
                                .onHover { isHovered in
                                    if isHovered { hoveredKey = item.key }
                                    else if hoveredKey == item.key { hoveredKey = nil }
                                }
                                .onTapGesture {
                                    manager.selectedSnapshotKey = item.key
                                    manager.selectedAppBundleID = nil
                                }
                                .contextMenu {
                                    Button("Restore") { manager.restore(key: item.key) }
                                        .disabled(!manager.canRestore(snapshot: item.snapshot))
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        manager.deleteSnapshot(key: item.key)
                                        if manager.selectedSnapshotKey == item.key { manager.selectedSnapshotKey = nil }
                                    }
                                }
                        }
                    }
                }
            }
            .padding(12)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Remember")
    }

    func snapshotRow(_ snapshot: LayoutSnapshot, key: String, isLive: Bool) -> some View {
        let isApplicable = isLive || (manager.currentApplicableSnapshot?.id == snapshot.id)
        let rowTint = isApplicable ? themeColor.color(seed: 0) : Color.primary
        let displayCount = ScreenFingerprint.from(key: snapshot.screenKey).displays.count
        let systemIcon = displayCount > 1 ? "display.2" : "display"
        return HStack(spacing: 12) {
            Image(systemName: systemIcon)
                .font(.system(size: 18))
                .foregroundStyle(isApplicable ? themeColor.color(seed: 0) : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(snapshot.displayName)
                        .font(.system(.headline, design: .rounded).weight(.medium))
                        .lineLimit(1)
                    if isLive {
                        Text("Live".localized(appLanguage))
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(themeColor.color(seed: 3).opacity(0.15))
                            .foregroundStyle(themeColor.color(seed: 3))
                            .clipShape(Capsule())
                    }
                }

                if isLive {
                    Text(ScreenFingerprint.from(key: snapshot.screenKey).readableName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(themeColor.color(seed: 4))
                        .lineLimit(1)
                }

                Text("\(snapshot.records.count) windows · \(snapshot.updatedAt.formatted(.relative(presentation: .named).locale(currentLocale)))")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            ScreenLayoutThumbnail(
                screenKey: snapshot.screenKey,
                tint: rowTint,
                isLive: isLive,
                isHighlighted: isApplicable
            )
        }
    }
}

// MARK: - Snapshot Detail View

struct SnapshotDetailView: View {
    @EnvironmentObject var manager: WindowManager
    @AppStorage("themeColor") private var themeColor: ThemeColor = .default
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .auto
    let snapshot: LayoutSnapshot
    let key: String

    var isPhysicalMismatch: Bool {
        let current = manager.currentFingerprint
        let snapFP = ScreenFingerprint.from(key: snapshot.screenKey)
        
        let currentUUIDs = Set(current.displays.compactMap { $0.uuid })
        let snapUUIDs = Set(snapFP.displays.compactMap { $0.uuid })
        
        // If models match (name + resolution) but physical units (UUIDs) differ
        return current.modelKey == snapFP.modelKey && currentUUIDs != snapUUIDs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snapshot.displayName)
                                .font(.system(.title2, design: .rounded).weight(.semibold))
                            Text(ScreenFingerprint.from(key: snapshot.screenKey).readableName)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        
                        HStack(spacing: 24) {
                            statPill(label: "Windows".localized(appLanguage), value: "\(snapshot.records.count)")
                            statPill(label: "Created".localized(appLanguage), value: snapshot.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: currentLocale)))
                            statPill(label: "Updated".localized(appLanguage), value: snapshot.updatedAt.formatted(.relative(presentation: .named).locale(currentLocale)))
                        }
                    }
                    
                    if let location = snapshot.location, !snapshot.isAutoSave && manager.store.saveLocationEnabled {
                        LocationBlock(snapshotID: key, location: location, isUpdated: snapshot.updatedAt.timeIntervalSince(snapshot.createdAt) > 1)
                    }
                }
                


                if isPhysicalMismatch || !manager.canRestore(snapshot: snapshot) {
                    HStack(alignment: .top, spacing: 10) {
                        if isPhysicalMismatch {
                            HStack(spacing: 10) {
                                Image(systemName: "display.and.arrow.down")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("New monitor detected with the same name".localized(appLanguage))
                                        .font(.system(size: 12, weight: .bold))
                                    Text("This is a different physical unit than the one in this session.".localized(appLanguage))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.blue.opacity(0.15), lineWidth: 1)
                            }
                        }

                        if !manager.canRestore(snapshot: snapshot) {
                            HStack(spacing: 10) {
                                Image(systemName: "display.trianglebadge.exclamationmark")
                                    .font(.title3)
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("External Screens Missing".localized(appLanguage))
                                        .font(.subheadline.weight(.semibold))
                                    Text("Connect the required displays to enable restoration of this session.".localized(appLanguage))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .background(Color.clear)

            Divider()

            // Window list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(snapshot.records.filter { !$0.windowID.appBundleID.isEmpty }) { record in
                            let isForeground = record.windowID.appBundleID == snapshot.foregroundBundleID
                            let isCurrentApp = record.windowID.appBundleID == manager.selectedAppBundleID
                            windowRow(record, isForeground: isForeground, isCurrentApp: isCurrentApp)
                                .id(record.id)
                        }
                    }
                    .padding(24)
                }
                .onAppear {
                    scrollToCurrentApp(using: proxy)
                }
                .onChange(of: manager.selectedAppBundleID) { _ in
                    scrollToCurrentApp(using: proxy)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Returns true if this window was captured from a different Mission Control Space
    /// (i.e. it had no visible window on the current Space at capture time).
    /// Set precisely during capture — no false positives from Fill Screen / maximized windows.
    private func isEntireScreen(_ record: WindowRecord) -> Bool {
        record.isFullScreenMode
    }

    func windowRow(_ record: WindowRecord, isForeground: Bool, isCurrentApp: Bool) -> some View {
        let isFull = isEntireScreen(record)
        let rowTint = isFull ? Color.indigo : themeColor.color(seed: 6)
        
        return WindowRowContainer(
            record: record,
            isForeground: isForeground,
            isCurrentApp: isCurrentApp,
            isFull: isFull,
            rowTint: rowTint,
            snapshot: snapshot,
            key: key,
            appLanguage: appLanguage,
            themeColor: themeColor
        )
    }

    private func scrollToCurrentApp(using proxy: ScrollViewProxy) {
        guard let currentAppID = manager.selectedAppBundleID,
              let record = snapshot.records.first(where: { $0.windowID.appBundleID == currentAppID }) else {
            return
        }
        withAnimation(.smooth) {
            proxy.scrollTo(record.id, anchor: .center)
        }
    }

    func statPill(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.weight(.medium))
        }
    }
}

struct WindowRowContainer: View {
    let record: WindowRecord
    let isForeground: Bool
    let isCurrentApp: Bool
    let isFull: Bool
    let rowTint: Color
    let snapshot: LayoutSnapshot
    let key: String
    let appLanguage: AppLanguage
    let themeColor: ThemeColor
    @EnvironmentObject var manager: WindowManager
    @State private var isRowHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon: full-screen variant vs normal positioned preview
            if isFull {
                FullScreenPreviewIcon(tint: rowTint)
                    .frame(width: 52, height: 34)
            } else {
                WindowPreviewIcon(record: record, tint: rowTint)
                    .frame(width: 52, height: 34)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    AppIconView(bundleID: record.windowID.appBundleID)
                        .frame(width: 15, height: 15)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                    Text(record.windowID.appName ?? record.windowID.appBundleID)
                        .font(.system(.headline, design: .rounded).weight(.medium))
                    if isCurrentApp {
                        Text("Active".localized(appLanguage))
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(Color.green)
                            .clipShape(Capsule())
                    }
                    if isFull {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 8, weight: .bold))
                            Text("Full Screen".localized(appLanguage))
                                .font(.system(size: 10, weight: .bold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.indigo.opacity(0.15))
                        .foregroundStyle(Color.indigo)
                        .clipShape(Capsule())
                    }
                    if isForeground {
                        Image(systemName: "square.3.layers.3d.top.filled")
                            .font(.system(size: 10))
                            .foregroundStyle(themeColor.color(seed: 5))
                            .help("This app will be brought to the front upon restore")
                    }
                }

                HStack(spacing: 4) {
                    if let screenName = record.screenName {
                        Text(lz(screenName))
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(rowTint.opacity(0.1))
                            .foregroundStyle(rowTint)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }

                    if !record.windowID.windowTitle.isEmpty {
                        Text(record.windowID.windowTitle)
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            
            if !snapshot.isAutoSave {
                HStack(spacing: 8) {
                    let appID = record.windowID.appBundleID
                    let isIncluded = snapshot.commandExcludedBundleIDs.contains(appID)
                    
                    // ⌘⇧R button: always visible, showing green checkmark when enabled, dim when disabled.
                    ExcludeCommandButton(appLanguage: appLanguage, isIncluded: isIncluded) {
                        manager.toggleCommandExclusion(key: key, bundleID: appID)
                    }
                    
                    // Bring-to-front: always visible when active (filled), only on hover otherwise
                    if isForeground || isRowHovered {
                        BringToFrontButton(appLanguage: appLanguage, isActive: isForeground) {
                            manager.setForegroundApp(key: key, bundleID: appID)
                            manager.bringAppToFront(bundleID: appID)
                        }
                    } else {
                        Spacer().frame(width: 26, height: 26)
                    }
                    
                    DeleteSessionAppButton(appLanguage: appLanguage) {
                        manager.removeAppFromSnapshot(key: key, windowID: record.windowID)
                    }
                }
            }
            
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(record.globalFrame.width)) × \(Int(record.globalFrame.height))")
                    .font(.footnote.monospaced())
                Text("(\(Int(record.globalFrame.origin.x)), \(Int(record.globalFrame.origin.y)))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .liquidGlass(isSelected: isCurrentApp || isForeground, prominent: false, tint: themeColor.color(seed: 6), isHovered: isRowHovered)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isRowHovered ? themeColor.color(seed: 6).opacity(0.35) : Color.clear, lineWidth: 1.5)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isRowHovered = hovering
            }
        }
    }
}



struct LocationBlock: View {
    @EnvironmentObject var manager: WindowManager
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .auto
    let snapshotID: String
    let location: LocationInfo
    let isUpdated: Bool
    
    @State private var isEditing = false
    @State private var editedAddress: String = ""
    @FocusState private var isFocused: Bool
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }
    
    var body: some View {
        HStack(spacing: 14) {
            // Map Preview
            ZStack {
                Map(position: .constant(.region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )))) {
                    Marker("", coordinate: coordinate)
                }
                .id(snapshotID) // Force recreation when switching layouts to ensure position updates
                .allowsHitTesting(false)
                
                Color.black.opacity(0.01)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let url = URL(string: "http://maps.apple.com/?ll=\(location.latitude),\(location.longitude)&q=Saved%20Location")!
                        NSWorkspace.shared.open(url)
                    }
            }
            .frame(width: 100, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
            .fixedSize()
            
            VStack(alignment: .leading, spacing: 3) {
                Label((isUpdated ? "Saved&Updated At" : "Saved At").localized(appLanguage), systemImage: "location.fill")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.secondary)
                    .opacity(0.8)
                
                if isEditing {
                    TextField("Location Name", text: $editedAddress, onCommit: {
                        manager.updateLocationAddress(key: snapshotID, newAddress: editedAddress)
                        isEditing = false
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .focused($isFocused)
                    .onAppear {
                        editedAddress = location.address ?? "\(location.latitude), \(location.longitude)"
                        isFocused = true
                    }
                } else {
                    Text(location.address ?? "\(location.latitude), \(location.longitude)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: 170, alignment: .leading)
                        .onTapGesture {
                            isEditing = true
                        }
                }
                
                if !isEditing {
                    Text("Click to rename".localized(appLanguage))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 170, alignment: .leading)
        }
        .padding(10)
        .fixedSize(horizontal: true, vertical: true)
        .background {
            VisualEffectView(material: .selection, blendingMode: .withinWindow)
                .opacity(0.4)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
        }
    }
}

struct DeleteSessionAppButton: View {
    let appLanguage: AppLanguage
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        ZStack {
            Circle()
                .fill(isHovered ? Color.red.opacity(0.15) : Color.clear)
                .frame(width: 26, height: 26)
            Image(systemName: "trash")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovered ? Color.red : Color.red.opacity(0.7))
        }
        .frame(width: 26, height: 26)
        .contentShape(Circle())
        .onTapGesture { action() }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .help("Remove from Session".localized(appLanguage))
    }
}

struct ExcludeCommandButton: View {
    let appLanguage: AppLanguage
    let isIncluded: Bool
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        ZStack {
            // Background capsule
            Capsule()
                .fill(isIncluded
                      ? Color.green.opacity(0.1)
                      : (isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.02)))
                .frame(width: 56, height: 26)
            
            // Command badge — use a ZStack.topTrailing for the inclusion checkmark badge
            ZStack(alignment: .topTrailing) {
                Text("⌘⇧R")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(isIncluded 
                                     ? Color.green.opacity(0.85) 
                                     : (isHovered ? Color.primary.opacity(0.65) : Color.secondary.opacity(0.35)))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                
                if isIncluded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 6.5, weight: .black))
                        .foregroundStyle(Color.white)
                        .padding(1.5)
                        .background(Color.green, in: Circle())
                        .offset(x: 3, y: -3)
                }
            }
        }
        .frame(width: 60, height: 30)
        .contentShape(Capsule())
        .onTapGesture { action() }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .help(isIncluded
              ? "Disable Command Trigger for this app".localized(appLanguage)
              : "Enable Command Trigger for this app".localized(appLanguage))
    }
}

struct BringToFrontButton: View {
    let appLanguage: AppLanguage
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        ZStack {
            Circle()
                .fill(isActive
                      ? Color.accentColor
                      : (isHovered ? Color.accentColor.opacity(0.15) : Color.clear))
                .frame(width: 26, height: 26)
            Image(systemName: "square.3.layers.3d.top.filled")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? Color.white : (isHovered ? Color.accentColor : Color.secondary))
        }
        .frame(width: 26, height: 26)
        .contentShape(Circle())
        .onTapGesture { action() }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .help(isActive
              ? "Click to unset Bring to Front".localized(appLanguage)
              : "Bring to Front".localized(appLanguage))
    }
}
