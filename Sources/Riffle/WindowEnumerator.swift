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
    /// CG window ids we already probed and chose not to list (phantoms,
    /// undersized, …). Without this, every snapshot treats them as "newcomers" and
    /// re-probes their apps — the main-thread stall that made the switcher feel stuck.
    /// Minimized windows are tracked separately so they can reappear on deminiaturize.
    private static var ignoredWindowIDs: Set<CGWindowID> = []
    /// Windows known to be minimized (yellow-button). Still in CGWindowList, so the
    /// dead-id prune won't catch them; they must be filtered explicitly.
    private static var minimizedWindowIDs: Set<CGWindowID> = []
    private static var pendingAppRefresh: Set<pid_t> = []
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

    /// Drop every cached window owned by `pid` (app quit). Cheap and synchronous
    /// so the next trigger never resurrects a dead app while a full sweep runs.
    static func remove(pid: pid_t) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cached = cachedWindows else { return }
        cachedWindows = cached.filter { $0.info.pid != pid }
    }

    /// Drop specific window ids (closed windows).
    static func remove(windowIDs: Set<CGWindowID>) {
        guard !windowIDs.isEmpty else { return }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cached = cachedWindows else { return }
        cachedWindows = cached.filter { !windowIDs.contains($0.info.windowID) }
        minimizedWindowIDs.subtract(windowIDs)
    }

    /// Yellow-button minimize / restore. Minimized windows stay in CGWindowList,
    /// so callers must tell us explicitly.
    static func setMinimized(_ windowID: CGWindowID, minimized: Bool) {
        cacheLock.lock()
        if minimized {
            minimizedWindowIDs.insert(windowID)
            if let cached = cachedWindows {
                cachedWindows = cached.filter { $0.info.windowID != windowID }
            }
        } else {
            minimizedWindowIDs.remove(windowID)
            ignoredWindowIDs.remove(windowID)
        }
        cacheLock.unlock()
        if !minimized, let pid = pid(ofWindowID: windowID) {
            refreshAppAsync(pid: pid)
        }
    }

    /// Re-probe one app off the main thread and replace its cache entries.
    /// Coalesced per pid so create-notification storms don't stack probes.
    static func refreshAppAsync(pid: pid_t) {
        cacheLock.lock()
        let schedule = pendingAppRefresh.insert(pid).inserted
        cacheLock.unlock()
        guard schedule else { return }
        refreshQueue.async {
            cacheLock.lock()
            pendingAppRefresh.remove(pid)
            cacheLock.unlock()
            mergeApp(pid: pid, probeOtherSpaces: true)
        }
    }

    /// Topmost on-screen layer-0 window for a pid, if any. Used as a focus
    /// fallback when AX hasn't published a focused window yet after launch.
    static func topWindowID(for pid: pid_t) -> CGWindowID? {
        cgWindows([.optionOnScreenOnly, .excludeDesktopElements])
            .first { $0.pid == pid }?
            .wid
    }

    /// Cheap per-trigger view over the (cached) window list. Serves the last
    /// enumeration immediately; only the very first call pays for a synchronous
    /// sweep. Removals sync against the window server (cheap). New windows are
    /// merged for the frontmost app via the public AX list only (no remote-token
    /// scan); everything else is probed on the background queue. CG lists many
    /// ids AX rejects (helpers, minimized) — those are remembered as ignored
    /// so they don't re-trigger probes on every Cmd+Tab.
    static func snapshot() -> Snapshot {
        cacheLock.lock()
        let cached = cachedWindows
        cacheLock.unlock()

        var ranked: [RankedWindow]
        if let cached {
            ranked = cached
        } else {
            ranked = enumerateWindows()
            cacheLock.lock()
            cachedWindows = ranked
            cacheLock.unlock()
        }

        let cgAll = cgWindows([.optionAll, .excludeDesktopElements])
        let live = Set(cgAll.map(\.wid))
        let onScreen = Set(cgWindows([.optionOnScreenOnly, .excludeDesktopElements]).map(\.wid))
        let cachedIDs = Set(ranked.map(\.info.windowID))

        // Removals: drop ids the window server no longer lists, and persist
        // that into the cache so the next trigger isn't one beat behind.
        let dead = cachedIDs.subtracting(live)
        if !dead.isEmpty {
            ranked = ranked.filter { live.contains($0.info.windowID) }
            remove(windowIDs: dead)
        }

        // Hidden apps (⌘H) and minimized windows still appear in CGWindowList,
        // so the dead-id prune above won't remove them. Drop them here.
        var newlyMinimized: Set<CGWindowID> = []
        ranked = ranked.filter { entry in
            if let app = NSRunningApplication(processIdentifier: entry.info.pid), app.isHidden {
                return false
            }
            // On-screen ⇒ not minimized (minimized windows live in the Dock).
            // Checked before the minimized set so a stale flag from a missed
            // deminiaturize notification can't hide a visible window.
            if onScreen.contains(entry.info.windowID) { return true }
            cacheLock.lock()
            let knownMinimized = minimizedWindowIDs.contains(entry.info.windowID)
            cacheLock.unlock()
            if knownMinimized { return false }
            // Off-screen is either another Space (keep) or minimized without
            // a notification (check AX).
            if boolAttr(entry.info.ax, kAXMinimizedAttribute) {
                newlyMinimized.insert(entry.info.windowID)
                return false
            }
            return true
        }
        if !newlyMinimized.isEmpty {
            cacheLock.lock()
            minimizedWindowIDs.formUnion(newlyMinimized)
            if let cached = cachedWindows {
                cachedWindows = cached.filter { !newlyMinimized.contains($0.info.windowID) }
            }
            cacheLock.unlock()
        }

        let activeDisplay = currentActiveDisplay()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Forget ignored/minimized ids that are gone; schedule background probes
        // only for plausible not-yet-seen windows (large enough to be real).
        cacheLock.lock()
        ignoredWindowIDs = ignoredWindowIDs.intersection(live)
        // An on-screen id can't be minimized: clear stale flags (missed
        // deminiaturize notifications) so such windows re-enter as newcomers
        // below instead of staying invisible forever.
        minimizedWindowIDs = minimizedWindowIDs.intersection(live).subtracting(onScreen)
        let ignored = ignoredWindowIDs.union(minimizedWindowIDs)
        cacheLock.unlock()

        let newcomers = live.subtracting(cachedIDs).subtracting(ignored)
        if !newcomers.isEmpty {
            let myPID = ProcessInfo.processInfo.processIdentifier
            let excluded = Set(Config.shared.excludedApps)
            var pidsToProbe = Set<pid_t>()
            var rejectNow: Set<CGWindowID> = []
            for e in cgAll where newcomers.contains(e.wid) {
                if e.bounds.width < minWindowSize.width || e.bounds.height < minWindowSize.height {
                    rejectNow.insert(e.wid)
                    continue
                }
                guard e.pid != myPID,
                      let app = NSRunningApplication(processIdentifier: e.pid),
                      app.activationPolicy == .regular,
                      !excluded.contains(app.bundleIdentifier ?? ""),
                      !excluded.contains(app.localizedName ?? "")
                else {
                    rejectNow.insert(e.wid)
                    continue
                }
                pidsToProbe.insert(e.pid)
            }
            if !rejectNow.isEmpty {
                cacheLock.lock()
                ignoredWindowIDs.formUnion(rejectNow)
                cacheLock.unlock()
            }
            // Frontmost only: cheap current-Space AX list (no remote-token scan)
            // so a just-opened window shows on this trigger. Full cross-Space
            // probe stays on the background queue for every affected pid.
            if let frontmostPID, pidsToProbe.contains(frontmostPID) {
                mergeApp(pid: frontmostPID, probeOtherSpaces: false)
                cacheLock.lock()
                ranked = cachedWindows ?? ranked
                cacheLock.unlock()
            }
            for pid in pidsToProbe {
                refreshAppAsync(pid: pid)
            }
        }

        // Most-recently-used first, from our own focus history; windows not
        // focused since launch fall back to front-to-back stacking order.
        // Frontmost focused window with no timestamp yet still ranks as "now"
        // so a launch-race miss can't bury the current app at the end.
        var focus = FocusHistory.shared.timestamps()
        if let frontmostPID,
           let frontWID = focusedWindowID(of: frontmostPID) ?? topWindowID(for: frontmostPID),
           focus[frontWID] == nil {
            focus[frontWID] = Date()
        }
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
        let windows = sorted.map(\.info)
        let activeScreenWindowIDs = Set(
            windows.filter { display(for: $0.frame) == activeDisplay }.map(\.windowID)
        )
        return Snapshot(
            windows: windows,
            activeScreen: nsScreen(for: activeDisplay),
            frontmostPID: frontmostPID,
            activeScreenWindowIDs: activeScreenWindowIDs
        )
    }

    // MARK: - Targeted merge

    /// Probe `pid` and replace that app's entries in the cache.
    /// - Parameter probeOtherSpaces: when false, only the public AX window list
    ///   is used (fast enough for the main-thread snapshot path). When true,
    ///   the remote-token scan also finds windows on other Spaces.
    @discardableResult
    private static func mergeApp(pid: pid_t, probeOtherSpaces: Bool) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular else {
            remove(pid: pid)
            return false
        }
        let excluded = Set(Config.shared.excludedApps)
        if excluded.contains(app.bundleIdentifier ?? "")
            || excluded.contains(app.localizedName ?? "") {
            remove(pid: pid)
            return false
        }

        let cgAll = cgWindows([.optionAll, .excludeDesktopElements])
        let boundsByID = Dictionary(cgAll.map { ($0.wid, $0.bounds) }, uniquingKeysWith: { a, _ in a })
        let zRank = Dictionary(
            cgWindows([.optionOnScreenOnly, .excludeDesktopElements]).enumerated()
                .map { ($0.element.wid, $0.offset) },
            uniquingKeysWith: { a, _ in a }
        )
        let expected = Set(cgAll.filter { $0.pid == pid }.map(\.wid))
        let probed = windows(of: app, expected: expected, probeOtherSpaces: probeOtherSpaces)
        let accepted = Set(probed.windows.map(\.wid))
        let minimized = probed.minimizedIDs

        var merged: [RankedWindow] = []
        for (order, win) in probed.windows.enumerated() {
            let frame = boundsByID[win.wid] ?? win.axFrame
            guard frame.width >= minWindowSize.width, frame.height >= minWindowSize.height else { continue }
            let rank = zRank[win.wid] ?? Int.max
            let info = WindowInfo(
                ax: win.ax,
                windowID: win.wid,
                pid: pid,
                appName: app.localizedName ?? "?",
                icon: app.icon,
                title: win.title.isEmpty ? (app.localizedName ?? "Untitled") : win.title,
                frame: frame
            )
            merged.append(RankedWindow(rank: rank, order: order, info: info))
        }

        // Permanent rejects only (phantoms/undersized). Minimized ids are tracked
        // separately so restoring a window can bring it back. Ids an *incomplete*
        // probe failed to resolve are unknowns, not phantoms — poisoning them
        // into ignoredWindowIDs made windows vanish for good after one AX
        // timeout, because snapshot() never re-probes ignored ids.
        let undersized = Set(probed.windows.compactMap { win -> CGWindowID? in
            let frame = boundsByID[win.wid] ?? win.axFrame
            return (frame.width < minWindowSize.width || frame.height < minWindowSize.height)
                ? win.wid : nil
        })
        let rejected: Set<CGWindowID> = (probeOtherSpaces && probed.complete)
            ? expected.subtracting(accepted).subtracting(minimized).union(undersized)
            : undersized

        cacheLock.lock()
        var base = cachedWindows ?? []
        // Only a complete cross-Space probe may wipe the app's cache wholesale.
        // A current-Space merge must not drop other-Space windows we already
        // know, and an incomplete probe must not drop windows it merely missed.
        if probeOtherSpaces && probed.complete {
            base.removeAll { $0.info.pid == pid }
        } else {
            let replaced = Set(merged.map(\.info.windowID))
            base.removeAll { $0.info.pid == pid && replaced.contains($0.info.windowID) }
            // Also drop dead ones for this pid that CG no longer lists.
            base.removeAll { $0.info.pid == pid && !expected.contains($0.info.windowID) }
            // Prefer newly probed entries when both exist.
            base.removeAll { replaced.contains($0.info.windowID) }
        }
        // Minimized windows must not linger in the shown cache.
        base.removeAll { minimized.contains($0.info.windowID) }
        base.append(contentsOf: merged)
        cachedWindows = base
        ignoredWindowIDs.formUnion(rejected)
        ignoredWindowIDs.subtract(accepted)
        minimizedWindowIDs.formUnion(minimized)
        minimizedWindowIDs.subtract(accepted)
        cacheLock.unlock()
        return true
    }

    private static func pid(ofWindowID wid: CGWindowID) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]],
              let info = list.first,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        else { return nil }
        return pid
    }

    private static func focusedWindowID(of pid: pid_t) -> CGWindowID? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return PrivateAX.windowID(of: ref as! AXUIElement)
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
        var foundMinimized: Set<CGWindowID> = []
        var completePIDs: Set<pid_t> = []
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let app = apps[i]
            let expected = expectedByPID[app.processIdentifier] ?? []
            let probed = windows(of: app, expected: expected, probeOtherSpaces: true)
            var local: [RankedWindow] = []
            for (order, win) in probed.windows.enumerated() {
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
                local.append(RankedWindow(rank: rank, order: i * 10_000 + order, info: info))
            }
            lock.lock()
            ranked.append(contentsOf: local)
            foundMinimized.formUnion(probed.minimizedIDs)
            if probed.complete { completePIDs.insert(app.processIdentifier) }
            lock.unlock()
        }
        FocusHistory.shared.prune(keeping: Set(boundsByID.keys))
        let accepted = Set(ranked.map(\.info.windowID))
        // On-screen CG ids that AX didn't accept and aren't minimized are
        // phantoms — but only if that app's probe was complete. After a
        // timed-out probe the misses are unknowns and must stay probeable.
        let onScreenIDs = Set(zRank.keys)
        let rejected = Set(cgAll.compactMap { e -> CGWindowID? in
            guard completePIDs.contains(e.pid),
                  !accepted.contains(e.wid),
                  !foundMinimized.contains(e.wid),
                  onScreenIDs.contains(e.wid)
            else { return nil }
            return e.wid
        })
        cacheLock.lock()
        ignoredWindowIDs = ignoredWindowIDs.intersection(Set(boundsByID.keys)).union(rejected)
        ignoredWindowIDs.subtract(accepted)
        minimizedWindowIDs = minimizedWindowIDs.intersection(Set(boundsByID.keys)).union(foundMinimized)
        minimizedWindowIDs.subtract(accepted)
        cacheLock.unlock()
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

    private struct AppProbeResult {
        let windows: [AppWindow]
        let minimizedIDs: Set<CGWindowID>
        /// False when the AX list read failed or the remote-token scan ran out
        /// of budget: window ids the probe didn't resolve are then unknowns,
        /// not phantoms, and must not be added to `ignoredWindowIDs`.
        let complete: Bool
    }

    /// All standard windows of an app, across all Spaces: the public window
    /// list (current Space) merged with a remote-token probe (which also
    /// finds windows in other Spaces). Minimized windows are excluded from
    /// `windows` but reported in `minimizedIDs`.
    private static func windows(
        of app: NSRunningApplication,
        expected: Set<CGWindowID>,
        probeOtherSpaces: Bool
    ) -> AppProbeResult {
        let pid = app.processIdentifier
        var byID: [CGWindowID: AXUIElement] = [:]
        var order: [CGWindowID] = []
        // Every window id we've resolved, including ones `insert` rejects
        // (minimized windows, sub-elements). Drives the probe's early exit;
        // tracking rejects too keeps a minimized window from stalling the loop.
        var seen: Set<CGWindowID> = []
        var minimizedIDs: Set<CGWindowID> = []

        // Check the subrole at insertion time: the remote-token probe also
        // resolves sub-elements (close buttons etc.) that report the same
        // window id — a button must never claim the id before its window.
        // Requiring a close button weeds out phantom app-level windows
        // (e.g. Chrome/Acrobat helper windows) that pose as standard windows.
        func insert(_ el: AXUIElement) {
            guard let wid = PrivateAX.windowID(of: el) else { return }
            seen.insert(wid)
            if boolAttr(el, kAXMinimizedAttribute) {
                minimizedIDs.insert(wid)
                return
            }
            guard byID[wid] == nil,
                  stringAttr(el, kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
                  hasAttr(el, kAXCloseButtonAttribute)
            else { return }
            byID[wid] = el
            order.append(wid)
        }

        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var listRef: CFTypeRef?
        var listOK = false
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &listRef) == .success,
           let list = listRef as? [AXUIElement] {
            listOK = true
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
        var timedOut = false
        if probeOtherSpaces && !covered() {
            let deadline = Date().addingTimeInterval(perAppBudget)
            for axId in 0..<bruteForceRange {
                if axId % 64 == 0 && Date() > deadline {
                    timedOut = true
                    break
                }
                guard let el = PrivateAX.remoteTokenElement(pid: pid, axId: axId) else { continue }
                insert(el)
                if covered() { break }
            }
        }

        let windows = order.compactMap { wid -> AppWindow? in
            guard let el = byID[wid] else { return nil }
            return AppWindow(
                ax: el,
                wid: wid,
                title: stringAttr(el, kAXTitleAttribute) ?? "",
                axFrame: frame(of: el)
            )
        }
        return AppProbeResult(
            windows: windows,
            minimizedIDs: minimizedIDs,
            complete: covered() || (listOK && !timedOut)
        )
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
