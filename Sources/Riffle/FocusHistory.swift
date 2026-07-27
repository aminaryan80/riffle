import AppKit
import ApplicationServices

/// Tracks when each window was last focused, so the switcher can list
/// windows in true most-recently-used order. macOS exposes no "last focused"
/// timestamp, so we build our own while the app runs:
///  - every app activation (workspace notification) records that app's focused window
///  - an AX observer on the frontmost app records focus changes *within* it
///  - every switch made through Riffle records the target directly
///
/// App launch often activates before AX has a focused window; we retry briefly
/// and fall back to the window server's topmost window for that pid.
final class FocusHistory {
    static let shared = FocusHistory()

    /// Guards `lastFocused` alone. It's written from the main thread (focus
    /// notifications, and every switch we make) but pruned from the background
    /// window sweep, so the two can collide. The rest of this class is
    /// main-thread only.
    private let lock = NSLock()
    private var lastFocused: [CGWindowID: Date] = [:]
    private var started = false
    private var observer: AXObserver?
    private var observedApp: AXUIElement?
    /// Generation bumped on each activation so in-flight retries for an older
    /// frontmost app bail out instead of recording stale focus.
    private var activationGeneration: UInt64 = 0

    private static let retryDelays: [TimeInterval] = [0.05, 0.2, 0.5]

    /// Idempotent; call once accessibility access is available.
    func start() {
        guard !started else { return }
        started = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        if let front = NSWorkspace.shared.frontmostApplication {
            trackActivation(of: front)
        }
    }

    func record(_ windowID: CGWindowID) {
        lock.lock()
        defer { lock.unlock() }
        lastFocused[windowID] = Date()
    }

    /// A copy of the whole table. Callers that rank a window list want one
    /// consistent view for the duration of a sort, not a lookup per comparison
    /// that could see the table change halfway through.
    func timestamps() -> [CGWindowID: Date] {
        lock.lock()
        defer { lock.unlock() }
        return lastFocused
    }

    /// Drop entries for windows that no longer exist.
    func prune(keeping alive: Set<CGWindowID>) {
        lock.lock()
        defer { lock.unlock() }
        lastFocused = lastFocused.filter { alive.contains($0.key) }
    }

    // MARK: - Focus tracking

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        trackActivation(of: app)
    }

    private func trackActivation(of app: NSRunningApplication) {
        activationGeneration &+= 1
        let generation = activationGeneration
        let pid = app.processIdentifier
        watch(app)
        if recordFocusedWindow(of: app) { return }
        scheduleRetries(pid: pid, generation: generation)
    }

    /// Returns true when a window id was recorded.
    @discardableResult
    private func recordFocusedWindow(of app: NSRunningApplication) -> Bool {
        if let wid = axFocusedWindowID(of: app.processIdentifier) {
            record(wid)
            return true
        }
        // AX often lags a brand-new window; the window server already knows.
        if let wid = WindowEnumerator.topWindowID(for: app.processIdentifier) {
            record(wid)
            return true
        }
        return false
    }

    private func scheduleRetries(pid: pid_t, generation: UInt64) {
        for delay in Self.retryDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard generation == self.activationGeneration else { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                if let wid = self.axFocusedWindowID(of: pid) {
                    self.record(wid)
                    return
                }
                if let wid = WindowEnumerator.topWindowID(for: pid) {
                    self.record(wid)
                }
            }
        }
    }

    private func axFocusedWindowID(of pid: pid_t) -> CGWindowID? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return PrivateAX.windowID(of: ref as! AXUIElement)
    }

    /// Move the focused-window observer to the now-frontmost app.
    private func watch(_ app: NSRunningApplication) {
        if let observer {
            // Unregister before dropping the observer, so the old app's AX
            // server stops tracking notifications nobody is listening for.
            if let observedApp {
                AXObserverRemoveNotification(observer, observedApp, kAXFocusedWindowChangedNotification as CFString)
                AXObserverRemoveNotification(observer, observedApp, kAXMainWindowChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
            self.observer = nil
            self.observedApp = nil
        }

        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let history = Unmanaged<FocusHistory>.fromOpaque(refcon).takeUnretainedValue()
            if let wid = PrivateAX.windowID(of: element) {
                history.record(wid)
            }
        }
        var obs: AXObserver?
        guard AXObserverCreate(app.processIdentifier, callback, &obs) == .success, let obs else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, axApp, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, axApp, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
        observedApp = axApp
    }
}
