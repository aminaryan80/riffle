import AppKit
import ApplicationServices

struct WindowInfo {
    let ax: AXUIElement
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let icon: NSImage?
    let title: String
    let frame: CGRect
}

enum WindowEnumerator {
    struct Snapshot {
        let windows: [WindowInfo]
        let activeScreen: NSScreen?
        let frontmostPID: pid_t?
        // Precomputed at trigger time so callers don't need the display helpers.
        let activeScreenWindowIDs: Set<CGWindowID>
    }

    // The cached enumeration keeps the window-server stacking order so the
    // most-recently-used sort (which depends on live FocusHistory timestamps)
    // can be recomputed cheaply at each trigger without re-probing.
    private struct RankedWindow {
        let rank: Int
        let order: Int
        let info: WindowInfo
    }

    // Windows smaller than this are helper/phantom windows, not real ones.
    private static let minWindowSize = CGSize(width: 100, height: 50)
    // How many remote-token element ids to probe per app.
    private static let bruteForceRange: Int32 = 1000
    // Per-app time budget for the probe, in case an app's AX server hangs.
    private static let perAppBudget: TimeInterval = 1.5

    private static let cacheLock = NSLock()
    private static var cachedWindows: [RankedWindow]?
    private static var refreshInFlight = false
    private static var refreshStale = false
    private static let refreshQueue = DispatchQueue(label: "Riffle.WindowEnumerator.refresh")

    /// Rebuild the cached window list off the main thread. Coalesced: requests
    /// that arrive while a refresh is running collapse into a single re-run
    /// once it finishes.
    static func refreshAsync() {
        cacheLock.lock()
        if refreshInFlight {
            // Don't just drop it. The in-flight sweep may have started *before*
            // whatever prompted this request (an app quitting, say), so its
            // result is already stale — it would bake the dead app back into the
            // cache and leave it there until something else happened.
            refreshStale = true
            cacheLock.unlock()
            return
        }
        refreshInFlight = true
        cacheLock.unlock()
        runRefresh()
    }

    private static func runRefresh() {
        refreshQueue.async {
            let ranked = enumerateWindows()
            cacheLock.lock()
            cachedWindows = ranked
            let again = refreshStale
            refreshStale = false
            if !again { refreshInFlight = false }
            cacheLock.unlock()
            if again { runRefresh() }
        }
    }

    /// Cheap per-trigger view over the (cached) window list. Serves the last
    /// enumeration immediately and kicks a background refresh for next time;
    /// only the very first call pays for a synchronous sweep.
    static func snapshot() -> Snapshot {
        cacheLock.lock()
        let cached = cachedWindows
        cacheLock.unlock()

        var ranked: [RankedWindow]
        if let cached {
            ranked = cached
            refreshAsync()
        } else {
            ranked = enumerateWindows()
            cacheLock.lock()
            cachedWindows = ranked
            cacheLock.unlock()
        }

        // The cache is always a beat behind: the background refresh that a quit
        // or a closed window kicks off can't finish before an immediate
        // re-trigger, so the list would still show windows that are gone.
        // Asking the window server which ids are still alive is a cheap call
        // (unlike the AX sweep that builds the cache), so it can run per
        // trigger and drop the dead ones before they're ever displayed.
        let live = Set(cgWindows([.optionAll, .excludeDesktopElements]).map { $0.wid })
        ranked = ranked.filter { live.contains($0.info.windowID) }

        let activeDisplay = currentActiveDisplay()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Most-recently-used first, from our own focus history; windows not
        // focused since launch fall back to front-to-back stacking order.
        let focus = FocusHistory.shared.timestamps()
        let sorted = ranked.sorted { a, b in
            let ta = focus[a.info.windowID]
            let tb = focus[b.info.windowID]
            switch (ta, tb) {
            case let (x?, y?): return x > y
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return (a.rank, a.order) < (b.rank, b.order)
            }
        }
        let windows = sorted.map { $0.info }
        let activeScreenWindowIDs = Set(
            windows.filter { display(for: $0.frame) == activeDisplay }.map { $0.windowID }
        )
        return Snapshot(
            windows: windows,
            activeScreen: nsScreen(for: activeDisplay),
            frontmostPID: frontmostPID,
            activeScreenWindowIDs: activeScreenWindowIDs
        )
    }

    private static func enumerateWindows() -> [RankedWindow] {
        let cgAll = cgWindows([.optionAll, .excludeDesktopElements])
        let boundsByID = Dictionary(cgAll.map { ($0.wid, $0.bounds) }, uniquingKeysWith: { a, _ in a })
        let zRank = Dictionary(
            cgWindows([.optionOnScreenOnly, .excludeDesktopElements]).enumerated()
                .map { ($0.element.wid, $0.offset) },
            uniquingKeysWith: { a, _ in a }
        )
        // Window ids the window server attributes to each app, across all
        // Spaces: lets the per-app probe stop as soon as it has found them all.
        var expectedByPID: [pid_t: Set<CGWindowID>] = [:]
        for e in cgAll { expectedByPID[e.pid, default: []].insert(e.wid) }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let excluded = Set(Config.shared.excludedApps)
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && $0.processIdentifier != myPID
                && !excluded.contains($0.bundleIdentifier ?? "")
                && !excluded.contains($0.localizedName ?? "")
        }

        // Probe apps in parallel: each app's AX server is a separate process,
        // so the sweep is bounded by the slowest app, not the sum.
        let lock = NSLock()
        var ranked: [RankedWindow] = []
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let app = apps[i]
            let expected = expectedByPID[app.processIdentifier] ?? []
            for (order, win) in windows(of: app, expected: expected).enumerated() {
                // Prefer the window server's idea of the frame: unlike the AX
                // frame it is also correct for windows in other Spaces.
                let frame = boundsByID[win.wid] ?? win.axFrame
                guard frame.width >= minWindowSize.width, frame.height >= minWindowSize.height else { continue }
                // Visible in the current Space: true z-order; in another Space: after visible ones.
                let rank = zRank[win.wid] ?? Int.max
                let info = WindowInfo(
                    ax: win.ax,
                    windowID: win.wid,
                    pid: app.processIdentifier,
                    appName: app.localizedName ?? "?",
                    icon: app.icon,
                    title: win.title.isEmpty ? (app.localizedName ?? "Untitled") : win.title,
                    frame: frame
                )
                lock.lock()
                ranked.append(RankedWindow(rank: rank, order: i * 10_000 + order, info: info))
                lock.unlock()
            }
        }
        FocusHistory.shared.prune(keeping: Set(boundsByID.keys))
        return ranked
    }

    static func focus(_ window: WindowInfo) {
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        let axApp = AXUIElementCreateApplication(window.pid)
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window.ax)
        AXUIElementSetAttributeValue(window.ax, kAXMainAttribute as CFString, kCFBooleanTrue)
        // Raising a window in another Space makes macOS switch to that Space.
        AXUIElementPerformAction(window.ax, kAXRaiseAction as CFString)
    }

    // MARK: - Per-app window discovery

    private struct AppWindow {
        let ax: AXUIElement
        let wid: CGWindowID
        let title: String
        let axFrame: CGRect
    }

    /// All standard windows of an app, across all Spaces: the public window
    /// list (current Space) merged with a remote-token probe (which also
    /// finds windows in other Spaces). Minimized windows are excluded.
    private static func windows(of app: NSRunningApplication, expected: Set<CGWindowID>) -> [AppWindow] {
        let pid = app.processIdentifier
        var byID: [CGWindowID: AXUIElement] = [:]
        var order: [CGWindowID] = []
        // Every window id we've resolved, including ones `insert` rejects
        // (minimized windows, sub-elements). Drives the probe's early exit;
        // tracking rejects too keeps a minimized window from stalling the loop.
        var seen: Set<CGWindowID> = []

        // Check the subrole at insertion time: the remote-token probe also
        // resolves sub-elements (close buttons etc.) that report the same
        // window id — a button must never claim the id before its window.
        // Requiring a close button weeds out phantom app-level windows
        // (e.g. Chrome/Acrobat helper windows) that pose as standard windows.
        func insert(_ el: AXUIElement) {
            guard let wid = PrivateAX.windowID(of: el) else { return }
            seen.insert(wid)
            guard byID[wid] == nil,
                  stringAttr(el, kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
                  hasAttr(el, kAXCloseButtonAttribute),
                  !boolAttr(el, kAXMinimizedAttribute)
            else { return }
            byID[wid] = el
            order.append(wid)
        }

        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var listRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &listRef) == .success,
           let list = listRef as? [AXUIElement] {
            list.forEach(insert)
        }

        // The public window list only covers the current Space. Probe for
        // windows in other Spaces only if it didn't already resolve every id
        // the window server attributes to this app (the common case).
        // `expected` is what the window server attributes to this app, and it is
        // the same source the early exit trusts — so an empty `expected` means
        // the app genuinely has no windows, not that we know nothing about it.
        // Requiring it to be non-empty (as this used to) meant a windowless app
        // could never satisfy the exit and ate the full probe, plus its entire
        // time budget, on every sweep — to find the nothing we already knew about.
        let covered = { seen.isSuperset(of: expected) }
        if !covered() {
            let deadline = Date().addingTimeInterval(perAppBudget)
            for axId in 0..<bruteForceRange {
                if axId % 64 == 0 && Date() > deadline { break }
                guard let el = PrivateAX.remoteTokenElement(pid: pid, axId: axId) else { continue }
                insert(el)
                if covered() { break }
            }
        }

        return order.compactMap { wid in
            guard let el = byID[wid] else { return nil }
            return AppWindow(
                ax: el,
                wid: wid,
                title: stringAttr(el, kAXTitleAttribute) ?? "",
                axFrame: frame(of: el)
            )
        }
    }

    // MARK: - CG window list

    private struct CGEntry {
        let wid: CGWindowID
        let pid: pid_t
        let bounds: CGRect
    }

    private static func cgWindows(_ options: CGWindowListOption) -> [CGEntry] {
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [CGEntry] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let wid = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
            )
            out.append(CGEntry(wid: wid, pid: pid, bounds: rect))
        }
        return out
    }

    // MARK: - Displays
    // AX and CG both use top-left-origin global coordinates, so frames compare directly.

    private static func currentActiveDisplay() -> CGDirectDisplayID {
        if let front = NSWorkspace.shared.frontmostApplication {
            let axApp = AXUIElementCreateApplication(front.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
               let winRef, CFGetTypeID(winRef) == AXUIElementGetTypeID() {
                let win = winRef as! AXUIElement
                let f = frame(of: win)
                if f.width > 0 { return display(for: f) }
            }
        }
        // Fall back to the display under the mouse.
        let mouse = CGEvent(source: nil)?.location ?? .zero
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(mouse, 1, &display, &count) == .success, count > 0 {
            return display
        }
        return CGMainDisplayID()
    }

    private static func display(for frame: CGRect) -> CGDirectDisplayID {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &displays, &count)
        var best = CGMainDisplayID()
        var bestArea: CGFloat = 0
        for i in 0..<Int(count) {
            let overlap = CGDisplayBounds(displays[i]).intersection(frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = displays[i]
            }
        }
        return best
    }

    private static func nsScreen(for display: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }
    }

    // MARK: - AX attribute helpers

    private static func frame(of window: AXUIElement) -> CGRect {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        var pos = CGPoint.zero
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
           let posRef, CFGetTypeID(posRef) == AXValueGetTypeID() {
            AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        }
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() {
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: pos, size: size)
    }

    private static func stringAttr(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func boolAttr(_ element: AXUIElement, _ attribute: String) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return false }
        return (ref as? Bool) ?? false
    }

    private static func hasAttr(_ element: AXUIElement, _ attribute: String) -> Bool {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success && ref != nil
    }
}
