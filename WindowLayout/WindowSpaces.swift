import Foundation
import CoreGraphics
import AppKit

/// Which Space does a window belong to?
///
/// Neither of the two APIs the capture already uses can answer that.
/// `CGWindowListCopyWindowInfo` reports every window on every Space but says
/// nothing about which. The accessibility tree returns **success with an empty
/// window list** for an app whose windows are parked on a Space that is not the
/// current one, so reading AX alone makes a live window indistinguishable from
/// a leftover the window server has not reaped.
///
/// That distinction is not cosmetic. It decides whether a record is worth
/// saving, whether the collapse guard is measuring anything, and whether a
/// restore can honestly claim to have finished.
///
/// The only source that knows is `CGSCopySpacesForWindows`, which is private.
/// It is resolved here at runtime with `dlsym`, so nothing links against a
/// private symbol and a macOS release that renames or withdraws one leaves
/// `isAvailable` false. Every caller must keep working in that case, with the
/// behaviour it had before this file existed.
enum WindowSpaces {

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    /// `kCGSAllSpacesMask` — the current Space, the others, and full-screen ones.
    /// Asking for a narrower set would make a window on another Space look like
    /// a window on none, which is the exact confusion this file exists to end.
    private static let allSpacesSelector: Int32 = 0x7

    private struct Resolved {
        let connection: Int32
        let lookup: SpacesForWindowsFn
    }

    /// Resolved once. `dlopen(nil, …)` hands back a handle to the running
    /// image, and CoreGraphics is already linked by way of AppKit, so the
    /// symbols are reachable without naming a framework path that could move.
    private static let resolved: Resolved? = {
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        guard let connectionPtr = dlsym(handle, "CGSMainConnectionID"),
              let lookupPtr = dlsym(handle, "CGSCopySpacesForWindows") else { return nil }
        let connection = unsafeBitCast(connectionPtr, to: MainConnectionFn.self)()
        guard connection != 0 else { return nil }
        return Resolved(connection: connection,
                        lookup: unsafeBitCast(lookupPtr, to: SpacesForWindowsFn.self))
    }()

    /// False when the private symbols could not be resolved. Callers fall back
    /// to their previous behaviour rather than treating every window as a
    /// leftover, which would empty the layout.
    static var isAvailable: Bool { resolved != nil }

    /// The Spaces one window belongs to. Empty means none: it is a leftover.
    ///
    /// The call takes an array but returns the *union* of Spaces across it, not
    /// a mapping, so one window per call is the only way to get an answer per
    /// window. Measured at well under a millisecond each, against the tens of
    /// milliseconds of accessibility IPC the same capture already pays.
    static func spaces(of windowID: CGWindowID) -> [Int] {
        guard let r = resolved else { return [] }
        let ids = [NSNumber(value: windowID)] as CFArray
        guard let result = r.lookup(r.connection, allSpacesSelector, ids)?.takeRetainedValue(),
              let numbers = result as? [NSNumber] else { return [] }
        return numbers.map { $0.intValue }
    }

    /// The Spaces for a batch of windows, keyed by window id.
    static func spaces(of windowIDs: [CGWindowID]) -> [CGWindowID: [Int]] {
        guard isAvailable else { return [:] }
        var out: [CGWindowID: [Int]] = [:]
        out.reserveCapacity(windowIDs.count)
        for id in windowIDs {
            out[id] = spaces(of: id)
        }
        return out
    }

    /// The Spaces that are active right now, one per display.
    ///
    /// Needed to tell two kinds of window apart, both of which have no
    /// accessibility frame to match against: one parked on another Space, which
    /// is real, and one on the Space in front of the user that the accessibility
    /// tree declined to report, which is not.
    static func currentSpaces() -> Set<Int> {
        guard let r = resolved,
              let handle = dlopen(nil, RTLD_NOW),
              let ptr = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return [] }
        typealias ManagedSpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
        let fn = unsafeBitCast(ptr, to: ManagedSpacesFn.self)
        guard let displays = fn(r.connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var out = Set<Int>()
        for display in displays {
            if let current = display["Current Space"] as? [String: Any],
               let id = current["ManagedSpaceID"] as? Int {
                out.insert(id)
            }
        }
        return out
    }

    /// The subset that belongs to at least one Space, i.e. the windows that
    /// really exist. Returns every id unchanged when the lookup is unavailable,
    /// so a caller filtering on this set is a no-op rather than a purge.
    static func onAnySpace(_ windowIDs: [CGWindowID]) -> Set<CGWindowID> {
        guard isAvailable else { return Set(windowIDs) }
        var out = Set<CGWindowID>()
        for id in windowIDs where !spaces(of: id).isEmpty {
            out.insert(id)
        }
        return out
    }

    /// Returns true if the active space is a standard desktop space (type == 0),
    /// and false if it is a full-screen app space (type 4/2) or another non-desktop space.
    static func isCurrentSpaceDesktop() -> Bool {
        // Fast-path 1: Check if the frontmost app is in AX full-screen mode
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.10)
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
               let windows = value as? [AXUIElement] {
                for window in windows {
                    var isFullScreen: AnyObject?
                    if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &isFullScreen) == .success,
                       let fsNumber = isFullScreen as? NSNumber, fsNumber.boolValue {
                        return false
                    }
                }
            }
        }

        // Fast-path 2: Query WindowServer via CGSGetActiveSpace & CGSSpaceGetType
        guard let r = resolved,
              let handle = dlopen(nil, RTLD_NOW) else { return true }
        
        typealias GetActiveSpaceFn = @convention(c) (Int32) -> UInt64
        typealias GetSpaceTypeFn = @convention(c) (Int32, UInt64) -> Int32
        if let activePtr = dlsym(handle, "CGSGetActiveSpace"),
           let typePtr = dlsym(handle, "CGSSpaceGetType") {
            let getActive = unsafeBitCast(activePtr, to: GetActiveSpaceFn.self)
            let getType = unsafeBitCast(typePtr, to: GetSpaceTypeFn.self)
            let activeSpace = getActive(r.connection)
            let spaceType = getType(r.connection, activeSpace)
            // Type 0 is standard user desktop. Type 2 and 4 are full-screen app spaces.
            if spaceType != 0 {
                return false
            }
        }

        // Fast-path 3: Check Current Space type across displays via CGSCopyManagedDisplaySpaces
        if let ptr = dlsym(handle, "CGSCopyManagedDisplaySpaces") {
            typealias ManagedSpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
            let fn = unsafeBitCast(ptr, to: ManagedSpacesFn.self)
            if let displays = fn(r.connection)?.takeRetainedValue() as? [[String: Any]] {
                for display in displays {
                    if let current = display["Current Space"] as? [String: Any],
                       let type = current["type"] as? Int, type != 0 {
                        return false
                    }
                }
            }
        }

        return true
    }

}

